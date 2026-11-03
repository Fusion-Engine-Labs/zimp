const std = @import("std");

const GLB_VERSION = 2;
const GLB_MAGIC = 0x46546C67; // ASCII for 'glTF'
const JSON_CHUNK = 0x4E4F534A; // ASCII for 'JSON'
const BIN_CHUNK = 0x004E4942; // ASCII for 'BIN\0'

const GLBHeader = struct {
    magic: u32,
    version: u32,
    length: u32,
};

const GLBChunk = struct {
    length: u32,
    type: u32,
    data: []const u8,
};

const GLBChunkHeader = struct {
    length: u32,
    type: u32,
};

pub const GLBResultError = error{
    FileToSmall,
    InvalidMagic,
    InvalidVersion,
    LengthMismatch,
    OutOfMemory,
};

inline fn processStruct(comptime T: type, file_bytes: []const u8, start: usize) T {
    return std.mem.bytesAsValue(T, file_bytes[start..][0..@sizeOf(T)]).*;
}

pub const GLBFile = struct {
    json: []const u8,
    bin: []const u8,

    pub fn parse(allocator: std.mem.Allocator, file_bytes: []const u8) GLBResultError!*GLBFile {
        if (file_bytes.len < @sizeOf(GLBHeader)) {
            return GLBResultError.FileToSmall;
        }

        const header = processStruct(GLBHeader, file_bytes, 0);
        if (header.magic != GLB_MAGIC) {
            return GLBResultError.InvalidMagic;
        }

        if (header.version != GLB_VERSION) {
            return GLBResultError.InvalidVersion;
        }

        if (header.length != file_bytes.len) {
            return GLBResultError.LengthMismatch;
        }

        const json_header = processStruct(GLBChunkHeader, file_bytes, @sizeOf(GLBHeader));
        if (json_header.type != JSON_CHUNK) {
            return GLBResultError.InvalidMagic;
        }

        const json_bytes = file_bytes[@sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) ..][0..json_header.length];

        const bin_start = @sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) + json_header.length;
        const bin_header = processStruct(GLBChunkHeader, file_bytes, bin_start);
        if (bin_header.type != BIN_CHUNK) {
            return GLBResultError.InvalidMagic;
        }

        const bin_bytes = file_bytes[bin_start + @sizeOf(GLBChunkHeader) ..][0..bin_header.length];

        const file = try allocator.create(GLBFile);
        file.* = GLBFile{
            .json = json_bytes,
            .bin = bin_bytes,
        };

        return file;
    }
};

const testing = std.testing;

fn glbSize(json_len: usize, bin_len: usize) usize {
    return @sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) + json_len + @sizeOf(GLBChunkHeader) + bin_len;
}

fn buildGlb(comptime json: []const u8, comptime bin: []const u8) [glbSize(json.len, bin.len)]u8 {
    const header_size = @sizeOf(GLBHeader);
    const chunk_header_size = @sizeOf(GLBChunkHeader);
    const total_length: u32 = @intCast(header_size + chunk_header_size + json.len + chunk_header_size + bin.len);

    var buf: [glbSize(json.len, bin.len)]u8 = undefined;
    var pos: usize = 0;

    // Header
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = GLB_MAGIC;
    pos += 4;
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = GLB_VERSION;
    pos += 4;
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = total_length;
    pos += 4;

    // JSON chunk
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = @intCast(json.len);
    pos += 4;
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = JSON_CHUNK;
    pos += 4;
    @memcpy(buf[pos..][0..json.len], json);
    pos += json.len;

    // BIN chunk
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = @intCast(bin.len);
    pos += 4;
    @as(*align(1) u32, @ptrCast(buf[pos..][0..4])).* = BIN_CHUNK;
    pos += 4;
    @memcpy(buf[pos..][0..bin.len], bin);

    return buf;
}

test "parse succeeds with valid glb" {
    const json = "{}";
    const bin = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f";
    const glb = buildGlb(json, bin);

    const file = try GLBFile.parse(testing.allocator, &glb);
    defer testing.allocator.destroy(file);

    try testing.expectEqualStrings("{}", file.json);
    try testing.expectEqualSlices(u8, bin, file.bin);
}

test "parse returns FileToSmall when input is too short" {
    const bytes = [_]u8{ 0x00, 0x01, 0x02 };
    const result = GLBFile.parse(testing.allocator, &bytes);
    try testing.expectError(GLBResultError.FileToSmall, result);
}

test "parse returns InvalidMagic with wrong magic number" {
    const bin: [16]u8 = @splat('\x00');
    var glb = buildGlb("{}", &bin);
    // Overwrite magic with garbage
    @as(*align(1) u32, @ptrCast(glb[0..4])).* = 0xDEADBEEF;

    const result = GLBFile.parse(testing.allocator, &glb);
    try testing.expectError(GLBResultError.InvalidMagic, result);
}

test "parse returns InvalidVersion with wrong version" {
    const bin: [16]u8 = @splat('\x00');
    var glb = buildGlb("{}", &bin);
    // Overwrite version with 1
    @as(*align(1) u32, @ptrCast(glb[4..8])).* = 1;

    const result = GLBFile.parse(testing.allocator, &glb);
    try testing.expectError(GLBResultError.InvalidVersion, result);
}

test "parse returns LengthMismatch when header length does not match file size" {
    const bin: [16]u8 = @splat('\x00');
    var glb = buildGlb("{}", &bin);
    // Overwrite length with wrong value
    @as(*align(1) u32, @ptrCast(glb[8..12])).* = 999;

    const result = GLBFile.parse(testing.allocator, &glb);
    try testing.expectError(GLBResultError.LengthMismatch, result);
}

test "parse returns InvalidMagic with wrong json chunk type" {
    const bin: [16]u8 = @splat('\x00');
    var glb = buildGlb("{}", &bin);
    // Overwrite JSON chunk type
    @as(*align(1) u32, @ptrCast(glb[16..20])).* = 0xDEADBEEF;

    const result = GLBFile.parse(testing.allocator, &glb);
    try testing.expectError(GLBResultError.InvalidMagic, result);
}

test "parse returns InvalidMagic with wrong bin chunk type" {
    const bin: [16]u8 = @splat('\x00');
    var glb = buildGlb("{}", &bin);
    // Overwrite BIN chunk type (after header + json chunk header + json data)
    const bin_type_offset = @sizeOf(GLBHeader) + @sizeOf(GLBChunkHeader) + 2 + 4;
    @as(*align(1) u32, @ptrCast(glb[bin_type_offset..][0..4])).* = 0xDEADBEEF;

    const result = GLBFile.parse(testing.allocator, &glb);
    try testing.expectError(GLBResultError.InvalidMagic, result);
}

test "parse correctly extracts json and bin slices" {
    const json = "[]";
    const bin = "\xFF\xFE\xFD\xFC\xFB\xFA\xF9\xF8\xF7\xF6\xF5\xF4\xF3\xF2\xF1\xF0";
    const glb = buildGlb(json, bin);

    const file = try GLBFile.parse(testing.allocator, &glb);
    defer testing.allocator.destroy(file);

    try testing.expectEqual(@as(usize, 2), file.json.len);
    try testing.expectEqual(@as(usize, 16), file.bin.len);
    try testing.expectEqualStrings("[]", file.json);
    try testing.expectEqualSlices(u8, bin, file.bin);
}
