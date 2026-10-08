const std = @import("std");

const zob = @import("zob");
const asset_registry = @import("../../assets/asset_registry.zig");
const SourceFile = @import("../../assets/source_file.zig").SourceFile;
const Hash = @import("../../assets/source_file.zig").Hash;
const Staleness = @import("../../cache/staleness.zig").Staleness;
const CacheEntry = @import("../../cache/entry.zig").CacheEntry;
const Cache = @import("../../cache/cache.zig").Cache;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const cook_metrics = @import("../cook_metrics.zig");
const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;
const log = @import("../../logger.zig");
const CookContext = @import("context.zig").CookContext;
const CsrGraph = @import("planner.zig").CsrGraph;
const SourceIndex = @import("planner.zig").SourceIndex;
const SourceRecord = @import("planner.zig").SourceRecord;
const AtomicFile = @import("../../shared/atomic_file.zig").AtomicFile;
const AssetKind = @import("../../assets/asset.zig").AssetKind;
const zmesh = @import("../../formats/zmesh.zig");
const ztex = @import("../../formats/ztex.zig");
const zshdr = @import("../../formats/zshdr.zig");
const zamat = @import("../../formats/zamat.zig");
const wire = @import("../../shared/wire.zig");
const HashedSource = @import("source_analysis.zig").HashedSource;
const CookInput = @import("../../cookers/cooker.zig").CookInput;

pub const ProcessResult = enum { cached, hash_match, cooked, dependency_changed, skipped, errored };

const MetricsDelta = struct {
    source_bytes_read: u64 = 0,
    cooked_bytes_written: u64 = 0,
};

const CacheUpdate = union(enum) {
    none,
    source_mtime: i96,
    cooked: u64,
    dependency_only,
    errored,
};

const CookJobResult = struct {
    entry: SourceFile,
    result: ProcessResult,
    cache_update: CacheUpdate = .none,
    metrics: MetricsDelta = .{},
    source_info: ?SourceFile.FileInfo = null,
    content_hash: ?Hash = null,
    output_path: ?[]const u8 = null,
};

const CookJob = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *const Cache,
    record: *const SourceRecord,
    force_recook: bool,
    cook_node: std.Progress.Node,

    pub fn execute(self: @This()) !CookJobResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var runner = CookJobRunner{
            .allocator = arena.allocator(),
            .temporary_allocator = self.allocator,
            .ctx = self.ctx,
            .cache = self.cache,
            .record = self.record,
            .descriptor = self.record.descriptor,
            .force_recook = self.force_recook,
            .cook_node = self.cook_node,
        };
        return runner.execute();
    }
};

