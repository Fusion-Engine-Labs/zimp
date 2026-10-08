const std = @import("std");

pub const AssetKind = enum(u8) {
    mesh = 0,
    texture = 1,
    shader_stage = 2,
    material = 3,

    pub fn cookedExtension(self: AssetKind) []const u8 {
        return switch (self) {
            .mesh => "zmesh",
            .texture => "ztex",
            .shader_stage => "zshdr",
            .material => "zamat",
        };
    }

    pub fn rebuildsOnHostOsChange(self: AssetKind) bool {
        return switch (self) {
            .material => true,
            .mesh, .texture, .shader_stage => false,
        };
    }

    /// Kinds whose cooked bytes embed project-scoped `AssetId` references, so
    /// they must be recooked when the project id changes.
    pub fn embedsAssetIds(self: AssetKind) bool {
        return switch (self) {
            .mesh, .material => true,
            .texture, .shader_stage => false,
        };
    }

    pub fn fromCookedPath(path: []const u8) ?AssetKind {
        for (std.enums.values(AssetKind)) |kind| {
            const extension = kind.cookedExtension();
            if (std.mem.endsWith(u8, path, extension) and
                path.len > extension.len and path[path.len - extension.len - 1] == '.')
                return kind;
        }
        return null;
    }

    pub fn fromInt(raw: u8) ?AssetKind {
        return switch (raw) {
            0 => .mesh,
            1 => .texture,
            2 => .shader_stage,
            3 => .material,
            else => null,
        };
    }
};

pub const Extension = enum {
    gltf,
    glb,
    obj,
    bin,
    png,
    jpg,
    jpeg,
    hdr,
    vert,
    frag,
    comp,
    glsl,
    zamat,
    other,

    pub fn string(self: Extension) []const u8 {
        return @tagName(self);
    }

    /// Returns null for files which are not independently cookable assets,
    /// including dependency-only files such as shader includes.
    pub fn assetKind(self: Extension) ?AssetKind {
        return switch (self) {
            .gltf, .glb, .obj => .mesh,
            .png, .jpg, .jpeg, .hdr => .texture,
            .vert, .frag, .comp => .shader_stage,
            .zamat => .material,
            .bin, .glsl, .other => null,
        };
    }

    pub fn fromName(name: []const u8) Extension {
        const dotted_ext = std.fs.path.extension(name);
        if (dotted_ext.len > 1) {
            return std.meta.stringToEnum(Extension, dotted_ext[1..]) orelse .other;
        }
        return .other;
    }

    pub fn processEntry(entry: std.Io.Dir.Entry) Extension {
        return fromName(entry.name);
    }
};

const testing = std.testing;

test "fromInt rejects unknown tags" {
    try testing.expectEqual(AssetKind.material, AssetKind.fromInt(3).?);
    try testing.expect(AssetKind.fromInt(4) == null);
    try testing.expect(AssetKind.fromInt(255) == null);
}

test "Extension.string returns correct string for gltf" {
    try testing.expectEqualStrings("gltf", Extension.gltf.string());
}

test "Extension.string returns correct string for other" {
    try testing.expectEqualStrings("other", Extension.other.string());
}

test "Extension.assetKind maps gltf to mesh" {
    try testing.expectEqual(.mesh, Extension.gltf.assetKind());
}

test "Extension.assetKind maps shader stage to shader_stage" {
    try testing.expectEqual(.shader_stage, Extension.vert.assetKind());
}

test "Extension.assetKind excludes dependency-only and unknown files" {
    try testing.expect(Extension.glsl.assetKind() == null);
    try testing.expect(Extension.other.assetKind() == null);
}

test "AssetKind.rebuildsOnHostOsChange marks only OS-sensitive assets" {
    try testing.expect(AssetKind.material.rebuildsOnHostOsChange());
    try testing.expect(!AssetKind.mesh.rebuildsOnHostOsChange());
    try testing.expect(!AssetKind.texture.rebuildsOnHostOsChange());
    try testing.expect(!AssetKind.shader_stage.rebuildsOnHostOsChange());
}

test "Extension.processEntry returns gltf for .gltf file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "model.gltf", .kind = .file };
    try testing.expectEqual(.gltf, Extension.processEntry(entry));
}

test "Extension.processEntry returns png for .png file" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "image.png", .kind = .file };
    try testing.expectEqual(.png, Extension.processEntry(entry));
}

test "Extension.processEntry uses final extension for multi-dot names" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "basic.mobile.frag", .kind = .file };
    try testing.expectEqual(.frag, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for unknown extension" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "data.csv", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for file with no extension" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = "README", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}

test "Extension.processEntry returns other for dotfile" {
    const entry: std.Io.Dir.Entry = .{ .inode = 0, .name = ".gitignore", .kind = .file };
    try testing.expectEqual(.other, Extension.processEntry(entry));
}
