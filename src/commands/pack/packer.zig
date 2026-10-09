//! Builds a `.zpak` from cooked files. Every asset is validated through its
//! view, every reference it holds must resolve to an asset of the right kind
//! in the pack, and assets big enough to matter are zstd-compressed in
//! parallel and stored compressed only when that pays.

const std = @import("std");
const zob = @import("zob");

const zpak = @import("../../formats/zpak.zig");
const zstd = @import("../../shared/zstd.zig");
const wire = @import("../../shared/wire.zig");
const file_read = @import("../../shared/file_read.zig");
const AtomicFile = @import("../../shared/atomic_file.zig").AtomicFile;
const runtime = @import("../../runtime.zig");
const AssetKind = @import("../../assets/asset.zig").AssetKind;
const AssetId = @import("../../id/id_types.zig").AssetId;
const log = @import("../../logger.zig");
const builtin_registry = @import("../../builtin/registry.zig");

pub const default_level: i32 = 19;

/// An asset is stored compressed only when that saves at least this
/// percentage of it and at least `min_saved_bytes`. Smaller savings barely
/// change the IO blocks read, but every load would still pay to decode.
pub const min_saved_percent: u64 = 10;
pub const min_saved_bytes: u64 = 4096;

/// Cooked bytes read per batch. Peak memory is about twice this plus the
/// largest asset, however big the pack is.
const batch_bytes: u64 = 64 * 1024 * 1024;

pub const Options = struct {
    /// zstd level, 1 to `zstd.max_level`.
    level: i32 = default_level,
    /// When false every asset is stored raw.
    compress: bool = true,
    /// Let references to engine builtins (`builtin/registry.zig`) of the
    /// builtin's own kind go unresolved. Directory-mode cooks never include
    /// the builtins, though their generated materials use the builtin
    /// shaders; project cooks do.
    allow_missing_builtins: bool = false,
};

pub const Input = struct {
    id: AssetId,
    kind: AssetKind,
    /// Normalized cooked path, relative to the cooked directory. Also the
    /// entry's name in the pack.
    path: []const u8,
};

pub const KindStats = struct {
    entries: u32 = 0,
    compressed: u32 = 0,
    asset_bytes: u64 = 0,
    stored_bytes: u64 = 0,

    fn add(self: *KindStats, other: KindStats) void {
        self.entries += other.entries;
        self.compressed += other.compressed;
        self.asset_bytes += other.asset_bytes;
        self.stored_bytes += other.stored_bytes;
    }
};

pub const Stats = struct {
    kinds: [zpak.kind_count]KindStats = @splat(.{}),
    file_bytes: u64 = 0,

    pub fn total(self: *const Stats) KindStats {
        var sum: KindStats = .{};
        for (self.kinds) |kind| sum.add(kind);
        return sum;
    }
};

pub fn worthCompressing(size: u64, compressed: u64) bool {
    if (compressed >= size) return false;
    const saved = size - compressed;
    return saved * 100 >= size * min_saved_percent and saved >= min_saved_bytes;
}

/// Packs `inputs`, read from `cooked_dir`, into `out_dir/out_path`, creating
/// its parent directories. The file is replaced atomically, so a pack mapped
/// by a running game stays intact.
pub fn writeFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    cooked_dir: std.Io.Dir,
    inputs: []Input,
    out_dir: std.Io.Dir,
    out_path: []const u8,
    options: Options,
) !Stats {
    if (std.fs.path.dirname(out_path)) |parent| try out_dir.createDirPath(io, parent);
    var pending = try AtomicFile.create(gpa, io, out_dir, out_path);
    defer pending.deinit();

    var buf: [64 * 1024]u8 = undefined;
    var file_writer = pending.file.writer(io, &buf);
    var stats: Stats = .{};
    const header = try write(gpa, io, cooked_dir, inputs, &file_writer.interface, options, &stats);
    try file_writer.interface.flush();
    try pending.file.writePositionalAll(io, std.mem.asBytes(&header), 0);
    try pending.commit();
    return stats;
}