const CookJobRunner = struct {
    allocator: std.mem.Allocator,
    temporary_allocator: std.mem.Allocator,
    ctx: *const CookContext,
    cache: *const Cache,
    record: *const SourceRecord,
    descriptor: asset_registry.AssetDescriptor,
    force_recook: bool,
    cook_node: std.Progress.Node,

    pub fn execute(self: *const CookJobRunner) !CookJobResult {
        const asset_node = self.cook_node.start(self.record.source.path, 0);
        defer asset_node.end();

        var analyzed = HashedSource.init(self.allocator, self.record.source, self.record.info);
        defer analyzed.deinit();

        if (self.descriptor.cooker == null) {
            return self.processDependencyOnly(&analyzed);
        }

        const start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const decision = try self.decideAssetAction(&analyzed);

        return switch (decision.action) {
            .cached => .{
                .entry = self.record.source,
                .result = .cached,
                .metrics = decision.metrics,
            },
            .hash_match => .{
                .entry = self.record.source,
                .result = .hash_match,
                .cache_update = .{ .source_mtime = decision.source_mtime },
                .metrics = decision.metrics,
            },
            .cook => self.cookAndPrepareCache(&analyzed, decision.metrics, start),
        };
    }

    const JobDecision = struct {
        action: Action = .cook,
        source_mtime: i96 = 0,
        metrics: MetricsDelta = .{},

        const Action = enum {
            cached,
            hash_match,
            cook,
        };
    };

    fn processDependencyOnly(self: *const CookJobRunner, analyzed: *HashedSource) !CookJobResult {
        var result = CookJobResult{
            .entry = self.record.source,
            .result = .dependency_changed,
        };

        const info = self.record.info;

        if (self.force_recook) {
            log.debug("{s} dependency changed, propagating to dependents", .{self.record.source.path});
            try self.attachSnapshot(&result, analyzed);
            result.cache_update = .dependency_only;
            return result;
        }

        if (self.lookupEntry()) |cache_entry| {
            const source_hash = if (cache_entry.source_mtime != info.modified_ns and cache_entry.source_size == info.size) try analyzed.hash(self.ctx.io, self.ctx.source) else null;
            const staleness = Staleness.check(cache_entry, info, source_hash, self.cache.host_os, !self.cache.project_id.eql(self.ctx.projectId()));
            self.recordAnalysisMetrics(&result.metrics, analyzed);

            switch (staleness.verdict) {
                .cached => {
                    log.debug("{s} is dependency-only and cached", .{self.record.source.path});
                    result.result = .skipped;
                    return result;
                },
                .hash_match => {
                    log.debug("{s} dependency-only hash match, updated mtime", .{self.record.source.path});
                    result.result = .skipped;
                    result.cache_update = .{ .source_mtime = info.modified_ns };
                    return result;
                },
                else => {
                    log.debug("{s} dependency-only source changed, propagating to dependents", .{self.record.source.path});
                    try self.attachSnapshot(&result, analyzed);
                    result.cache_update = .dependency_only;
                    return result;
                },
            }
        }

        log.debug("{s} dependency-only source first seen, propagating to dependents", .{self.record.source.path});
        try self.attachSnapshot(&result, analyzed);
        result.cache_update = .dependency_only;
        return result;
    }

    fn decideAssetAction(self: *const CookJobRunner, analyzed: *HashedSource) !JobDecision {
        var decision: JobDecision = .{};

        const info = self.record.info;
        decision.source_mtime = info.modified_ns;

        if (self.force_recook) {
            log.debug("{s} dependency changed, force recooking", .{self.record.source.path});
            return decision;
        }

        if (self.lookupEntry()) |cache_entry| {
            const source_hash = if (cache_entry.source_mtime != info.modified_ns and cache_entry.source_size == info.size)
                try analyzed.hash(self.ctx.io, self.ctx.source)
            else
                null;
            const staleness = Staleness.check(cache_entry, info, source_hash, self.cache.host_os, !self.cache.project_id.eql(self.ctx.projectId()));
            self.recordAnalysisMetrics(&decision.metrics, analyzed);

            switch (staleness.verdict) {
                .cached => {
                    if (self.outputFileIsCurrent(cache_entry.cooked_path)) {
                        log.debug("{s} is cached, not cooking", .{self.record.source.path});
                        decision.action = .cached;
                        return decision;
                    }
                    log.debug("{s} cached output is missing or uses an outdated format, recooking", .{self.record.source.path});
                },
                .hash_match => {
                    if (self.outputFileIsCurrent(cache_entry.cooked_path)) {
                        decision.action = .hash_match;
                        return decision;
                    }
                    log.debug("{s} hash match but output is missing or uses an outdated format, recooking", .{self.record.source.path});
                },
                .errored => {
                    log.debug("{s} previously errored, retrying", .{self.record.source.path});
                },
                else => {
                    log.debug("{s} is not cached, staleness: {s}", .{ self.record.source.path, @tagName(staleness.verdict) });
                },
            }
        }

        return decision;
    }

    fn cookAndPrepareCache(
        self: *const CookJobRunner,
        analyzed: *HashedSource,
        initial_metrics: MetricsDelta,
        start: std.Io.Clock.Timestamp,
    ) !CookJobResult {
        var result = CookJobResult{
            .entry = self.record.source,
            .result = .errored,
            .metrics = initial_metrics,
        };

        const cooker = self.descriptor.cooker orelse {
            log.warn("No cooker registered for extension '{s}', skipping '{s}'", .{ self.record.source.extension.string(), self.record.source.path });
            result.result = .skipped;
            return result;
        };

        const cooked_path = self.record.output_path orelse return result;

        if (std.fs.path.dirname(cooked_path)) |parent| {
            self.ctx.output.createDirPath(self.ctx.io, parent) catch |err| {
                log.err("Failed to create output directory for '{s}': {s}", .{ self.record.source.path, @errorName(err) });
                return result;
            };
        }

        var pending_file = AtomicFile.create(self.allocator, self.ctx.io, self.ctx.output, cooked_path) catch |err| {
            log.err("Failed to create output file for '{s}': {s}", .{ self.record.source.path, @errorName(err) });
            return result;
        };
        defer pending_file.deinit();

        var buf: [8192]u8 = undefined;
        var file_writer = pending_file.file.writer(self.ctx.io, &buf);

        const source_bytes = try analyzed.data(self.ctx.io, self.ctx.source);
        try self.attachSnapshot(&result, analyzed);
        result.output_path = cooked_path;
        const input = CookInput{
            .allocator = self.allocator,
            .temporary_allocator = self.temporary_allocator,
            .io = self.ctx.io,
            .source_dir = self.ctx.source,
            .project_id = self.ctx.projectId(),
            .source = self.record.source,
            .bytes = source_bytes,
            .writer = &file_writer.interface,
        };

        const cook_failed = blk: {
            cooker.cook(&input) catch |err| {
                log.err("Failed to cook '{s}': {s}", .{ self.record.source.path, @errorName(err) });
                break :blk true;
            };
            break :blk false;
        };

        if (cook_failed) {
            self.ctx.output.deleteFile(self.ctx.io, cooked_path) catch |err| {
                if (err != error.FileNotFound)
                    log.warn("Failed to remove stale output '{s}': {s}", .{ cooked_path, @errorName(err) });
            };
            result.cache_update = .errored;
            return result;
        }

        try file_writer.flush();

        const cooked_stat = try pending_file.file.stat(self.ctx.io);
        try pending_file.commit();

        const end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const elapsed_ns: u64 = @intCast(start.durationTo(end).raw.nanoseconds);
        var duration_buf: [32]u8 = undefined;
        log.debug("Cooked '{s}' in {s}", .{ self.record.source.path, cook_metrics.fmtDuration(elapsed_ns, &duration_buf) });

        result.result = .cooked;
        result.metrics.cooked_bytes_written += cooked_stat.size;
        result.cache_update = .{ .cooked = cooked_stat.size };
        return result;
    }

    fn lookupEntry(self: *const CookJobRunner) ?*const CacheEntry {
        const idx = self.record.cached_index orelse return null;
        return &self.cache.entries.items[idx];
    }

    fn outputFileIsCurrent(self: *const CookJobRunner, cooked_path: []const u8) bool {
        const kind = self.record.source.assetKind() orelse return false;
        return cookedFileIsCurrent(self.ctx.io, self.ctx.output, cooked_path, kind);
    }

    fn attachSnapshot(self: *const CookJobRunner, result: *CookJobResult, analyzed: *HashedSource) !void {
        result.source_info = self.record.info;
        result.content_hash = try analyzed.hash(self.ctx.io, self.ctx.source);
        self.recordAnalysisMetrics(&result.metrics, analyzed);
    }

    fn recordAnalysisMetrics(_: *const CookJobRunner, metrics: *MetricsDelta, analyzed: *const HashedSource) void {
        metrics.source_bytes_read = analyzed.bytes_read;
    }
};

