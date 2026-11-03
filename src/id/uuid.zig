const std = @import("std");

pub const ParseError = error{
    InvalidUuid,
};

pub const Uuid = struct {
    bytes: [16]u8,

    pub const zero: Uuid = .{ .bytes = @splat(0) };

    pub fn v4(random: std.Random) Uuid {
        var id: Uuid = .{ .bytes = undefined };
        random.bytes(&id.bytes);
        id.bytes[6] = (id.bytes[6] & 0x0f) | 0x40;
        id.bytes[8] = (id.bytes[8] & 0x3f) | 0x80;
        return id;
    }

    /// Deterministic UUID from (namespace, name): SHA-256 truncated to 16
    /// bytes, RFC-4122 shaped (version nibble 8 = "custom", canonical
    /// variant bits). Same inputs produce the same id forever, on every
    /// machine — the algorithm is frozen by a golden test and must never
    /// change once ids derived from it have been persisted.
    pub fn deriveV8(namespace: Uuid, name: []const u8) Uuid {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&namespace.bytes);
        hasher.update(name);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        var id: Uuid = .{ .bytes = digest[0..16].* };
        id.bytes[6] = (id.bytes[6] & 0x0f) | 0x80; // version 8
        id.bytes[8] = (id.bytes[8] & 0x3f) | 0x80; // RFC variant
        return id;
    }

    pub fn fromBytes(bytes: [16]u8) Uuid {
        return .{ .bytes = bytes };
    }

    pub fn eql(self: Uuid, other: Uuid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    pub fn isZero(self: Uuid) bool {
        return self.eql(zero);
    }

    pub fn toString(self: Uuid) [36]u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        var out: [36]u8 = undefined;
        @memcpy(out[0..8], hex[0..8]);
        out[8] = '-';
        @memcpy(out[9..13], hex[8..12]);
        out[13] = '-';
        @memcpy(out[14..18], hex[12..16]);
        out[18] = '-';
        @memcpy(out[19..23], hex[16..20]);
        out[23] = '-';
        @memcpy(out[24..36], hex[20..32]);
        return out;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Uuid {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        return switch (token) {
            .string => |text| parse(text) catch error.UnexpectedToken,
            .allocated_string => |text| {
                defer allocator.free(text);
                return parse(text) catch error.UnexpectedToken;
            },
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Uuid {
        return switch (source) {
            .string => |text| parse(text) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonStringify(self: Uuid, writer: anytype) !void {
        const text = self.toString();
        try writer.write(text[0..]);
    }

    pub fn parse(text: []const u8) ParseError!Uuid {
        if (text.len != 36) {
            return ParseError.InvalidUuid;
        }

        if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') {
            return ParseError.InvalidUuid;
        }

        var out: [16]u8 = undefined;
        var out_i: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '-') {
                i += 1;
                continue;
            }
            if (i + 1 >= text.len) {
                return error.InvalidUuid;
            }
            const hi = try hexNibble(text[i]);
            const lo = try hexNibble(text[i + 1]);
            out[out_i] = (hi << 4) | lo;
            out_i += 1;
            i += 2;
        }
        if (out_i != 16) {
            return error.InvalidUuid;
        }
        return .{ .bytes = out };
    }

    /// Strict parse of a UUID literal at compile time, for fixed identities
    /// written as source constants (e.g. engine component type ids). An
    /// invalid literal is a compile error, never a runtime failure.
    pub fn parseComptime(comptime text: []const u8) Uuid {
        return comptime parse(text) catch @compileError("invalid UUID literal: " ++ text);
    }
};

fn hexNibble(c: u8) ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidUuid,
    };
}

const testing = std.testing;

test "Uuid.v4 sets RFC 4122 version and variant bits" {
    var prng = std.Random.DefaultPrng.init(0);
    const id = Uuid.v4(prng.random());
    try testing.expectEqual(@as(u8, 0x40), id.bytes[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), id.bytes[8] & 0xc0);
    try testing.expect(!id.isZero());
}

test "Uuid.toString formats canonical lowercase UUID text" {
    const id = Uuid.fromBytes(.{
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0x4d, 0xef,
        0x80, 0x12, 0x34, 0x56,
        0x78, 0x9a, 0xbc, 0xde,
    });
    try testing.expectEqualStrings("12345678-9abc-4def-8012-3456789abcde", &id.toString());
}

test "Uuid equality and zero detection use all bytes" {
    const zero = Uuid.zero;
    const same_zero = Uuid.fromBytes(@splat(0));
    var non_zero_bytes: [16]u8 = @splat(0);
    non_zero_bytes[15] = 1;
    const non_zero = Uuid.fromBytes(non_zero_bytes);

    try testing.expect(zero.eql(same_zero));
    try testing.expect(zero.isZero());
    try testing.expect(!zero.eql(non_zero));
    try testing.expect(!non_zero.isZero());
}

test "Uuid JSON round-trips as canonical text" {
    const id = Uuid.fromBytes(.{
        0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0x4d, 0xef,
        0x80, 0x12, 0x34, 0x56,
        0x78, 0x9a, 0xbc, 0xde,
    });

    const bytes = try std.json.Stringify.valueAlloc(testing.allocator, id, .{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"12345678-9abc-4def-8012-3456789abcde\"", bytes);

    const parsed = try std.json.parseFromSlice(Uuid, testing.allocator, bytes, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.eql(id));
}

test "Uuid JSON parsing rejects non-string values" {
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(Uuid, testing.allocator, "{\"bytes\":[]}", .{}));
}

test "Uuid.parseComptime accepts a valid literal at compile time" {
    const id = comptime Uuid.parseComptime("12345678-9abc-4def-8012-3456789abcde");
    try testing.expectEqualStrings("12345678-9abc-4def-8012-3456789abcde", &id.toString());
}

test "Uuid.parse rejects malformed text" {
    try testing.expectError(error.InvalidUuid, Uuid.parse("12345678-9abc-4def-8012-3456789abcd"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("12345678x9abc-4def-8012-3456789abcde"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("12345678-9ABC-4def-8012-3456789abcde"));
    try testing.expectError(error.InvalidUuid, Uuid.parse(""));
}

test "Uuid.deriveV8 is deterministic and input-sensitive" {
    const ns = Uuid.parseComptime("7a0e3d4c-915b-4f27-8c1d-6602b3f4a910");
    const a = Uuid.deriveV8(ns, "generated/materials/monkey_Suzanne.zamat");
    const b = Uuid.deriveV8(ns, "generated/materials/monkey_Suzanne.zamat");
    const c = Uuid.deriveV8(ns, "generated/materials/monkey_Other.zamat");
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.isZero());
}

test "Uuid.deriveV8 sets version and variant bits" {
    const ns = Uuid.parseComptime("7a0e3d4c-915b-4f27-8c1d-6602b3f4a910");
    const id = Uuid.deriveV8(ns, "x");
    try testing.expectEqual(@as(u8, 0x80), id.bytes[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), id.bytes[8] & 0xc0);
}

test "golden derived id is stable across releases" {
    // If this test ever fails, derived identity broke for every project
    // that ever persisted a derived id. Never update these literals.
    const ns = Uuid.parseComptime("7a0e3d4c-915b-4f27-8c1d-6602b3f4a910");
    const golden = Uuid.deriveV8(ns, "generated/materials/golden.zamat");
    try testing.expectEqualStrings("cde59dc1-afbd-8740-b00d-adee8cb339ce", &golden.toString());
    const x = Uuid.deriveV8(ns, "x");
    try testing.expectEqualStrings("153a5c09-4e75-864c-a25b-fb972603dd55", &x.toString());
}