/// Streams a pack of `inputs` to `out`, which must start at file offset 0.
/// Sorts `inputs` by (kind, id). Returns the header the caller must write over
/// the first `@sizeOf(zpak.Header)` bytes (see `zpak.Writer`).
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    cooked_dir: std.Io.Dir,
    inputs: []Input,
    out: *std.Io.Writer,
    options: Options,
    stats: *Stats,
) !zpak.Header {
    if (options.level < 1 or options.level > zstd.max_level) return error.InvalidLevel;
    std.mem.sort(Input, inputs, {}, inputLessThan);

    var writer = try zpak.Writer.init(gpa, out);
    defer writer.deinit();
    var refs: std.ArrayList(Ref) = .empty;
    defer refs.deinit(gpa);
    var scheduler = zob.Scheduler.initWithOptions(io, gpa, .{ .max_concurrency = std.Thread.getCpuCount() catch 1 });
    defer scheduler.deinit();

    var batch: std.ArrayList(Loaded) = .empty;
    defer {
        for (batch.items) |*loaded| loaded.deinit(gpa);
        batch.deinit(gpa);
    }

    var start: usize = 0;
    while (start < inputs.len) {
        var end = start;
        var read_bytes: u64 = 0;
        while (end < inputs.len and (end == start or read_bytes < batch_bytes)) : (end += 1) {
            try batch.ensureUnusedCapacity(gpa, 1);
            const loaded = try load(gpa, io, cooked_dir, inputs, @intCast(end), &refs);
            batch.appendAssumeCapacity(loaded);
            read_bytes += loaded.bytes.len;
        }
        if (options.compress) try compressBatch(gpa, io, &scheduler, batch.items, options.level);

        for (batch.items, inputs[start..end]) |*loaded, input| {
            const payload = choosePayload(loaded);
            try writer.add(.{ .id = input.id, .kind = input.kind, .name = input.path, .payload = payload });
            const kind = &stats.kinds[@intFromEnum(input.kind)];
            kind.entries += 1;
            kind.asset_bytes += loaded.bytes.len;
            kind.stored_bytes += switch (payload) {
                .none => |bytes| bytes.len,
                .zstd => |z| frameBytes(z.frames),
            };
            if (payload == .zstd) kind.compressed += 1;
        }
        for (batch.items) |*loaded| loaded.deinit(gpa);
        batch.clearRetainingCapacity();
        start = end;
    }

    try checkReferences(inputs, refs.items, options.allow_missing_builtins);
    const header = try writer.finish();
    stats.file_bytes = header.file_size;
    return header;
}

/// A cooked asset read into memory, plus its zstd frames once compressed.
const Loaded = struct {
    bytes: []align(wire.section_alignment) u8,
    /// One frame per `zpak.chunk_size` bytes; empty when not compressed.
    frames: [][]const u8 = &.{},
    frame_buf: []u8 = &.{},

    fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.frames);
        gpa.free(self.frame_buf);
        self.* = undefined;
    }
};

/// A reference from `inputs[from]` to an asset that must be in the pack.
const Ref = struct {
    kind: AssetKind,
    id: AssetId,
    from: u32,
};

fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    cooked_dir: std.Io.Dir,
    inputs: []const Input,
    index: u32,
    refs: *std.ArrayList(Ref),
) !Loaded {
    const input = inputs[index];
    const bytes = file_read.readFileAligned(gpa, io, cooked_dir, input.path) catch |err| {
        log.err("pack: cannot read '{s}': {s}", .{ input.path, @errorName(err) });
        return err;
    };
    errdefer gpa.free(bytes);
    const view = runtime.viewBytes(bytes, input.kind) catch |err| {
        log.err("pack: '{s}' is not a valid {s}: {s}", .{ input.path, @tagName(input.kind), @errorName(err) });
        return err;
    };
    switch (view) {
        .mesh => |mesh| for (0..mesh.materialSlotCount()) |i| {
            try refs.append(gpa, .{ .kind = .material, .id = mesh.materialSlot(i), .from = index });
        },
        .material => |material| {
            try refs.append(gpa, .{ .kind = .shader_stage, .id = material.vertex_shader, .from = index });
            try refs.append(gpa, .{ .kind = .shader_stage, .id = material.fragment_shader, .from = index });
            for (0..material.texture_slots.len) |i| {
                try refs.append(gpa, .{ .kind = .texture, .id = material.textureSlot(i).texture, .from = index });
            }
        },
        .texture, .shader => {},
    }
    return .{ .bytes = bytes };
}

