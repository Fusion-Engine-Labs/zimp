const std = @import("std");

const CountingAllocator = @import("../../shared/counting_allocator.zig").CountingAllocator;
const ProjectCookInfo = @import("context.zig").ProjectCookInfo;
const CookMetrics = @import("../cook_metrics.zig").CookMetrics;
const manifest_builder = @import("../../manifest/builder.zig");
const manifest_codec = @import("../../manifest/codec.zig");
const Publisher = @import("../../builtin/publisher.zig");
const cache_session_mod = @import("cache_session.zig");
const CookContext = @import("context.zig").CookContext;
const Cache = @import("../../cache/cache.zig").Cache;
const cook_metrics = @import("../cook_metrics.zig");
const model = @import("../../manifest/model.zig");
const Executor = @import("executor.zig").Executor;
const planner = @import("planner.zig");
const log = @import("../../logger.zig");

pub fn run(
    allocator: std.mem.Allocator,
    counting: *CountingAllocator,
    ctx: *const CookContext,
    progress: std.Progress.Node,
) !CookMetrics {
    var metrics: CookMetrics = .{};
    const total_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);

    {
        var cache_session = try cache_session_mod.CacheSession.open(allocator, ctx);
        defer cache_session.deinit(allocator);
        cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

        {
            // Also drops deleted sources from the cache.
            var plan = try planner.build(allocator, ctx, &cache_session.cache, &metrics);
            defer plan.deinit(allocator);
            cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

            var executor = Executor.init(
                allocator,
                ctx,
                &metrics,
                &cache_session.cache,
                plan.records.items,
                plan.dependencies,
                plan.dependents,
                counting,
            );
            try executor.run(ctx.io, progress);

            const cache_write_start = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            metrics.cache_bytes_written = try cache_session.persist(allocator, ctx);
            const cache_write_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
            metrics.cache_write_ns = @intCast(cache_write_start.durationTo(cache_write_end).raw.nanoseconds);

            if (ctx.project) |proj| {
                var publisher = try Publisher.publish(allocator, ctx);
                defer publisher.deinit(allocator);

                const builtin_entries = try publisher.manifestEntries(allocator);
                defer allocator.free(builtin_entries);

                try buildAndWriteManifest(
                    allocator,
                    ctx,
                    proj,
                    &cache_session.cache,
                    builtin_entries,
                );
            }
        }

        metrics.pipeline_live_bytes = counting.currentRequestedBytes();
        cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());
    }

    metrics.ending_allocated_bytes = counting.currentRequestedBytes();
    const total_end = std.Io.Clock.Timestamp.now(ctx.io, .awake);
    metrics.total_ns = @intCast(total_start.durationTo(total_end).raw.nanoseconds);
    cook_metrics.markPeak(&metrics, counting.peakRequestedBytes());

    return metrics;
}

fn buildAndWriteManifest(
    allocator: std.mem.Allocator,
    ctx: *const CookContext,
    proj: ProjectCookInfo,
    cache: *const Cache,
    builtin_entries: []const model.AssetManifestEntry,
) !void {
    var stats = manifest_builder.BuildStats{};
    var manifest = try manifest_builder.build(allocator, .{
        .project_id = proj.project_id,
        .cache = cache,
        .builtin_entries = builtin_entries,
    }, &stats);
    defer manifest.deinit();

    try manifest_codec.writeToDir(allocator, ctx.io, proj.root_dir, proj.manifest_path, &manifest);

    log.info("Asset manifest: {d} entries ({d} builtin);", .{
        stats.entries,
        stats.builtin_entries,
    });
}
