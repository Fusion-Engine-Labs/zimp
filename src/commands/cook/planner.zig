const std = @import("std");

const material_generator = @import("../../parsers/gltf/material_generator.zig");
const AssetScanner = @import("../../assets/asset_scanner.zig").AssetScanner;
const DepGraph = @import("../../assets/dependency_graph.zig").DepGraph;
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const asset_registry = @import("../../assets/asset_registry.zig");
const builtin_registry = @import("../../builtin/registry.zig");
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const Hash = @import("../../assets/source_file.zig").Hash;
const CookContext = @import("context.zig").CookContext;
const Cache = @import("../../cache/cache.zig").Cache;
const log = @import("../../logger.zig");

pub const SourceIndex = u32;

pub const CsrGraph = struct {
    offsets: []u32,
    edges: []SourceIndex,

    pub fn deinit(self: CsrGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.edges);
    }

    pub fn edgesFrom(self: CsrGraph, index: SourceIndex) []const SourceIndex {
        return self.edges[self.offsets[index]..self.offsets[index + 1]];
    }
};

/// Stable, dense source state.  Paths are sorted before records are assigned so
/// indexes are deterministic across identical scans.
pub const SourceRecord = struct {
    source: SourceFile,
    info: SourceFile.FileInfo,
    descriptor: asset_registry.AssetDescriptor,
    output_path: ?[]const u8,
    cached_index: ?u32,
};

pub const CookPlan = struct {
    records: std.ArrayList(SourceRecord),
    dependencies: CsrGraph,
    dependents: CsrGraph,

    pub fn deinit(self: *CookPlan, allocator: std.mem.Allocator) void {
        for (self.records.items) |record| {
            allocator.free(record.source.path);
            if (record.output_path) |path| {
                allocator.free(path);
            }
        }
        self.records.deinit(allocator);

        self.dependencies.deinit(allocator);
        self.dependents.deinit(allocator);
    }
};