const CompressJob = struct {
    level: i32,
    src: []const u8,
    dst: []u8,
    frame: *[]const u8,

    pub fn execute(self: CompressJob) anyerror!void {
        var encoder = try zstd.Encoder.init(self.level);
        defer encoder.deinit();
        self.frame.* = try encoder.compress(self.dst, self.src);
    }
};

/// Compresses every chunk of every asset in `batch` that could save
/// `min_saved_bytes`, in parallel. Chunks are independent, so the frames
/// don't depend on scheduling.
fn compressBatch(gpa: std.mem.Allocator, io: std.Io, scheduler: *zob.Scheduler, batch: []Loaded, level: i32) !void {
    var futures: std.ArrayList(zob.Future(anyerror!void)) = .empty;
    defer futures.deinit(gpa);
    var first_error: ?anyerror = null;

    // Every submitted job is awaited below, even if preparing a later one fails.
    submit: for (batch) |*loaded| {
        if (loaded.bytes.len <= min_saved_bytes) continue;
        const size: u32 = @intCast(loaded.bytes.len);
        const chunks = zpak.chunkCount(size);
        const stride = zstd.compressBound(zpak.chunk_size);
        prepare(gpa, &futures, loaded, chunks, stride) catch |err| {
            first_error = err;
            break :submit;
        };
        for (0..chunks) |k| {
            const chunk: u32 = @intCast(k);
            const future = scheduler.trySubmit(CompressJob, .{
                .level = level,
                .src = loaded.bytes[k * zpak.chunk_size ..][0..zpak.chunkLen(size, chunk)],
                .dst = loaded.frame_buf[k * stride ..][0..stride],
                .frame = &loaded.frames[k],
            }, .normal) catch |err| {
                first_error = err;
                break :submit;
            };
            futures.appendAssumeCapacity(future);
        }
    }
    for (futures.items) |*future| {
        future.await(io) catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    if (first_error) |err| return err;
}

fn prepare(gpa: std.mem.Allocator, futures: *std.ArrayList(zob.Future(anyerror!void)), loaded: *Loaded, chunks: u32, stride: usize) !void {
    try futures.ensureUnusedCapacity(gpa, chunks);
    loaded.frames = try gpa.alloc([]const u8, chunks);
    errdefer {
        gpa.free(loaded.frames);
        loaded.frames = &.{};
    }
    loaded.frame_buf = try gpa.alloc(u8, stride * chunks);
}

fn choosePayload(loaded: *const Loaded) zpak.Writer.Payload {
    if (loaded.frames.len > 0 and worthCompressing(loaded.bytes.len, frameBytes(loaded.frames))) {
        return .{ .zstd = .{ .size = @intCast(loaded.bytes.len), .frames = loaded.frames } };
    }
    return .{ .none = loaded.bytes };
}

fn frameBytes(frames: []const []const u8) u64 {
    var total: u64 = 0;
    for (frames) |frame| total += frame.len;
    return total;
}

fn inputLessThan(_: void, a: Input, b: Input) bool {
    return orderInput(a.kind, a.id, b) == .lt;
}

fn orderInput(kind: AssetKind, id: AssetId, input: Input) std.math.Order {
    if (kind != input.kind) return std.math.order(@intFromEnum(kind), @intFromEnum(input.kind));
    return std.mem.order(u8, &id.uuid.bytes, &input.id.uuid.bytes);
}

/// Fails if any asset references one that isn't in the pack with the kind
/// the reference expects. `inputs` must be sorted.
fn checkReferences(inputs: []const Input, refs: []const Ref, allow_missing_builtins: bool) !void {
    var missing: usize = 0;
    var missing_builtins: usize = 0;
    for (refs) |ref| {
        const Context = struct { kind: AssetKind, id: AssetId };
        const found = std.sort.binarySearch(Input, inputs, Context{ .kind = ref.kind, .id = ref.id }, struct {
            fn compare(context: Context, input: Input) std.math.Order {
                return orderInput(context.kind, context.id, input);
            }
        }.compare);
        if (found != null) continue;
        if (allow_missing_builtins and builtin_registry.kindOf(ref.id) == ref.kind) {
            missing_builtins += 1;
            continue;
        }
        missing += 1;
        log.err("pack: '{s}' references {s} {f}, which is not in the pack", .{ inputs[ref.from].path, @tagName(ref.kind), ref.id });
    }
    if (missing_builtins > 0) log.info("pack: {d} references to engine builtins left unresolved; a directory-mode cook doesn't include them", .{missing_builtins});
    if (missing > 0) return error.DanglingReference;
}

const testing = std.testing;
const zmesh = @import("../../formats/zmesh.zig");
const pack_store = @import("../../runtime/pack_store.zig");
const PackStore = runtime.PackStore;

test "worthCompressing needs both 10% and 4 KiB saved" {
    try testing.expect(worthCompressing(100_000, 50_000));
    try testing.expect(!worthCompressing(100_000, 91_000)); // 9%
    try testing.expect(!worthCompressing(30_000, 26_000)); // 13%, but < 4 KiB
    try testing.expect(worthCompressing(40_960, 36_864)); // exactly 10% and 4 KiB
    try testing.expect(!worthCompressing(1000, 1000));
    try testing.expect(!worthCompressing(1000, 2000));
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    shader: []u8,

    const big_shader_id = AssetId.parseComptime("cccccccc-cccc-4ccc-8ccc-cccccccccccc");
    const small_shader_id = AssetId.parseComptime("dddddddd-dddd-4ddd-8ddd-dddddddddddd");

    /// A raw mesh whose material slot points at `zmesh.test_material_id`,
    /// which these fixtures don't include, plus a big and a small shader.
    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "cooked/meshes");
        try tmp.dir.createDirPath(testing.io, "cooked/shaders");
        var mesh_buf: [4096]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "cooked/meshes/m.zmesh", .data = try pack_store.testMeshBytes(&mesh_buf) });
        const shader = try pack_store.testShaderBytes(zpak.chunk_size + 5000);
        errdefer testing.allocator.free(shader);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "cooked/shaders/big.vert.zshdr", .data = shader });
        const small = try pack_store.testShaderBytes(64);
        defer testing.allocator.free(small);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "cooked/shaders/small.vert.zshdr", .data = small });
        return .{ .tmp = tmp, .shader = shader };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.shader);
        self.tmp.cleanup();
    }

    fn pack(self: *Fixture, inputs: []Input, out_path: []const u8, options: Options) !Stats {
        const cooked = try self.tmp.dir.openDir(testing.io, "cooked", .{});
        defer cooked.close(testing.io);
        return writeFile(testing.allocator, testing.io, cooked, inputs, self.tmp.dir, out_path, options);
    }

    fn shaderInputs() [2]Input {
        return .{
            .{ .id = small_shader_id, .kind = .shader_stage, .path = "shaders/small.vert.zshdr" },
            .{ .id = big_shader_id, .kind = .shader_stage, .path = "shaders/big.vert.zshdr" },
        };
    }
};

