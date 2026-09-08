const std = @import("std");

const CookedMaterial = @import("../assets/cooked/material.zig").CookedMaterial;
const SourceFile = @import("../assets/source_file.zig").SourceFile;
const raw_material = @import("../assets/raw/material.zig");
const raw_shader = @import("../assets/raw/shader.zig");
const file_read = @import("../shared/file_read.zig");
const builtin = @import("../builtin/registry.zig");
const CookInput = @import("cooker.zig").CookInput;
const zamat = @import("../formats/zamat.zig");
const Cooker = @import("cooker.zig").Cooker;
const log = @import("../logger.zig");

pub fn cooker() Cooker {
    return .{ .cook_fn = cookMaterial };
}

fn cookMaterial(input: *const CookInput) !void {
    var source = try raw_material.parseMaterialSource(input.bytes, input.allocator);
    defer source.deinit(input.allocator);

    try validateReferences(input.allocator, input.io, input.source_dir, input.source.path, &source);

    var cooked = try CookedMaterial.cook(input.allocator, &source);
    defer cooked.deinit(input.allocator);

    try zamat.write(input.writer, cooked);
}

fn validateReferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    source: *raw_material.MaterialSource,
) !void {
    const vert_path = try std.fmt.allocPrint(allocator, "{s}.vert", .{source.shader_path});
    defer allocator.free(vert_path);
    const frag_path = try std.fmt.allocPrint(allocator, "{s}.frag", .{source.shader_path});
    defer allocator.free(frag_path);

    const vert = try lookupPath(allocator, io, source_dir, file_path, vert_path);
    defer vert.deinit(allocator);
    const frag = try lookupPath(allocator, io, source_dir, file_path, frag_path);
    defer frag.deinit(allocator);

    var reflected = try reflectMaterialShaders(
        allocator,
        io,
        source_dir,
        &vert.source,
        &frag.source,
    );
    defer reflected.deinit(allocator);

    for (source.textures) |slot| {
        if (!file_read.fileExists(source_dir, io, slot.texture_path)) {
            log.warn("{s}: texture '{s}' not found", .{ file_path, slot.texture_path });
        }
        try validateTextureSlot(file_path, slot, &reflected);
    }

    for (source.params) |param| {
        try validateParam(file_path, param, &reflected);
    }

    source.required_variants = try selectRequiredVariants(allocator, source, reflected.variants);
}

/// Shader source may either be embedded engine data or a heap allocation read
/// from the project's asset directory. Only the latter belongs to the caller.
const ResolvedShader = struct {
    source: builtin.Source,
    owned_bytes: ?[]u8 = null,

    fn deinit(self: ResolvedShader, allocator: std.mem.Allocator) void {
        if (self.owned_bytes) |bytes| allocator.free(bytes);
    }
};

fn lookupPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    file_path: []const u8,
    shader_path: []const u8,
) !ResolvedShader {
    if (builtin.find(shader_path)) |src| {
        return .{ .source = src };
    }

    if (!file_read.fileExists(source_dir, io, shader_path)) {
        log.err("{s}: shader '{s}' not found", .{ file_path, shader_path });
        return error.MissingShader;
    }

    const result = try file_read.readFileAllocChunked(allocator, io, source_dir, shader_path);
    return .{
        .source = .{ .path = shader_path, .bytes = result },
        .owned_bytes = result,
    };
}

const UniformKind = enum {
    sampler,
    float,
    vec2,
    vec3,
    vec4,
    int,
    bool,
    mat3,
    mat4,
    other,
};

const Uniform = struct {
    name: []const u8,
    kind: UniformKind,
};

const ReflectedShaders = struct {
    uniforms: []Uniform,
    variants: []const []const u8,

    fn deinit(self: *ReflectedShaders, allocator: std.mem.Allocator) void {
        for (self.uniforms) |uniform| allocator.free(uniform.name);
        allocator.free(self.uniforms);
        for (self.variants) |variant| allocator.free(variant);
        allocator.free(self.variants);
    }

    fn findUniform(self: *const ReflectedShaders, name: []const u8) ?Uniform {
        for (self.uniforms) |uniform| {
            if (std.mem.eql(u8, uniform.name, name)) return uniform;
        }
        return null;
    }

    fn hasVariant(self: *const ReflectedShaders, name: []const u8) bool {
        for (self.variants) |variant| {
            if (std.mem.eql(u8, variant, name)) return true;
        }
        return false;
    }
};

fn reflectMaterialShaders(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    vert: *const builtin.Source,
    frag: *const builtin.Source,
) !ReflectedShaders {
    var uniforms: std.ArrayList(Uniform) = .empty;
    errdefer {
        for (uniforms.items) |uniform| allocator.free(uniform.name);
        uniforms.deinit(allocator);
    }
    var variants: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (variants.items) |variant| allocator.free(variant);
        variants.deinit(allocator);
    }

    try reflectShaderFile(allocator, io, source_dir, vert, &uniforms, &variants);
    try reflectShaderFile(allocator, io, source_dir, frag, &uniforms, &variants);

    return .{
        .uniforms = try uniforms.toOwnedSlice(allocator),
        .variants = try variants.toOwnedSlice(allocator),
    };
}

