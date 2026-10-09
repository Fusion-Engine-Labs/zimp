const std = @import("std");
const builtin = @import("builtin");

const runtime = @import("../runtime.zig");
const zpak = @import("../formats/zpak.zig");
const zstd = @import("../shared/zstd.zig");
const wire = @import("../shared/wire.zig");
const AssetKind = @import("../assets/asset.zig").AssetKind;
const AssetId = @import("../id/id_types.zig").AssetId;

/// A memory-mapped `.zpak`. Raw entries load as views straight into the
/// mapping; zstd entries are decoded into a heap buffer. Safe to `load`
/// from several threads at once.
///
/// Assets loaded from raw entries borrow the mapping, so they must be freed
/// before `close`. Replace a pack file atomically (as `zimp pack` does), never
/// in place: truncating a mapped file faults readers.
pub const PackStore = struct {
    map: std.Io.File.MemoryMap,
    pak: zpak.ZPak,
    decoders: DecoderPool = .{},

    pub fn open(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !PackStore {
        const file = try dir.openFile(io, sub_path, .{});
        defer file.close(io);
        return mapFile(io, file);
    }

    /// Maps `file` and validates the table of contents. The caller keeps
    /// ownership of `file` and may close it right away.
    pub fn mapFile(io: std.Io, file: std.Io.File) !PackStore {
        const len = try file.length(io);
        // A zero-length mapping is invalid, and nothing that short is a pack.
        if (len < @sizeOf(zpak.Header)) return error.Truncated;
        const size = std.math.cast(usize, len) orelse return error.PackTooLarge;
        var map = try std.Io.File.MemoryMap.create(io, file, .{
            .len = size,
            .protection = .{ .read = true },
            // Pages are faulted in per asset on load, not the whole pack up front.
            .populate = false,
        });
        errdefer map.destroy(io);
        return .{ .map = map, .pak = try zpak.ZPak.view(map.memory) };
    }

    pub fn close(self: *PackStore, io: std.Io) void {
        self.decoders.deinit();
        self.map.destroy(io);
        self.* = undefined;
    }

    /// Loads entry `index`. A raw entry's pages are faulted in here, on the
    /// calling thread, so whoever reads the asset next (for a texture, the
    /// GL upload on the main thread) never stalls on page faults or disk reads.
    pub fn load(self: *PackStore, gpa: std.mem.Allocator, io: std.Io, index: u32) !runtime.Asset {
        const kind = self.pak.kindAt(index);
        switch (self.pak.codecAt(index)) {
            .none => {
                const bytes = self.pak.rawBytes(index);
                adviseWillNeed(bytes);
                prefault(bytes);
                return .{ .bytes = bytes, .view = try runtime.viewBytes(bytes, kind) };
            },
            .zstd => {
                adviseWillNeed(self.pak.payload(index));
                const bytes = try gpa.alignedAlloc(u8, wire.alignment, self.pak.entries[index].size);
                self.decode(io, index, bytes) catch |err| {
                    gpa.free(bytes);
                    return err;
                };
                // Frees `bytes` itself if they don't validate.
                return .fromOwned(gpa, bytes, kind);
            },
        }
    }

    /// Decodes every frame of zstd entry `index` into `out`, which must be
    /// exactly the entry's size.
    pub fn decode(self: *PackStore, io: std.Io, index: u32, out: []u8) !void {
        const size = self.pak.entries[index].size;
        std.debug.assert(out.len == size);
        var decoder = try self.decoders.acquire(io);
        defer self.decoders.release(io, decoder);
        for (0..zpak.chunkCount(size)) |k| {
            const chunk: u32 = @intCast(k);
            const start = @as(usize, chunk) * zpak.chunk_size;
            try decoder.decompress(out[start..][0..zpak.chunkLen(size, chunk)], self.pak.frame(index, chunk));
        }
    }
};

/// Reuses decoder contexts across loads; each holds ~100 KiB of tables.
/// Grows to the number of threads that decode at once.
const DecoderPool = struct {
    mutex: std.Io.Mutex = .init,
    idle: [max_idle]zstd.Decoder = undefined,
    idle_len: usize = 0,

    const max_idle = 16;

    fn acquire(self: *DecoderPool, io: std.Io) !zstd.Decoder {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.idle_len > 0) {
                self.idle_len -= 1;
                return self.idle[self.idle_len];
            }
        }
        return zstd.Decoder.init();
    }

    fn release(self: *DecoderPool, io: std.Io, decoder: zstd.Decoder) void {
        var owned = decoder;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.idle_len == max_idle) return owned.deinit();
        self.idle[self.idle_len] = owned;
        self.idle_len += 1;
    }

    fn deinit(self: *DecoderPool) void {
        for (self.idle[0..self.idle_len]) |*decoder| decoder.deinit();
        self.idle_len = 0;
    }
};