test "writeFile packs, compresses what pays, and loads back" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var inputs = Fixture.shaderInputs();
    const stats = try fixture.pack(&inputs, "out/assets.zpak", .{ .level = 3 });

    const shaders = stats.kinds[@intFromEnum(AssetKind.shader_stage)];
    try testing.expectEqual(@as(u32, 2), shaders.entries);
    try testing.expectEqual(@as(u32, 1), shaders.compressed);
    try testing.expect(shaders.stored_bytes < shaders.asset_bytes);

    var store = try PackStore.open(testing.io, fixture.tmp.dir, "out/assets.zpak");
    defer store.close(testing.io);
    try testing.expectEqual(stats.file_bytes, store.map.memory.len);
    const big = store.pak.findKind(.shader_stage, Fixture.big_shader_id).?;
    try testing.expectEqual(zpak.Codec.zstd, store.pak.codecAt(big));
    try testing.expectEqualStrings("shaders/big.vert.zshdr", store.pak.nameAt(big));
    var asset = try store.load(testing.allocator, testing.io, big);
    defer asset.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, fixture.shader, asset.bytes);
    // Too small to save 4 KiB, so stored raw.
    try testing.expectEqual(zpak.Codec.none, store.pak.codecAt(store.pak.find(Fixture.small_shader_id).?));
}