pub fn build(allocator: std.mem.Allocator, ctx: *const CookContext, cache: *Cache, metrics: *CookMetrics) !CookPlan {
    const scan_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    const scanner = AssetScanner.init(allocator, ctx.io, ctx.source);
    var sources = try scanner.scan();
    errdefer scanner.deinit(&sources);

    for (sources.items) |source| {
        if (builtin_registry.isBuiltin(source.path)) {
            log.err("Project asset: '{s}' is using reserved builtin namespace: '{s}'", .{
                source.path,
                builtin_registry.PREFIX,
            });
            return error.ReservedAssetPath;
        }
    }

    const generation = try material_generator.generateForSources(
        allocator,
        ctx.io,
        ctx.source,
        sources.items,
    );
    if (generation.changed()) {
        log.debug("Generated {d} material and {d} texture source file(s), rescanning assets", .{
            generation.materials,
            generation.textures,
        });
        scanner.deinit(&sources);
        sources = try scanner.scan();
    }

    const material_topology_changed = try materialTopologyChanged(allocator, sources.items, cache);
    // Forget deleted sources before the records below take cache indices:
    // pruning compacts the cache, so an index taken earlier would point at
    // another source's entry, or past the end. This comes after the topology
    // check, which has to see deleted materials to recook their meshes.
    pruneDeleted(allocator, cache, sources.items);
    const scan_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    metrics.scan_ns = @intCast(scan_start.durationTo(scan_end).raw.nanoseconds);
    std.mem.sort(SourceFile, sources.items, {}, struct {
        fn lessThan(_: void, a: SourceFile, b: SourceFile) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var records: std.ArrayList(SourceRecord) = .empty;
    errdefer {
        for (records.items) |record| {
            allocator.free(record.source.path);
            if (record.output_path) |path| allocator.free(path);
        }
        records.deinit(allocator);
    }
    try records.ensureTotalCapacity(allocator, sources.items.len);
    for (sources.items) |source| {
        const descriptor = asset_registry.descriptorForSource(source);
        const info = try source.getFileInfo(ctx.source, ctx.io);
        const output_path = if (descriptor.cooker) |cooker|
            try cooker.outputPath(allocator, source)
        else
            null;
        records.appendAssumeCapacity(.{
            .source = source,
            .info = info,
            .descriptor = descriptor,
            .output_path = output_path,
            .cached_index = if (material_topology_changed and source.assetKind() == .mesh)
                null
            else
                cache.getIdx(source),
        });
    }
    sources.deinit(allocator);
    sources = .empty;

    metrics.assets_total = @intCast(records.items.len);

    try validateUniqueOutputs(allocator, records.items);

    const dep_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    var dep_graph = DepGraph.init(allocator);
    defer dep_graph.deinit();

    try buildDependencyGraph(allocator, ctx, cache, &dep_graph, records.items);

    const dep_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.dependency_graph_ns = @intCast(dep_start.durationTo(dep_end).raw.nanoseconds);

    log.debug("Built dependency graph: {d} edge(s) across {d} source file(s)", .{
        dep_graph.totalDependencyCount(),
        records.items.len,
    });

    const graphs = try buildCsrGraphs(allocator, &dep_graph, records.items);
    errdefer graphs.dependencies.deinit(allocator);
    errdefer graphs.dependents.deinit(allocator);
    try validateAcyclic(allocator, graphs.dependencies, graphs.dependents);

    return .{
        .records = records,
        .dependencies = graphs.dependencies,
        .dependents = graphs.dependents,
    };
}

fn materialTopologyChanged(allocator: std.mem.Allocator, sources: []const SourceFile, cache: *const Cache) !bool {
    var current_paths = std.StringHashMap(void).init(allocator);
    defer current_paths.deinit();

    for (sources) |source| {
        if (source.extension != .zamat) {
            continue;
        }
        try current_paths.put(source.path, {});

        if (cache.getIdx(source) == null) {
            return true;
        }
    }

    for (cache.entries.items) |entry| {
        if (entry.asset_kind == .material and !current_paths.contains(entry.source_path)) {
            return true;
        }
    }
    return false;
}

fn pruneDeleted(allocator: std.mem.Allocator, cache: *Cache, sources: []const SourceFile) void {
    const pruned = cache.pruneDeleted(allocator, sources);
    if (pruned > 0) {
        log.debug("Removed {d} deleted source file(s) from cache", .{pruned});
    }

    const pruned_deps = cache.pruneDeletedDependencyRows(allocator, sources);
    if (pruned_deps > 0) {
        log.debug("Removed {d} deleted dependency graph row(s) from cache", .{pruned_deps});
    }
}

fn buildCsrGraphs(allocator: std.mem.Allocator, graph: *const DepGraph, records: []const SourceRecord) !struct { dependencies: CsrGraph, dependents: CsrGraph } {
    var indexes = std.AutoHashMap(Hash, SourceIndex).init(allocator);
    defer indexes.deinit();
    try indexes.ensureTotalCapacity(@intCast(records.len));
    for (records, 0..) |record, index| {
        indexes.putAssumeCapacity(record.source.hashPath(), @intCast(index));
    }

    const degree = try allocator.alloc(u32, records.len);
    defer allocator.free(degree);
    const dependent_degree = try allocator.alloc(u32, records.len);
    defer allocator.free(dependent_degree);
    @memset(degree, 0);
    @memset(dependent_degree, 0);

    var edge_count: usize = 0;
    for (records, 0..) |record, index| {
        if (graph.getDependenciesByHash(record.source.hashPath())) |deps| {
            for (deps.items) |dependency| {
                const dependency_index = indexes.get(dependency) orelse continue;
                degree[index] += 1;
                dependent_degree[dependency_index] += 1;
                edge_count += 1;
            }
        }
    }

    var dependencies = try makeCsr(allocator, degree, edge_count);
    errdefer dependencies.deinit(allocator);
    var dependents = try makeCsr(allocator, dependent_degree, edge_count);
    errdefer dependents.deinit(allocator);
    const dependency_cursor = try allocator.dupe(u32, dependencies.offsets[0..records.len]);
    defer allocator.free(dependency_cursor);
    const dependent_cursor = try allocator.dupe(u32, dependents.offsets[0..records.len]);
    defer allocator.free(dependent_cursor);

    for (records, 0..) |record, index| {
        if (graph.getDependenciesByHash(record.source.hashPath())) |deps| {
            for (deps.items) |dependency| {
                const dependency_index = indexes.get(dependency) orelse continue;
                dependencies.edges[dependency_cursor[index]] = dependency_index;
                dependency_cursor[index] += 1;
                dependents.edges[dependent_cursor[dependency_index]] = @intCast(index);
                dependent_cursor[dependency_index] += 1;
            }
        }
    }

    return .{ .dependencies = dependencies, .dependents = dependents };
}

fn makeCsr(allocator: std.mem.Allocator, degree: []const u32, edge_count: usize) !CsrGraph {
    const offsets = try allocator.alloc(u32, degree.len + 1);
    errdefer allocator.free(offsets);
    offsets[0] = 0;

    for (degree, 0..) |count, index| {
        offsets[index + 1] = offsets[index] + count;
    }
    return .{ .offsets = offsets, .edges = try allocator.alloc(SourceIndex, edge_count) };
}

fn validateAcyclic(allocator: std.mem.Allocator, dependencies: CsrGraph, dependents: CsrGraph) !void {
    const remaining = try allocator.alloc(u32, dependencies.offsets.len - 1);
    defer allocator.free(remaining);
    var ready: std.ArrayList(SourceIndex) = .empty;
    defer ready.deinit(allocator);

    for (remaining, 0..) |*count, index| {
        count.* = @intCast(dependencies.edgesFrom(@intCast(index)).len);
        if (count.* == 0) {
            try ready.append(allocator, @intCast(index));
        }
    }

    var emitted: usize = 0;
    var cursor: usize = 0;
    while (cursor < ready.items.len) : (cursor += 1) {
        emitted += 1;
        for (dependents.edgesFrom(ready.items[cursor])) |dependent| {
            remaining[dependent] -= 1;
            if (remaining[dependent] == 0) {
                try ready.append(allocator, dependent);
            }
        }
    }

    if (emitted != remaining.len) {
        return error.CycleDetected;
    }
}

fn validateUniqueOutputs(allocator: std.mem.Allocator, records: []const SourceRecord) !void {
    var outputs = std.StringHashMap([]const u8).init(allocator);
    defer outputs.deinit();

    for (records) |record| {
        const output_path = record.output_path orelse continue;

        const gop = try outputs.getOrPut(output_path);
        if (gop.found_existing) {
            log.err("Cooked output collision: '{s}' and '{s}' both map to '{s}'", .{
                gop.value_ptr.*,
                record.source.path,
                output_path,
            });
            return error.DuplicateCookedOutput;
        }
        gop.key_ptr.* = output_path;
        gop.value_ptr.* = record.source.path;
    }
}

fn buildDependencyGraph(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *Cache,
    dep_graph: *DepGraph,
    records: []const SourceRecord,
) !void {
    for (records) |record| {
        const source = record.source;

        if (cache.lookupDependencyRow(source)) |row| {
            if (row.isFresh(record.info)) {
                const from = source.hashPath();
                for (row.dependencies.items) |dep| {
                    try dep_graph.addDependency(from, dep.path_hash);
                }
                continue;
            }
        }

        const deps = asset_registry.extractDependencies(&source, ctx.source, ctx.io, allocator) catch |err| {
            log.warn("Failed to extract dependencies for '{s}': {s}", .{ source.path, @errorName(err) });
            continue;
        };
        defer {
            for (deps) |d| allocator.free(d.path);
            allocator.free(deps);
        }

        const from = source.hashPath();
        for (deps) |dep| {
            try dep_graph.addDependency(from, dep.hashPath());
        }

        try cache.upsertDependencyRow(allocator, source, record.info, deps);
    }
}

const testing = std.testing;

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

test "buildDependencyGraph reuses fresh cached dependency rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "main.frag", "void main() {}\n");

    const source = SourceFile.fromPath("main.frag");
    const dep = SourceFile.fromPath("common.glsl");
    const info = try source.getFileInfo(tmp.dir, testing.io);

    var cache = try Cache.init(testing.allocator, tmp.dir, ".");
    defer cache.deinit(testing.allocator);
    try cache.upsertDependencyRow(testing.allocator, source, info, &.{dep});

    const ctx = CookContext{
        .io = testing.io,
        .source = tmp.dir,
        .output = tmp.dir,
        .output_path = ".",
        .force = false,
    };

    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{.{ .source = source, .info = info, .descriptor = asset_registry.descriptorForSource(source), .output_path = null, .cached_index = null }});

    const deps = graph.getDependenciesByHash(source.hashPath()) orelse return error.MissingDependency;
    try testing.expectEqual(@as(usize, 1), deps.items.len);
    try testing.expectEqual(dep.hashPath(), deps.items[0]);
}