fn reflectShaderFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
    source: *const builtin.Source,
    uniforms: *std.ArrayList(Uniform),
    variants: *std.ArrayList([]const u8),
) !void {
    var shader = try raw_shader.RawShader.init(allocator, io, source_dir, source);
    defer shader.deinit(allocator);

    for (shader.variants) |variant| {
        if (!containsString(variants.items, variant)) {
            try variants.append(allocator, try allocator.dupe(u8, variant));
        }
    }

    var lines = std.mem.splitScalar(u8, shader.source, '\n');
    while (lines.next()) |line| {
        try parseUniformLine(allocator, line, uniforms);
    }
}

fn parseUniformLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    uniforms: *std.ArrayList(Uniform),
) !void {
    const no_comment = if (std.mem.indexOf(u8, line, "//")) |idx| line[0..idx] else line;
    const trimmed = std.mem.trim(u8, no_comment, " \t\r");

    var it = std.mem.tokenizeAny(u8, trimmed, " \t;");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "uniform")) break;
    } else return;
    const type_name = it.next() orelse return;
    var uniform_name = it.next() orelse return;
    if (std.mem.indexOfScalar(u8, uniform_name, '[')) |idx| {
        uniform_name = uniform_name[0..idx];
    }

    if (findUniformInList(uniforms.items, uniform_name) != null) return;

    try uniforms.append(allocator, .{
        .name = try allocator.dupe(u8, uniform_name),
        .kind = uniformKind(type_name),
    });
}

fn uniformKind(type_name: []const u8) UniformKind {
    if (std.mem.startsWith(u8, type_name, "sampler")) return .sampler;
    if (std.mem.eql(u8, type_name, "float")) return .float;
    if (std.mem.eql(u8, type_name, "vec2")) return .vec2;
    if (std.mem.eql(u8, type_name, "vec3")) return .vec3;
    if (std.mem.eql(u8, type_name, "vec4")) return .vec4;
    if (std.mem.eql(u8, type_name, "int")) return .int;
    if (std.mem.eql(u8, type_name, "bool")) return .bool;
    if (std.mem.eql(u8, type_name, "mat3")) return .mat3;
    if (std.mem.eql(u8, type_name, "mat4")) return .mat4;
    return .other;
}

fn validateTextureSlot(file_path: []const u8, slot: raw_material.TextureSlot, reflected: *const ReflectedShaders) !void {
    const uniform = reflected.findUniform(slot.slot_name) orelse {
        log.err("{s}: texture '{s}' has no matching shader sampler uniform", .{ file_path, slot.slot_name });
        return error.MissingShaderUniform;
    };
    if (uniform.kind != .sampler) {
        log.err("{s}: texture '{s}' is not a sampler uniform", .{ file_path, slot.slot_name });
        return error.ShaderUniformTypeMismatch;
    }
}

fn validateParam(file_path: []const u8, param: raw_material.ParamValue, reflected: *const ReflectedShaders) !void {
    const uniform = reflected.findUniform(param.name) orelse {
        log.err("{s}: material param '{s}' has no matching shader uniform", .{ file_path, param.name });
        return error.MissingShaderUniform;
    };
    const expected = paramUniformKind(param.value);
    if (uniform.kind != expected) {
        log.err("{s}: material param '{s}' type does not match shader uniform", .{ file_path, param.name });
        return error.ShaderUniformTypeMismatch;
    }
}

fn selectRequiredVariants(
    allocator: std.mem.Allocator,
    source: *const raw_material.MaterialSource,
    declared_variants: []const []const u8,
) ![]const []const u8 {
    var selected: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (selected.items) |variant| allocator.free(variant);
        selected.deinit(allocator);
    }

    const candidates = [_]struct { name: []const u8, enabled: bool }{
        .{ .name = "HAS_ALBEDO_MAP", .enabled = hasTexture(source, "u_albedo") },
        .{ .name = "HAS_NORMAL_MAP", .enabled = hasTexture(source, "u_normal_map") },
        .{ .name = "HAS_AO", .enabled = hasTexture(source, "u_ao_map") },
        .{ .name = "HAS_EMISSIVE", .enabled = hasTexture(source, "u_emissive_map") },
        .{ .name = "HAS_METALLIC_ROUGHNESS_MAP", .enabled = hasTexture(source, "u_roughness_metallic_map") },
        .{ .name = "ALPHA_TEST", .enabled = source.render_state.alpha_mode == .alpha_test },
        .{ .name = "ALPHA_BLEND", .enabled = source.render_state.alpha_mode == .alpha_blend },
        .{ .name = "DOUBLE_SIDED", .enabled = source.render_state.double_sided },
    };

    for (candidates) |candidate| {
        if (!candidate.enabled) continue;
        if (!containsString(declared_variants, candidate.name)) continue;
        try selected.append(allocator, try allocator.dupe(u8, candidate.name));
    }

    return selected.toOwnedSlice(allocator);
}