test "writeFile output is deterministic and --no-compress stores everything raw" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var inputs = Fixture.shaderInputs();
    _ = try fixture.pack(&inputs, "a.zpak", .{ .level = 3 });
    _ = try fixture.pack(&inputs, "b.zpak", .{ .level = 3 });
    const a = try fixture.tmp.dir.readFileAlloc(testing.io, "a.zpak", testing.allocator, .unlimited);
    defer testing.allocator.free(a);
    const b = try fixture.tmp.dir.readFileAlloc(testing.io, "b.zpak", testing.allocator, .unlimited);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);

    const stats = try fixture.pack(&inputs, "raw.zpak", .{ .compress = false });
    try testing.expectEqual(@as(u32, 0), stats.total().compressed);
    try testing.expectEqual(stats.total().asset_bytes, stats.total().stored_bytes);
}

test "allow_missing_builtins lets only builtin references go unresolved" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var mesh_buf: [4096]u8 = undefined;
    var mesh_writer = std.Io.Writer.fixed(&mesh_buf);
    try zmesh.writeTestZmeshFileWithMaterial(&mesh_writer, builtin_registry.error_material_id);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "cooked/meshes/builtin.zmesh", .data = mesh_writer.buffered() });

    var builtin_ref = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .mesh, .path = "meshes/builtin.zmesh" }};
    try testing.expectError(error.DanglingReference, fixture.pack(&builtin_ref, "x.zpak", .{}));
    _ = try fixture.pack(&builtin_ref, "x.zpak", .{ .allow_missing_builtins = true });

    var project_ref = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .mesh, .path = "meshes/m.zmesh" }};
    try testing.expectError(error.DanglingReference, fixture.pack(&project_ref, "y.zpak", .{ .allow_missing_builtins = true }));

    // A builtin id used as the wrong kind (a shader as a material) is still dangling.
    mesh_writer = std.Io.Writer.fixed(&mesh_buf);
    try zmesh.writeTestZmeshFileWithMaterial(&mesh_writer, builtin_registry.idFor(builtin_registry.PREFIX ++ "standard.vert"));
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "cooked/meshes/wrong.zmesh", .data = mesh_writer.buffered() });
    var wrong_kind = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .mesh, .path = "meshes/wrong.zmesh" }};
    try testing.expectError(error.DanglingReference, fixture.pack(&wrong_kind, "z.zpak", .{ .allow_missing_builtins = true }));
}

test "writeFile rejects dangling references, invalid assets, and bad levels without writing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    // The mesh's material is not in the pack.
    var dangling = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .mesh, .path = "meshes/m.zmesh" }};
    try testing.expectError(error.DanglingReference, fixture.pack(&dangling, "x.zpak", .{}));

    // A shader packed under the wrong kind fails its view.
    var wrong_kind = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .texture, .path = "shaders/big.vert.zshdr" }};
    try testing.expectError(error.InvalidMagic, fixture.pack(&wrong_kind, "x.zpak", .{}));

    var missing = [_]Input{.{ .id = Fixture.big_shader_id, .kind = .texture, .path = "nope.ztex" }};
    try testing.expectError(error.FileNotFound, fixture.pack(&missing, "x.zpak", .{}));

    var inputs = Fixture.shaderInputs();
    try testing.expectError(error.InvalidLevel, fixture.pack(&inputs, "x.zpak", .{ .level = 23 }));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "x.zpak", .{}));
}