test "buildDependencyGraph refreshes stale cached dependency rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "main.frag",
        \\#include "new.glsl"
        \\void main() {}
        \\
    );

    const source = SourceFile.fromPath("main.frag");
    const old_dep = SourceFile.fromPath("old.glsl");
    const info = try source.getFileInfo(tmp.dir, testing.io);

    var cache = try Cache.init(testing.allocator, tmp.dir, ".");
    defer cache.deinit(testing.allocator);
    try cache.upsertDependencyRow(testing.allocator, source, .{
        .size = info.size + 1,
        .modified_ns = info.modified_ns,
    }, &.{old_dep});

    const ctx = CookContext{
        .io = testing.io,
        .source = tmp.dir,
        .output = tmp.dir,
        .output_path = ".",
        .force = false,
    };

    var graph = DepGraph.init(testing.allocator);
    defer graph.deinit();

    try buildDependencyGraph(testing.allocator, &ctx, &cache, &graph, &.{.{ .source = source, .info = info, .descriptor = asset_registry.descriptorForSource(source), .output_path = null, .cached_index = null }});

    const row = cache.lookupDependencyRow(source) orelse return error.MissingDependencyRow;
    try testing.expect(row.isFresh(info));
    try testing.expectEqual(@as(usize, 1), row.dependencies.items.len);
    try testing.expectEqualStrings("new.glsl", row.dependencies.items[0].path);

    const deps = graph.getDependenciesByHash(source.hashPath()) orelse return error.MissingDependency;
    try testing.expectEqual(SourceFile.fromPath("new.glsl").hashPath(), deps.items[0]);
}