fn paramUniformKind(value: raw_material.ParamValue.Value) UniformKind {
    return switch (value) {
        .float => .float,
        .vec2 => .vec2,
        .vec3 => .vec3,
        .vec4 => .vec4,
        .int => .int,
        .bool => .bool,
    };
}

fn hasTexture(source: *const raw_material.MaterialSource, slot_name: []const u8) bool {
    for (source.textures) |slot| {
        if (std.mem.eql(u8, slot.slot_name, slot_name)) return true;
    }
    return false;
}

fn containsString(strings: []const []const u8, needle: []const u8) bool {
    for (strings) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn findUniformInList(uniforms: []const Uniform, name: []const u8) ?Uniform {
    for (uniforms) |uniform| {
        if (std.mem.eql(u8, uniform.name, name)) return uniform;
    }
    return null;
}

const testing = std.testing;

fn cookMaterialFixture(allocator: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir, file_path: []const u8, writer: *std.Io.Writer) !void {
    const result = try file_read.readFileAllocChunked(allocator, io, source_dir, file_path);
    defer allocator.free(result);
    const source = SourceFile.fromPath(file_path);
    const input = CookInput{ .allocator = allocator, .io = io, .source_dir = source_dir, .source = source, .bytes = result, .writer = writer };
    try cooker().cook(&input);
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dirname| {
        try dir.createDirPath(testing.io, dirname);
    }
    const file = try dir.createFile(testing.io, path, .{});
    var buf: [4096]u8 = undefined;
    var writer = file.writer(testing.io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    file.close(testing.io);
}

test "material cooker writes zamat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_albedo]
        \\path = "textures/missing.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform sampler2D u_albedo;
        \\uniform float u_roughness;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);

    try testing.expectEqualSlices(u8, zamat.MAGIC, out[0..zamat.MAGIC.len]);

    var reader = std.Io.Reader.fixed(out[0..writer.end]);
    var loaded = try zamat.Zamat.read(testing.allocator, &reader);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("shaders/basic.vert.zshdr", loaded.vertex_shader_path);
    try testing.expectEqualStrings("shaders/basic.frag.zshdr", loaded.fragment_shader_path);
    try testing.expectEqualStrings("textures/missing.ztex", loaded.texture_slots[0].cooked_path);
}

test "material cooker validates builtin standard uniforms without freeing embedded source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "fusion/standard"
        \\[texture.u_albedo]
        \\path = "textures/missing.png"
        \\[params]
        \\u_base_color = [1.0, 1.0, 1.0, 1.0]
        \\
    );

    var out: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);
    try testing.expect(writer.end > 0);
}

test "material cooker errors on missing shader" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/missing"
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.MissingShader, cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker rejects params missing from shader reflection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[params]
        \\u_missing = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag", "void main() {}\n");

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.MissingShaderUniform, cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker rejects param type mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[params]
        \\u_roughness = [1.0, 2.0]
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform float u_roughness;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try testing.expectError(error.ShaderUniformTypeMismatch, cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer));
}

test "material cooker accepts custom texture sampler names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_custom_mask]
        \\path = "textures/missing.png"
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\uniform sampler2D u_custom_mask;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);
}

test "material cooker reflects layout-qualified uniforms" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[texture.u_albedo]
        \\path = "textures/missing.png"
        \\[params]
        \\u_roughness = 0.5
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\layout(binding = 0) uniform sampler2D u_albedo;
        \\layout(location = 3) uniform float u_roughness;
        \\void main() {}
        \\
    );

    var out: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);
}

test "material cooker selects declared variants from material contents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeTestFile(tmp.dir, "materials/test.zamat",
        \\[material]
        \\shader = "shaders/basic"
        \\[render_state]
        \\alpha_mode = "alpha_test"
        \\[texture.u_normal_map]
        \\path = "textures/missing.png"
        \\
    );
    try writeTestFile(tmp.dir, "shaders/basic.vert", "void main() {}\n");
    try writeTestFile(tmp.dir, "shaders/basic.frag",
        \\#version 330 core
        \\// VARIANTS: HAS_NORMAL_MAP, ALPHA_TEST
        \\uniform sampler2D u_normal_map;
        \\void main() {}
        \\
    );

    var out: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try cookMaterialFixture(testing.allocator, testing.io, tmp.dir, "materials/test.zamat", &writer);

    var reader = std.Io.Reader.fixed(out[0..writer.end]);
    var loaded = try zamat.Zamat.read(testing.allocator, &reader);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), loaded.required_variants.len);
    try testing.expectEqualStrings("HAS_NORMAL_MAP", loaded.required_variants[0]);
    try testing.expectEqualStrings("ALPHA_TEST", loaded.required_variants[1]);
}