const CookedHeader = struct {
    magic: []const u8,
    version: u32,
};

fn currentCookedHeader(asset_kind: AssetKind) CookedHeader {
    return switch (asset_kind) {
        .mesh => .{ .magic = zmesh.MAGIC, .version = zmesh.ZMESH_VERSION },
        .texture => .{ .magic = ztex.MAGIC, .version = ztex.ZATEX_VERSION },
        .shader_stage => .{ .magic = zshdr.MAGIC, .version = zshdr.ZSHDR_VERSION },
        .material => .{ .magic = zamat.MAGIC, .version = zamat.ZAMAT_VERSION },
    };
}

fn cookedFileIsCurrent(io: std.Io, output: std.Io.Dir, cooked_path: []const u8, asset_kind: AssetKind) bool {
    if (cooked_path.len == 0) {
        return false;
    }

    const file = output.openFile(io, cooked_path, .{}) catch return false;
    defer file.close(io);

    var header: wire.FileHeader = undefined;
    const read = file.readPositionalAll(io, std.mem.asBytes(&header), 0) catch return false;
    if (read != @sizeOf(wire.FileHeader)) return false;
    const size = file.length(io) catch return false;
    const expected = currentCookedHeader(asset_kind);
    return std.mem.eql(u8, &header.magic, expected.magic) and
        header.version == expected.version and
        header.total_size == size;
}

