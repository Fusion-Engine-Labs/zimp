const std = @import("std");

const CookContext = @import("../commands/cook/context.zig").CookContext;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const AtomicFile = @import("../shared/atomic_file.zig").AtomicFile;
const asset_registry = @import("../assets/asset_registry.zig");
const CookInput = @import("../cookers/cooker.zig").CookInput;
const AssetKind = @import("../assets/asset.zig").AssetKind;
const builtin_registry = @import("registry.zig");
const model = @import("../manifest/model.zig");

pub const PublishedAsset = struct {
    manifest_entry: model.AssetManifestEntry,
    owned_cooked_path: []const u8,

    fn deinit(self: *PublishedAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_cooked_path);
    }
};

const Publisher = @This();

items: []PublishedAsset,

pub fn publish(allocator: std.mem.Allocator, ctx: *const CookContext) !Publisher {
    var items = try allocator.alloc(PublishedAsset, builtin_registry.assets.len);
    var len: usize = 0;
    errdefer {
        for (0..len) |i| {
            items[i].deinit(allocator);
        }
        allocator.free(items);
    }

    for (builtin_registry.assets, 0..) |asset, i| {
        items[i] = try publishOne(allocator, ctx, asset);
        len += 1;
    }

    return .{
        .items = items,
    };
}

pub fn deinit(self: *Publisher, allocator: std.mem.Allocator) void {
    for (self.items) |*item| {
        item.deinit(allocator);
    }
    allocator.free(self.items);
}

pub fn manifestEntries(self: *const Publisher, allocator: std.mem.Allocator) ![]const model.AssetManifestEntry {
    const entries = try allocator.alloc(model.AssetManifestEntry, self.items.len);
    for (self.items, entries) |item, *entry| {
        entry.* = item.manifest_entry;
    }

    return entries;
}

fn publishOne(allocator: std.mem.Allocator, ctx: *const CookContext, asset: builtin_registry.Source) !PublishedAsset {
    const source_file = SourceFile.fromPath(asset.path);
    const descriptor = asset_registry.descriptorForSource(source_file);
    const cooker = descriptor.cooker orelse return error.BuiltinMissingCooker;
    const kind = source_file.assetKind() orelse return error.BuiltinMissingKind;

    const cooked_path = try cooker.outputPath(allocator, source_file);
    errdefer allocator.free(cooked_path);

    if (std.fs.path.dirname(cooked_path)) |parent| {
        try ctx.output.createDirPath(ctx.io, parent);
    }

    var pending = try AtomicFile.create(
        allocator,
        ctx.io,
        ctx.output,
        cooked_path,
    );
    defer pending.deinit();

    var buffer: [8192]u8 = undefined;
    var writer = pending.file.writer(ctx.io, &buffer);

    const input = CookInput{
        .allocator = allocator,
        .io = ctx.io,
        .source_dir = ctx.source,
        .project_id = ctx.projectId(),
        .source = source_file,
        .bytes = asset.bytes,
        .writer = &writer.interface,
    };

    try cooker.cook(&input);
    try writer.interface.flush();

    const cooked_state = try pending.file.stat(ctx.io);
    try pending.commit();

    return .{
        .owned_cooked_path = cooked_path,
        .manifest_entry = .{
            .id = builtin_registry.idFor(asset.path),
            .kind = kind,
            .source_path = asset.path,
            .cooked_path = cooked_path,
            .content_hash = asset.hashBytes(),
            .source_size = asset.bytes.len,
            .cooked_size = cooked_state.size,
            .generated = false,
        },
    };
}