const can_advise = builtin.os.tag.isDarwin() or builtin.os.tag.isBSD() or builtin.os.tag == .linux;

/// Asks the kernel to read a large payload's pages ahead in one go, rather
/// than one fault at a time as they are touched. It also makes warm loads
/// faster: on macOS, a 4 MiB raw texture load dropped from 113 to 88 µs.
/// Small payloads skip it; the syscall would cost more than their faults.
fn adviseWillNeed(bytes: []const u8) void {
    if (!can_advise or bytes.len < zpak.large_payload_bytes) return;
    const page = std.heap.pageSize();
    const start = std.mem.alignBackward(usize, @intFromPtr(bytes.ptr), page);
    const end = std.mem.alignForward(usize, @intFromPtr(bytes.ptr) + bytes.len, page);
    std.posix.madvise(@ptrFromInt(start), end - start, std.posix.MADV.WILLNEED) catch {};
}

/// Reads one byte per page so every page of `bytes` is mapped.
fn prefault(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const page = std.heap.pageSize();
    var sum: u8 = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += page) sum +%= @as(*const volatile u8, &bytes[i]).*;
    sum +%= @as(*const volatile u8, &bytes[bytes.len - 1]).*;
    std.mem.doNotOptimizeAway(sum);
}

const testing = std.testing;
const zmesh = @import("../formats/zmesh.zig");
const zshdr = @import("../formats/zshdr.zig");

pub const TestItem = struct {
    id: AssetId,
    kind: AssetKind,
    name: []const u8,
    bytes: []const u8,
    compress: bool = false,
};

/// Writes `items` (already in (kind, id) order) as a pack at `dir/sub_path`.
/// Compressed items are split into real zstd frames.
pub fn writeTestPack(dir: std.Io.Dir, sub_path: []const u8, items: []const TestItem) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer = try zpak.Writer.init(testing.allocator, &out.writer);
    defer writer.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var encoder = try zstd.Encoder.init(19);
    defer encoder.deinit();

    for (items) |item| {
        if (!item.compress) {
            try writer.add(.{ .id = item.id, .kind = item.kind, .name = item.name, .payload = .{ .none = item.bytes } });
            continue;
        }
        const size: u32 = @intCast(item.bytes.len);
        const frames = try arena.allocator().alloc([]const u8, zpak.chunkCount(size));
        for (frames, 0..) |*frame, k| {
            const src = item.bytes[k * zpak.chunk_size ..][0..zpak.chunkLen(size, @intCast(k))];
            const dst = try arena.allocator().alloc(u8, zstd.compressBound(src.len));
            frame.* = try encoder.compress(dst, src);
        }
        try writer.add(.{ .id = item.id, .kind = item.kind, .name = item.name, .payload = .{ .zstd = .{ .size = size, .frames = frames } } });
    }
    const header = try writer.finish();
    const bytes = out.written();
    @memcpy(bytes[0..@sizeOf(zpak.Header)], std.mem.asBytes(&header));
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = bytes });
}

/// A valid shader whose body is `body_len` bytes of repetitive text, so it
/// compresses well. Caller frees.
pub fn testShaderBytes(body_len: usize) ![]u8 {
    const body = try testing.allocator.alloc(u8, body_len);
    defer testing.allocator.free(body);
    const line = "// filler for compression\n";
    for (body, 0..) |*b, i| b.* = line[i % line.len];
    body[body.len - 1] = '\n';

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try zshdr.write(&out.writer, .{ .stage = .vertex, .variant_names = &.{}, .prologue = "#version 330 core\n", .body = body });
    return out.toOwnedSlice();
}

pub fn testMeshBytes(buf: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try zmesh.writeTestZmeshFile(&writer);
    return writer.buffered();
}