test "build refreshes generated textures from unchanged gltf sources" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "scene.gltf",
        \\{
        \\  "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        \\  "textures": [{"source": 0}],
        \\  "images": [{"uri": "albedo.png"}]
        \\}
    );
    try writeTestFile(tmp.dir, "albedo.png", &.{ 1, 2, 3 });

    const source_dir = try std.Io.Dir.openDir(tmp.dir, testing.io, ".", .{ .iterate = true });
    defer source_dir.close(testing.io);
    var cache = try Cache.init(testing.allocator, source_dir, ".");
    defer cache.deinit(testing.allocator);
    const ctx = CookContext{
        .io = testing.io,
        .source = source_dir,
        .output = source_dir,
        .output_path = ".",
        .force = false,
    };

    var initial_metrics: CookMetrics = .{};
    var initial_plan = try build(testing.allocator, &ctx, &cache, &initial_metrics);
    defer initial_plan.deinit(testing.allocator);

    try writeTestFile(tmp.dir, "albedo.png", &.{ 4, 5, 6 });
    var refreshed_metrics: CookMetrics = .{};
    var refreshed_plan = try build(testing.allocator, &ctx, &cache, &refreshed_metrics);
    defer refreshed_plan.deinit(testing.allocator);

    const generated_texture_path = try std.fmt.allocPrint(testing.allocator, "generated/textures/scene_{x}_image_0_albedo.png", .{
        SourceFile.fromPath("scene.gltf").hashPath(),
    });
    defer testing.allocator.free(generated_texture_path);
    var found_generated_texture = false;
    for (refreshed_plan.records.items) |record| {
        if (std.mem.eql(u8, record.source.path, generated_texture_path)) {
            found_generated_texture = true;
            break;
        }
    }
    try testing.expect(found_generated_texture);

    const external_image = SourceFile.fromPath("albedo.png");
    const generated_texture = SourceFile.fromPath(generated_texture_path);
    try testing.expectEqual(
        try external_image.hash(source_dir, testing.io),
        try generated_texture.hash(source_dir, testing.io),
    );
}

test "validateUniqueOutputs rejects sources with the same cooked path" {
    const records = [_]SourceRecord{
        .{ .source = SourceFile.fromPath("textures/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "textures/hero.ztex", .cached_index = null },
        .{ .source = SourceFile.fromPath("textures/hero.jpg"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.jpg), .output_path = "textures/hero.ztex", .cached_index = null },
    };
    try testing.expectError(error.DuplicateCookedOutput, validateUniqueOutputs(testing.allocator, &records));
}

test "validateUniqueOutputs allows repeated stems in different directories" {
    const records = [_]SourceRecord{
        .{ .source = SourceFile.fromPath("characters/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "characters/hero.ztex", .cached_index = null },
        .{ .source = SourceFile.fromPath("ui/hero.png"), .info = .{ .size = 0, .modified_ns = 0 }, .descriptor = asset_registry.descriptorForExtension(.png), .output_path = "ui/hero.ztex", .cached_index = null },
    };
    try validateUniqueOutputs(testing.allocator, &records);
}