const MetricsAccumulator = struct {
    metrics: *CookMetrics,
    counting: *CountingAllocator,

    fn recordJobResult(self: *MetricsAccumulator, result: CookJobResult) void {
        self.metrics.source_bytes_read += result.metrics.source_bytes_read;
        self.metrics.cooked_bytes_written += result.metrics.cooked_bytes_written;

        switch (result.result) {
            .cached => self.metrics.assets_cached += 1,
            .hash_match => {
                self.metrics.assets_cached += 1;
                self.metrics.assets_hash_match += 1;
            },
            .cooked => self.metrics.assets_cooked += 1,
            .dependency_changed => {},
            .errored => self.metrics.assets_errored += 1,
            .skipped => {},
        }
    }

    fn markPeak(self: *MetricsAccumulator) void {
        cook_metrics.markPeak(self.metrics, self.counting.peakRequestedBytes());
    }
};

const CookCacheUpdater = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,

    fn apply(self: *CookCacheUpdater, result: CookJobResult) !void {
        switch (result.cache_update) {
            .none => {},
            .source_mtime => |mtime| {
                if (self.cache.lookupEntryMut(result.entry)) |cache_entry| {
                    if (cache_entry.source_mtime != mtime) {
                        cache_entry.source_mtime = mtime;
                        self.cache.markDirty();
                    }
                }
            },
            .cooked => |cooked_size| try self.cacheCooked(result, cooked_size),
            .dependency_only => try self.cacheDependencyOnly(result),
            .errored => {
                try self.cacheErrored(result);
            },
        }
    }

    fn cacheDependencyOnly(self: *CookCacheUpdater, result: CookJobResult) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.init(self.allocator, self.io, result.entry, info, content_hash, "", 0),
        );
    }

    fn cacheCooked(self: *CookCacheUpdater, result: CookJobResult, cooked_size: u64) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        const output_path = result.output_path orelse return error.MissingOutputPath;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.init(self.allocator, self.io, result.entry, info, content_hash, output_path, cooked_size),
        );
    }

    fn cacheErrored(self: *CookCacheUpdater, result: CookJobResult) !void {
        const info = result.source_info orelse return error.MissingSourceSnapshot;
        const content_hash = result.content_hash orelse return error.MissingSourceSnapshot;
        try self.cache.upsertEntry(
            self.allocator,
            result.entry,
            try CacheEntry.initErrored(self.allocator, result.entry, info, content_hash),
        );
    }
};

const Completion = struct {
    index: SourceIndex,
    result: anyerror!CookJobResult,
};

const CompletionQueue = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: []Completion,
    len: usize = 0,

    fn push(self: *CompletionQueue, completion: Completion) void {
        self.mutex.lockUncancelable(self.io);
        self.items[self.len] = completion;
        self.len += 1;
        self.cond.signal(self.io);
        self.mutex.unlock(self.io);
    }

    fn pop(self: *CompletionQueue) Completion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.len == 0) {
            self.cond.waitUncancelable(self.io, &self.mutex);
        }

        self.len -= 1;
        return self.items[self.len];
    }
};