pub const test_mesh_id = AssetId.parseComptime("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
pub const test_shader_id = AssetId.parseComptime("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");

const TestPack = struct {
    tmp: std.testing.TmpDir,
    shader: []u8,

    fn init() !TestPack {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var mesh_buf: [4096]u8 = undefined;
        const mesh = try testMeshBytes(&mesh_buf);
        // Three frames, the last one short.
        const shader = try testShaderBytes(2 * zpak.chunk_size + 1000);
        errdefer testing.allocator.free(shader);
        try writeTestPack(tmp.dir, "assets.zpak", &.{
            .{ .id = test_mesh_id, .kind = .mesh, .name = "meshes/test.zmesh", .bytes = mesh },
            .{ .id = test_shader_id, .kind = .shader_stage, .name = "shaders/test.vert.zshdr", .bytes = shader, .compress = true },
        });
        return .{ .tmp = tmp, .shader = shader };
    }

    fn deinit(self: *TestPack) void {
        testing.allocator.free(self.shader);
        self.tmp.cleanup();
    }
};

test "PackStore views raw entries inside the mapping and decodes zstd entries" {
    var fixture = try TestPack.init();
    defer fixture.deinit();
    var store = try PackStore.open(testing.io, fixture.tmp.dir, "assets.zpak");
    defer store.close(testing.io);

    const mesh_index = store.pak.findKind(.mesh, test_mesh_id).?;
    var mesh = try store.load(testing.allocator, testing.io, mesh_index);
    defer mesh.deinit(testing.allocator);
    try testing.expect(mesh.owned == null);
    try testing.expect(mesh.view == .mesh);
    const map_start = @intFromPtr(store.map.memory.ptr);
    try testing.expect(@intFromPtr(mesh.bytes.ptr) >= map_start and @intFromPtr(mesh.bytes.ptr) < map_start + store.map.memory.len);

    const shader_index = store.pak.find(test_shader_id).?;
    try testing.expectEqual(zpak.Codec.zstd, store.pak.codecAt(shader_index));
    try testing.expectEqual(@as(u32, 3), zpak.chunkCount(store.pak.entries[shader_index].size));
    var shader = try store.load(testing.allocator, testing.io, shader_index);
    defer shader.deinit(testing.allocator);
    try testing.expect(shader.owned != null);
    try testing.expect(shader.view == .shader);
    try testing.expectEqualSlices(u8, fixture.shader, shader.bytes);
}

test "PackStore decodes concurrently with pooled decoders" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var fixture = try TestPack.init();
    defer fixture.deinit();
    var store = try PackStore.open(testing.io, fixture.tmp.dir, "assets.zpak");
    defer store.close(testing.io);

    const Worker = struct {
        fn run(s: *PackStore, expected: []const u8, failed: *std.atomic.Value(bool)) void {
            const index = s.pak.find(test_shader_id).?;
            for (0..20) |_| {
                var asset = s.load(std.heap.page_allocator, testing.io, index) catch {
                    failed.store(true, .monotonic);
                    return;
                };
                defer asset.deinit(std.heap.page_allocator);
                if (!std.mem.eql(u8, expected, asset.bytes)) failed.store(true, .monotonic);
            }
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, fixture.shader, &failed });
    for (threads) |thread| thread.join();
    try testing.expect(!failed.load(.monotonic));
    try testing.expect(store.decoders.idle_len >= 1 and store.decoders.idle_len <= threads.len);
}

test "PackStore frees a zstd entry that decodes but fails validation exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid frames whose contents aren't a cooked shader.
    var junk: [8192]u8 = undefined;
    for (&junk, 0..) |*b, i| b.* = @truncate(i % 7);
    try writeTestPack(tmp.dir, "junk.zpak", &.{
        .{ .id = test_shader_id, .kind = .shader_stage, .name = "shaders/junk.zshdr", .bytes = &junk, .compress = true },
    });
    var store = try PackStore.open(testing.io, tmp.dir, "junk.zpak");
    defer store.close(testing.io);
    try testing.expectEqual(zpak.Codec.zstd, store.pak.codecAt(0));
    // testing.allocator reports a double free or a leak.
    try testing.expectError(error.InvalidMagic, store.load(testing.allocator, testing.io, 0));
}

test "PackStore rejects missing, empty, and corrupt packs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.FileNotFound, PackStore.open(testing.io, tmp.dir, "missing.zpak"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "empty.zpak", .data = "" });
    try testing.expectError(error.Truncated, PackStore.open(testing.io, tmp.dir, "empty.zpak"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "junk.zpak", .data = "not a pack, just some bytes long enough for a header" });
    try testing.expectError(error.InvalidMagic, PackStore.open(testing.io, tmp.dir, "junk.zpak"));
}

test "PackStore reports corrupt frames and invalid payloads on load" {
    var fixture = try TestPack.init();
    defer fixture.deinit();
    const bytes = try fixture.tmp.dir.readFileAlloc(testing.io, "assets.zpak", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);

    // Break the magic of the shader's second frame and of the raw mesh.
    const aligned = try testing.allocator.alignedAlloc(u8, wire.alignment, bytes.len);
    defer testing.allocator.free(aligned);
    @memcpy(aligned, bytes);
    const pak = try zpak.ZPak.view(aligned);
    const shader_index = pak.find(test_shader_id).?;
    const frame = pak.frame(shader_index, 1);
    const frame_at = @intFromPtr(frame.ptr) - @intFromPtr(aligned.ptr);
    @memset(bytes[frame_at..][0..4], 0xff);
    bytes[@intCast(pak.entries[pak.find(test_mesh_id).?].offset)] = 'X';
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "corrupt.zpak", .data = bytes });

    var store = try PackStore.open(testing.io, fixture.tmp.dir, "corrupt.zpak");
    defer store.close(testing.io);
    try testing.expectError(error.CorruptPayload, store.load(testing.allocator, testing.io, shader_index));
    try testing.expectError(error.InvalidMagic, store.load(testing.allocator, testing.io, store.pak.find(test_mesh_id).?));
}