const QueuedCookJob = struct {
    index: SourceIndex,
    job: CookJob,
    completions: *CompletionQueue,

    pub fn execute(self: @This()) void {
        self.completions.push(.{ .index = self.index, .result = self.job.execute() });
    }
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    metrics: *CookMetrics,
    cache: *Cache,
    records: []const SourceRecord,
    dependencies: CsrGraph,
    dependents: CsrGraph,
    counting: *CountingAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *const CookContext,
        metrics: *CookMetrics,
        cache: *Cache,
        records: []const SourceRecord,
        dependencies: CsrGraph,
        dependents: CsrGraph,
        counting: *CountingAllocator,
    ) Executor {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .metrics = metrics,
            .cache = cache,
            .records = records,
            .dependencies = dependencies,
            .dependents = dependents,
            .counting = counting,
        };
    }

    pub fn run(self: *Executor, io: std.Io, progress: std.Progress.Node) !void {
        var scheduler = zob.Scheduler.init(io, self.allocator);
        defer scheduler.deinit();
        var cache_updater = CookCacheUpdater{
            .allocator = self.allocator,
            .io = self.ctx.io,
            .cache = self.cache,
        };
        var metrics_accumulator = MetricsAccumulator{
            .metrics = self.metrics,
            .counting = self.counting,
        };

        const cook_start = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        const cook_node = progress.start("Cooking assets", self.totalAssetCount());
        defer cook_node.end();

        const count = self.records.len;
        const remaining = try self.allocator.alloc(u32, count);
        defer self.allocator.free(remaining);

        const forced = try self.allocator.alloc(bool, count);
        defer self.allocator.free(forced);

        const completions = try self.allocator.alloc(Completion, count);
        defer self.allocator.free(completions);

        const futures = try self.allocator.alloc(zob.Future(void), count);
        defer self.allocator.free(futures);
        @memset(forced, false);

        var queue = CompletionQueue{ .io = io, .items = completions };
        var ready: std.ArrayList(SourceIndex) = .empty;
        defer ready.deinit(self.allocator);
        try ready.ensureTotalCapacity(self.allocator, count);
        for (remaining, 0..) |*degree, index| {
            degree.* = @intCast(self.dependencies.edgesFrom(@intCast(index)).len);
            if (degree.* == 0) {
                ready.appendAssumeCapacity(@intCast(index));
            }
        }

        var submitted: usize = 0;
        var completed: usize = 0;
        var ready_index: usize = 0;
        var first_error: ?anyerror = null;
        while (completed < count) {
            while (ready_index < ready.items.len) : (ready_index += 1) {
                const index = ready.items[ready_index];
                const record = &self.records[index];
                const queued = QueuedCookJob{
                    .index = index,
                    .job = .{
                        .allocator = self.allocator,
                        .ctx = self.ctx,
                        .cache = self.cache,
                        .record = record,
                        .force_recook = forced[index],
                        .cook_node = cook_node,
                    },
                    .completions = &queue,
                };
                futures[submitted] = scheduler.submit(QueuedCookJob, queued, .normal);
                submitted += 1;
            }

            if (submitted == completed) {
                return error.CycleDetected;
            }

            const completion = queue.pop();
            completed += 1;
            if (completion.result) |result| {
                metrics_accumulator.recordJobResult(result);
                cache_updater.apply(result) catch |err| {
                    if (first_error == null) {
                        first_error = err;
                    }
                };
                const changed = result.result == .cooked or result.result == .dependency_changed;

                for (self.dependents.edgesFrom(completion.index)) |dependent| {
                    if (changed) {
                        forced[dependent] = true;
                    }

                    remaining[dependent] -= 1;
                    if (remaining[dependent] == 0) {
                        ready.appendAssumeCapacity(dependent);
                    }
                }
                metrics_accumulator.markPeak();
            } else |err| {
                if (first_error == null) {
                    first_error = err;
                }

                for (self.dependents.edgesFrom(completion.index)) |dependent| {
                    remaining[dependent] -= 1;
                    if (remaining[dependent] == 0) {
                        ready.appendAssumeCapacity(dependent);
                    }
                }
            }
        }

        for (futures[0..submitted]) |*future| {
            future.await(io);
        }

        if (first_error) |err| {
            return err;
        }

        const cook_end = std.Io.Clock.Timestamp.now(self.ctx.io, .awake);
        self.metrics.cook_ns = @intCast(cook_start.durationTo(cook_end).raw.nanoseconds);
    }

    fn totalAssetCount(self: *const Executor) usize {
        return self.records.len;
    }
};

test "cooked file version mismatch invalidates only that cached output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const stale = wire.FileHeader.init(zmesh.MAGIC, zmesh.ZMESH_VERSION - 1, @sizeOf(wire.FileHeader));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mesh.zmesh", .data = std.mem.asBytes(&stale) });
    try std.testing.expect(!cookedFileIsCurrent(std.testing.io, tmp.dir, "mesh.zmesh", .mesh));

    const current = wire.FileHeader.init(zmesh.MAGIC, zmesh.ZMESH_VERSION, @sizeOf(wire.FileHeader));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mesh.zmesh", .data = std.mem.asBytes(&current) });
    try std.testing.expect(cookedFileIsCurrent(std.testing.io, tmp.dir, "mesh.zmesh", .mesh));
}

test "truncated cooked file is not current" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const header = wire.FileHeader.init(zmesh.MAGIC, zmesh.ZMESH_VERSION, 4096);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mesh.zmesh", .data = std.mem.asBytes(&header) });
    try std.testing.expect(!cookedFileIsCurrent(std.testing.io, tmp.dir, "mesh.zmesh", .mesh));
}
