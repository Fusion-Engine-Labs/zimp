const std = @import("std");

pub const MeshScratch = @import("mesh_scratch.zig").MeshScratch;
const log = @import("../../logger.zig");

const Map = std.AutoHashMap(u64, u32);

pub const UV0Bounds = struct {
    min: [2]f32,
    scale: [2]f32,

    pub fn compute(vertices: []const RawVertex) UV0Bounds {
        var min: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var max: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };

        for (vertices) |v| {
            const uv = v.uv0 orelse continue;
            for (0..2) |i| {
                min[i] = @min(min[i], uv[i]);
                max[i] = @max(max[i], uv[i]);
            }
        }

        var scale: [2]f32 = undefined;
        for (0..2) |i| {
            // no UVs
            if (min[i] > max[i]) {
                min[i] = 0;
                max[i] = 1;
            }

            const range = max[i] - min[i];
            scale[i] = if (range > 1e-8) range else 1.0;
        }

        return .{ .min = min, .scale = scale };
    }
};

pub const RawVertex = struct {
    position: [3]f32,
    normal: ?[3]f32,
    tangent: ?[4]f32,
    uv0: ?[2]f32,
    uv1: ?[2]f32,
    joint_indices: ?[4]u16,
    joint_weights: ?[4]f32,

    pub fn hash(self: *const RawVertex) u64 {
        var hasher = std.hash.XxHash64.init(0);
        hasher.update(std.mem.asBytes(&self.position));
        hashOptional(&hasher, self.normal);
        hashOptional(&hasher, self.tangent);
        hashOptional(&hasher, self.uv0);
        hashOptional(&hasher, self.uv1);
        hashOptional(&hasher, self.joint_indices);
        hashOptional(&hasher, self.joint_weights);
        return hasher.final();
    }

    pub fn eql(self: *const RawVertex, other: *const RawVertex) bool {
        return std.mem.eql(u8, std.mem.asBytes(&self.position), std.mem.asBytes(&other.position)) and
            eqlOptional(self.normal, other.normal) and
            eqlOptional(self.tangent, other.tangent) and
            eqlOptional(self.uv0, other.uv0) and
            eqlOptional(self.uv1, other.uv1) and
            eqlOptional(self.joint_indices, other.joint_indices) and
            eqlOptional(self.joint_weights, other.joint_weights);
    }

    pub fn quantizeUV0(self: *const RawVertex, bounds: *const UV0Bounds) ?[2]u16 {
        if (self.uv0) |uv| {
            return quantizeUV(uv, bounds);
        }
        return null;
    }

    pub fn quantizeUV1(self: *const RawVertex) ?[2]u16 {
        const uv = self.uv1 orelse return null;

        for (0..2) |i| {
            if (uv[i] < 0.0 or uv[i] > 1.0) {
                log.warn("uv1 value {d} is outside [0,1]", .{uv[i]});
            }
        }

        const bounds = UV0Bounds{
            .min = .{ 0, 0 },
            .scale = .{ 1, 1 },
        };
        return quantizeUV(uv, &bounds);
    }

    /// Octahedral tangent as snorm8 `{ oct.x, oct.y, handedness sign, 0 }`.
    pub fn encodeTangentOctahedral(self: *const RawVertex) ?[4]i8 {
        const tangent = self.tangent orelse return null;
        const oct = octEncode(.{ tangent[0], tangent[1], tangent[2] }, .{ 1, 0, 0 });
        return .{
            @intFromFloat(@round(oct[0] * 127.0)),
            @intFromFloat(@round(oct[1] * 127.0)),
            if (tangent[3] < 0.0) -127 else 127,
            0,
        };
    }

    /// unorm8 weights renormalized to sum to exactly 255 (largest remainder).
    pub fn quantizeJointWeights(self: *const RawVertex) ?[4]u8 {
        const weights = self.joint_weights orelse return null;
        // Negative and non-finite weights count as 0.
        var clean: [4]f32 = undefined;
        var sum: f32 = 0;
        for (weights, &clean) |w, *c| {
            c.* = if (std.math.isFinite(w) and w > 0.0) w else 0.0;
            sum += c.*;
        }
        if (!(sum > 0.0) or !std.math.isFinite(sum)) return .{ 255, 0, 0, 0 };

        var result: [4]u8 = undefined;
        var remainders: [4]f32 = undefined;
        var total: u32 = 0;
        for (clean, 0..) |w, i| {
            const scaled = @min(w / sum * 255.0, 255.0);
            const floored = @floor(scaled);
            result[i] = @intFromFloat(floored);
            remainders[i] = scaled - floored;
            total += result[i];
        }
        while (total < 255) : (total += 1) {
            const i = std.mem.indexOfMax(f32, &remainders);
            result[i] += 1;
            remainders[i] = -1;
        }
        return result;
    }

    pub fn encodeNormalOctahedral(self: *const RawVertex) ?[2]i16 {
        const normal = self.normal orelse return null;
        const oct = octEncode(normal, .{ 0, 0, 1 });
        return .{
            @intFromFloat(@round(oct[0] * 32767.0)),
            @intFromFloat(@round(oct[1] * 32767.0)),
        };
    }

    /// Like std.math.sign but returns 1.0 for zero (needed for octahedral fold).
    fn signNonZero(x: f32) f32 {
        return if (x >= 0.0) 1.0 else -1.0;
    }

    /// Octahedral projection into [-1, 1]². Zero-length or non-finite input
    /// encodes `fallback`.
    fn octEncode(v: [3]f32, fallback: [3]f32) [2]f32 {
        const abs_sum = @abs(v[0]) + @abs(v[1]) + @abs(v[2]);
        const n = if (abs_sum > 1e-20 and std.math.isFinite(abs_sum)) v else fallback;
        const s = @abs(n[0]) + @abs(n[1]) + @abs(n[2]);
        var oct: [2]f32 = .{ n[0] / s, n[1] / s };

        // Fold for negative z hemisphere
        if (n[2] < 0.0) {
            const ox = oct[0];
            const oy = oct[1];
            oct[0] = (1.0 - @abs(oy)) * signNonZero(ox);
            oct[1] = (1.0 - @abs(ox)) * signNonZero(oy);
        }
        return oct;
    }

    fn quantizeUV(uv: [2]f32, bounds: *const UV0Bounds) [2]u16 {
        var result: [2]u16 = undefined;
        for (0..2) |i| {
            result[i] = quantizeUnorm16((uv[i] - bounds.min[i]) / bounds.scale[i]);
        }

        return result;
    }
};

/// Rounds `t` (clamped to [0, 1]) to a u16 unorm. NaN maps to 0.
pub fn quantizeUnorm16(t: f32) u16 {
    const clamped = if (t > 0.0) @min(t, 1.0) else 0.0;
    return @intFromFloat(@round(clamped * 65535.0));
}

/// Position as u16 unorm relative to the mesh AABB; w is 0. Flat axes
/// quantize to 0, so `min + q * (max - min)` reconstructs them exactly.
pub fn quantizePosition(position: [3]f32, min: [3]f32, max: [3]f32) [4]u16 {
    var result: [4]u16 = .{ 0, 0, 0, 0 };
    for (0..3) |i| {
        const extent = max[i] - min[i];
        if (extent > 0.0) result[i] = quantizeUnorm16((position[i] - min[i]) / extent);
    }
    return result;
}

fn hashOptional(hasher: *std.hash.XxHash64, optional: anytype) void {
    if (optional) |value| {
        const present: [1]u8 = .{1};
        hasher.update(&present);
        hasher.update(std.mem.asBytes(&value));
    } else {
        const absent: [1]u8 = .{0};
        hasher.update(&absent);
    }
}

fn eqlOptional(a: anytype, b: @TypeOf(a)) bool {
    if (a) |a_value| {
        if (b) |b_value| {
            return std.mem.eql(u8, std.mem.asBytes(&a_value), std.mem.asBytes(&b_value));
        }
        return false;
    }
    return b == null;
}

pub const RawSubmesh = struct {
    index_offset: u32,
    index_count: u32,
    material_index: u16,
};

pub const MeshGuarantees = struct {
    vertices_unique: bool = false,
    triangles_validated: bool = false,
    unused_vertices_removed: bool = false,
};

pub const RawMesh = struct {
    vertices: []RawVertex,
    indices: []u32,
    submeshes: []RawSubmesh,
    name: ?[]const u8,
    guarantees: MeshGuarantees = .{},

    pub fn optimize(self: *RawMesh, allocator: std.mem.Allocator) !void {
        var scratch = MeshScratch.init(allocator);
        defer scratch.deinit();
        try self.optimizeWithScratch(allocator, &scratch);
    }

    pub fn optimizeWithScratch(self: *RawMesh, allocator: std.mem.Allocator, scratch: *MeshScratch) !void {
        const degenerates_removed = if (self.guarantees.triangles_validated) false else try self.removeDegenerateTriangles(allocator);
        if (!self.guarantees.unused_vertices_removed or degenerates_removed) {
            _ = try self.removeUnusedVerticesWithScratch(allocator, scratch);
        }
        const deduplicated = if (self.guarantees.vertices_unique) false else try self.deduplicateVerticesWithScratch(allocator, scratch);
        if (deduplicated) {
            const post_dedup_degenerates = try self.removeDegenerateTriangles(allocator);
            if (post_dedup_degenerates) _ = try self.removeUnusedVerticesWithScratch(allocator, scratch);
        }
        self.guarantees = .{
            .vertices_unique = true,
            .triangles_validated = true,
            .unused_vertices_removed = true,
        };
        try self.optimizeVertexCache(allocator);
        try self.optimizeVertexFetchWithScratch(allocator, scratch);
    }

    fn removeDegenerateTriangles(self: *RawMesh, allocator: std.mem.Allocator) !bool {
        if (self.indices.len == 0) {
            return false;
        }

        if (self.submeshes.len == 0) {
            if (self.indices.len % 3 != 0) {
                return false;
            }
        } else {
            for (self.submeshes) |submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                if (offset > self.indices.len or count > self.indices.len - offset) {
                    return error.InvalidSubmeshRange;
                }
                if (count % 3 != 0) {
                    return false;
                }
            }
        }

        const original_len = self.indices.len;
        var cleaned_len: usize = 0;

        if (self.submeshes.len == 0) {
            cleaned_len = try compactValidTriangles(self.vertices, self.indices, 0, self.indices.len, 0);
        } else {
            for (self.submeshes) |*submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                const new_offset = cleaned_len;
                const kept_count = try compactValidTriangles(self.vertices, self.indices, offset, count, cleaned_len);
                submesh.index_offset = @intCast(new_offset);
                submesh.index_count = @intCast(kept_count);
                cleaned_len += kept_count;
            }
        }

        if (cleaned_len == original_len) {
            return false;
        }

        if (allocator.resize(self.indices, cleaned_len)) {
            self.indices = self.indices.ptr[0..cleaned_len];
        } else {
            const new_indices = try allocator.dupe(u32, self.indices[0..cleaned_len]);
            allocator.free(self.indices);
            self.indices = new_indices;
        }

        log.debug("[Optimizing Mesh] Removed {d} degenerate triangle indices", .{original_len - cleaned_len});
        return true;
    }

    // Forsyth Algorithm
    fn optimizeVertexCache(self: *RawMesh, allocator: std.mem.Allocator) !void {
        if (self.indices.len < 6 or self.indices.len % 3 != 0) {
            return;
        }

        const optimized = try allocator.dupe(u32, self.indices);
        errdefer allocator.free(optimized);

        if (self.submeshes.len == 0) {
            try optimizeVertexCacheRange(allocator, self.vertices.len, self.indices, optimized, 0, self.indices.len);
        } else {
            for (self.submeshes) |submesh| {
                const offset: usize = submesh.index_offset;
                const count: usize = submesh.index_count;
                if (offset > self.indices.len or count > self.indices.len - offset) {
                    return error.InvalidSubmeshRange;
                }
                if (count % 3 != 0) {
                    return;
                }
                try optimizeVertexCacheRange(allocator, self.vertices.len, self.indices, optimized, offset, count);
            }
        }

        allocator.free(self.indices);
        self.indices = optimized;
    }

    fn deduplicateVerticesWithScratch(self: *RawMesh, allocator: std.mem.Allocator, scratch: *MeshScratch) !bool {
        return self.deduplicateVerticesWithHashAndScratch(allocator, scratch, RawVertex.hash);
    }

    fn deduplicateVerticesWithHashAndScratch(
        self: *RawMesh,
        allocator: std.mem.Allocator,
        scratch: *MeshScratch,
        hash_fn: *const fn (*const RawVertex) u64,
    ) !bool {
        var deduped: std.ArrayList(RawVertex) = try .initCapacity(allocator, self.vertices.len);
        defer deduped.deinit(allocator);

        var map = Map.init(allocator);
        defer map.deinit();

        const remap = try scratch.remapFor(self.vertices.len);
        const next_candidate = try scratch.candidatesFor(self.vertices.len);
        const no_candidate = std.math.maxInt(u32);

        for (0.., self.vertices) |i, vertex| {
            const h = hash_fn(&vertex);
            if (map.get(h)) |first_candidate| {
                var candidate = first_candidate;
                while (true) {
                    if (deduped.items[candidate].eql(&vertex)) {
                        remap[i] = candidate;
                        break;
                    }
                    const next = next_candidate[candidate];
                    if (next == no_candidate) {
                        const new_idx: u32 = @intCast(deduped.items.len);
                        deduped.appendAssumeCapacity(vertex);
                        next_candidate[candidate] = new_idx;
                        next_candidate[new_idx] = no_candidate;
                        remap[i] = new_idx;
                        break;
                    }
                    candidate = next;
                }
            } else {
                const new_idx: u32 = @intCast(deduped.items.len);
                deduped.appendAssumeCapacity(vertex);
                try map.put(h, new_idx);
                next_candidate[new_idx] = no_candidate;
                remap[i] = new_idx;
            }
        }

        // No duplicates found, nothing to do
        if (deduped.items.len == self.vertices.len) {
            return false;
        }

        const original_len = self.vertices.len;

        // Rewrite index buffer using the remap table
        for (self.indices) |*index| {
            if (index.* >= remap.len) return error.InvalidMeshIndex;
            index.* = remap[index.*];
        }

        // Replace vertices with deduplicated array
        allocator.free(self.vertices);
        self.vertices = try deduped.toOwnedSlice(allocator);

        log.debug("[Optimizing Mesh] Deduplicated {d} -> {d} vertices", .{ original_len, self.vertices.len });
        return true;
    }

    fn removeUnusedVerticesWithScratch(self: *RawMesh, allocator: std.mem.Allocator, scratch: *MeshScratch) !bool {
        if (self.vertices.len == 0) {
            return false;
        }

        const used = try scratch.usedFor(self.vertices.len);
        @memset(used, false);

        for (self.indices) |index| {
            if (index >= self.vertices.len) {
                return error.InvalidMeshIndex;
            }
            used[index] = true;
        }

        var used_count: usize = 0;
        for (used) |is_used| {
            if (is_used) {
                used_count += 1;
            }
        }

        if (used_count == self.vertices.len) {
            return false;
        }

        const remap = try scratch.remapFor(self.vertices.len);

        const compacted = try allocator.alloc(RawVertex, used_count);
        errdefer allocator.free(compacted);

        var next_vertex: u32 = 0;
        for (self.vertices, used, 0..) |vertex, is_used, old_index| {
            if (is_used) {
                remap[old_index] = next_vertex;
                compacted[next_vertex] = vertex;
                next_vertex += 1;
            }
        }

        for (self.indices) |*index| {
            index.* = remap[index.*];
        }

        const original_len = self.vertices.len;
        allocator.free(self.vertices);
        self.vertices = compacted;

        log.debug("[Optimizing Mesh] Removed {d} unused vertices", .{original_len - self.vertices.len});
        return true;
    }

    fn optimizeVertexFetchWithScratch(self: *RawMesh, allocator: std.mem.Allocator, scratch: *MeshScratch) !void {
        if (self.vertices.len == 0 or self.indices.len == 0) {
            return;
        }

        const unset = std.math.maxInt(u32);
        const remap = try scratch.remapFor(self.vertices.len);
        @memset(remap, unset);

        const reordered = try allocator.alloc(RawVertex, self.vertices.len);
        errdefer allocator.free(reordered);

        var next_vertex: u32 = 0;
        for (self.indices) |*index| {
            if (index.* >= self.vertices.len) {
                return error.InvalidMeshIndex;
            }

            const old_index = index.*;
            if (remap[old_index] == unset) {
                remap[old_index] = next_vertex;
                reordered[next_vertex] = self.vertices[old_index];
                next_vertex += 1;
            }
            index.* = remap[old_index];
        }

        for (self.vertices, 0..) |vertex, old_index| {
            if (remap[old_index] == unset) {
                remap[old_index] = next_vertex;
                reordered[next_vertex] = vertex;
                next_vertex += 1;
            }
        }

        allocator.free(self.vertices);
        self.vertices = reordered;
    }
};

const forsyth_cache_size = 32;
const forsyth_last_triangle_score: f32 = 0.75;
const forsyth_cache_decay_power: f32 = 1.5;
const forsyth_valence_boost_scale: f32 = 2.0;
const forsyth_valence_boost_power: f32 = 0.5;
const forsyth_score_table_size = 64;
const degenerate_triangle_area_epsilon_sq: f32 = 1.0e-20;

const forsyth_cache_position_scores: [forsyth_cache_size]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var scores: [forsyth_cache_size]f32 = undefined;
    for (0..forsyth_cache_size) |position| {
        scores[position] = if (position < 3)
            forsyth_last_triangle_score
        else
            std.math.pow(f32, 1.0 - @as(f32, @floatFromInt(position - 3)) / @as(f32, @floatFromInt(forsyth_cache_size - 3)), forsyth_cache_decay_power);
    }
    break :blk scores;
};

const forsyth_valence_scores: [forsyth_score_table_size + 1]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var scores: [forsyth_score_table_size + 1]f32 = undefined;
    scores[0] = 0.0;
    for (1..scores.len) |valence| {
        scores[valence] = forsyth_valence_boost_scale * std.math.pow(f32, @floatFromInt(valence), -forsyth_valence_boost_power);
    }
    break :blk scores;
};

fn compactValidTriangles(
    vertices: []const RawVertex,
    indices: []u32,
    index_offset: usize,
    index_count: usize,
    output_offset: usize,
) !usize {
    if (index_count % 3 != 0) {
        return error.InvalidTriangleIndexBuffer;
    }

    var written: usize = 0;
    var triangle_start = index_offset;
    while (triangle_start < index_offset + index_count) : (triangle_start += 3) {
        const a = indices[triangle_start + 0];
        const b = indices[triangle_start + 1];
        const c = indices[triangle_start + 2];
        if (a >= vertices.len or b >= vertices.len or c >= vertices.len) {
            return error.InvalidMeshIndex;
        }
        if (isDegenerateTriangle(vertices, a, b, c)) {
            continue;
        }

        indices[output_offset + written + 0] = a;
        indices[output_offset + written + 1] = b;
        indices[output_offset + written + 2] = c;
        written += 3;
    }

    return written;
}

fn isDegenerateTriangle(vertices: []const RawVertex, a: u32, b: u32, c: u32) bool {
    if (a == b or b == c or c == a) {
        return true;
    }

    const p0 = vertices[a].position;
    const p1 = vertices[b].position;
    const p2 = vertices[c].position;

    const e0 = [3]f32{
        p1[0] - p0[0],
        p1[1] - p0[1],
        p1[2] - p0[2],
    };
    const e1 = [3]f32{
        p2[0] - p0[0],
        p2[1] - p0[1],
        p2[2] - p0[2],
    };
    const cross = [3]f32{
        e0[1] * e1[2] - e0[2] * e1[1],
        e0[2] * e1[0] - e0[0] * e1[2],
        e0[0] * e1[1] - e0[1] * e1[0],
    };
    const area_sq = cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2];
    return area_sq <= degenerate_triangle_area_epsilon_sq;
}

fn optimizeVertexCacheRange(
    allocator: std.mem.Allocator,
    vertex_count: usize,
    source: []const u32,
    dest: []u32,
    index_offset: usize,
    index_count: usize,
) !void {
    if (index_count == 0) {
        return;
    }
    if (index_count % 3 != 0) {
        return error.InvalidTriangleIndexBuffer;
    }

    const triangle_count = index_count / 3;
    if (triangle_count <= 1) {
        return;
    }

    const range = source[index_offset .. index_offset + index_count];

    var active_triangle_counts = try allocator.alloc(u32, vertex_count);
    defer allocator.free(active_triangle_counts);
    @memset(active_triangle_counts, 0);

    for (range) |index| {
        if (index >= vertex_count) {
            return error.InvalidMeshIndex;
        }
        active_triangle_counts[index] += 1;
    }

    var adjacency_offsets = try allocator.alloc(u32, vertex_count + 1);
    defer allocator.free(adjacency_offsets);
    adjacency_offsets[0] = 0;
    for (active_triangle_counts, 0..) |count, vertex_index| {
        adjacency_offsets[vertex_index + 1] = adjacency_offsets[vertex_index] + count;
    }

    var adjacency = try allocator.alloc(u32, adjacency_offsets[vertex_count]);
    defer allocator.free(adjacency);

    var adjacency_cursors = try allocator.dupe(u32, adjacency_offsets[0..vertex_count]);
    defer allocator.free(adjacency_cursors);

    for (0..triangle_count) |triangle_index| {
        const triangle_start = triangle_index * 3;
        for (0..3) |corner| {
            const vertex_index = range[triangle_start + corner];
            const write_index = adjacency_cursors[vertex_index];
            adjacency[write_index] = @intCast(triangle_index);
            adjacency_cursors[vertex_index] = write_index + 1;
        }
    }

    var cache_positions = try allocator.alloc(i32, vertex_count);
    defer allocator.free(cache_positions);
    @memset(cache_positions, -1);

    var vertex_scores = try allocator.alloc(f32, vertex_count);
    defer allocator.free(vertex_scores);
    for (0..vertex_count) |vertex_index| {
        vertex_scores[vertex_index] = forsythVertexScore(cache_positions[vertex_index], active_triangle_counts[vertex_index]);
    }

    var triangle_scores = try allocator.alloc(f32, triangle_count);
    defer allocator.free(triangle_scores);
    for (0..triangle_count) |triangle_index| {
        triangle_scores[triangle_index] = forsythTriangleScore(range, triangle_index, vertex_scores);
    }

    var emitted = try allocator.alloc(bool, triangle_count);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var cache: [forsyth_cache_size]u32 = undefined;
    var cache_len: usize = 0;
    var emitted_count: usize = 0;
    var scan_cursor: usize = 0;

    while (emitted_count < triangle_count) {
        const triangle_index = findBestForsythTriangle(
            &cache,
            cache_len,
            adjacency_offsets,
            adjacency,
            triangle_scores,
            emitted,
            &scan_cursor,
        ) orelse return error.InvalidTriangleIndexBuffer;

        emitted[triangle_index] = true;

        const triangle_start = triangle_index * 3;
        const output_start = index_offset + emitted_count * 3;
        dest[output_start + 0] = range[triangle_start + 0];
        dest[output_start + 1] = range[triangle_start + 1];
        dest[output_start + 2] = range[triangle_start + 2];
        emitted_count += 1;

        var affected_vertices: [forsyth_cache_size * 2 + 3]u32 = undefined;
        var affected_count: usize = 0;
        appendAffectedVertices(&affected_vertices, &affected_count, cache[0..cache_len]);

        for (cache[0..cache_len]) |vertex_index| {
            cache_positions[vertex_index] = -1;
        }

        for (0..3) |corner| {
            const vertex_index = range[triangle_start + corner];
            if (active_triangle_counts[vertex_index] == 0) {
                return error.InvalidTriangleIndexBuffer;
            }
            active_triangle_counts[vertex_index] -= 1;
            appendAffectedVertex(&affected_vertices, &affected_count, vertex_index);
        }

        var corner: usize = 3;
        while (corner > 0) {
            corner -= 1;
            promoteVertexInForsythCache(&cache, &cache_len, range[triangle_start + corner]);
        }

        for (cache[0..cache_len], 0..) |vertex_index, cache_position| {
            cache_positions[vertex_index] = @intCast(cache_position);
        }
        appendAffectedVertices(&affected_vertices, &affected_count, cache[0..cache_len]);

        for (affected_vertices[0..affected_count]) |vertex_index| {
            vertex_scores[vertex_index] = forsythVertexScore(cache_positions[vertex_index], active_triangle_counts[vertex_index]);
        }

        for (affected_vertices[0..affected_count]) |vertex_index| {
            const adjacency_start = adjacency_offsets[vertex_index];
            const adjacency_end = adjacency_offsets[vertex_index + 1];
            for (adjacency[adjacency_start..adjacency_end]) |adjacent_triangle_index| {
                if (!emitted[adjacent_triangle_index]) {
                    triangle_scores[adjacent_triangle_index] = forsythTriangleScore(range, adjacent_triangle_index, vertex_scores);
                }
            }
        }
    }
}

fn forsythVertexScore(cache_position: i32, active_triangle_count: u32) f32 {
    if (active_triangle_count == 0) {
        return 0.0;
    }

    const cache_score = if (cache_position >= 0 and cache_position < forsyth_cache_size)
        forsyth_cache_position_scores[@intCast(cache_position)]
    else
        0.0;
    const valence_score = if (active_triangle_count <= forsyth_score_table_size)
        forsyth_valence_scores[active_triangle_count]
    else
        forsyth_valence_boost_scale * std.math.pow(f32, @floatFromInt(active_triangle_count), -forsyth_valence_boost_power);
    return cache_score + valence_score;
}

fn forsythTriangleScore(indices: []const u32, triangle_index: usize, vertex_scores: []const f32) f32 {
    const triangle_start = triangle_index * 3;
    return vertex_scores[indices[triangle_start + 0]] +
        vertex_scores[indices[triangle_start + 1]] +
        vertex_scores[indices[triangle_start + 2]];
}

fn findBestForsythTriangle(
    cache: *const [forsyth_cache_size]u32,
    cache_len: usize,
    adjacency_offsets: []const u32,
    adjacency: []const u32,
    triangle_scores: []const f32,
    emitted: []const bool,
    scan_cursor: *usize,
) ?usize {
    var best_triangle: ?usize = null;
    var best_score: f32 = -std.math.inf(f32);

    for (cache[0..cache_len]) |vertex_index| {
        const adjacency_start = adjacency_offsets[vertex_index];
        const adjacency_end = adjacency_offsets[vertex_index + 1];
        for (adjacency[adjacency_start..adjacency_end]) |triangle_index| {
            if (emitted[triangle_index]) {
                continue;
            }
            const score = triangle_scores[triangle_index];
            if (best_triangle == null or score > best_score) {
                best_triangle = triangle_index;
                best_score = score;
            }
        }
    }

    if (best_triangle != null) {
        return best_triangle;
    }

    while (scan_cursor.* < emitted.len and emitted[scan_cursor.*]) {
        scan_cursor.* += 1;
    }

    var triangle_index = scan_cursor.*;
    while (triangle_index < emitted.len) : (triangle_index += 1) {
        if (emitted[triangle_index]) {
            continue;
        }
        const score = triangle_scores[triangle_index];
        if (best_triangle == null or score > best_score) {
            best_triangle = triangle_index;
            best_score = score;
        }
    }

    return best_triangle;
}

fn promoteVertexInForsythCache(cache: *[forsyth_cache_size]u32, cache_len: *usize, vertex_index: u32) void {
    var existing_position: ?usize = null;
    for (cache[0..cache_len.*], 0..) |cached_vertex, cache_position| {
        if (cached_vertex == vertex_index) {
            existing_position = cache_position;
            break;
        }
    }

    const write_len = if (existing_position == null and cache_len.* < forsyth_cache_size) cache_len.* + 1 else cache_len.*;
    var position = if (write_len == 0) 0 else write_len - 1;
    while (position > 0) : (position -= 1) {
        if (existing_position) |existing| {
            if (position > existing) {
                continue;
            }
        }
        cache[position] = cache[position - 1];
    }

    cache[0] = vertex_index;
    cache_len.* = write_len;
}

fn appendAffectedVertex(affected_vertices: []u32, affected_count: *usize, vertex_index: u32) void {
    for (affected_vertices[0..affected_count.*]) |affected_vertex| {
        if (affected_vertex == vertex_index) {
            return;
        }
    }

    affected_vertices[affected_count.*] = vertex_index;
    affected_count.* += 1;
}

fn appendAffectedVertices(affected_vertices: []u32, affected_count: *usize, vertices: []const u32) void {
    for (vertices) |vertex_index| {
        appendAffectedVertex(affected_vertices, affected_count, vertex_index);
    }
}

// Tests

fn makeVertex(x: f32, y: f32, z: f32) RawVertex {
    return .{
        .position = .{ x, y, z },
        .normal = null,
        .tangent = null,
        .uv0 = null,
        .uv1 = null,
        .joint_indices = null,
        .joint_weights = null,
    };
}

/// Resolve an index triple to actual vertex positions for comparison.
fn resolveTriangle(vertices: []const RawVertex, indices: []const u32, tri_start: usize) [3][3]f32 {
    return .{
        vertices[indices[tri_start + 0]].position,
        vertices[indices[tri_start + 1]].position,
        vertices[indices[tri_start + 2]].position,
    };
}

fn countVertexCacheMisses(indices: []const u32) usize {
    var cache: [forsyth_cache_size]u32 = undefined;
    var cache_len: usize = 0;
    var misses: usize = 0;

    for (indices) |index| {
        var cache_hit = false;
        for (cache[0..cache_len]) |cached_index| {
            if (cached_index == index) {
                cache_hit = true;
                break;
            }
        }

        if (!cache_hit) {
            misses += 1;
        }

        promoteVertexInForsythCache(&cache, &cache_len, index);
    }

    return misses;
}

fn expectSameTriangles(allocator: std.mem.Allocator, expected: []const u32, actual: []const u32) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    try std.testing.expectEqual(@as(usize, 0), expected.len % 3);

    const triangle_count = expected.len / 3;
    var matched = try allocator.alloc(bool, triangle_count);
    defer allocator.free(matched);
    @memset(matched, false);

    for (0..triangle_count) |expected_triangle| {
        const expected_start = expected_triangle * 3;
        var found = false;

        for (0..triangle_count) |actual_triangle| {
            if (matched[actual_triangle]) {
                continue;
            }

            const actual_start = actual_triangle * 3;
            if (expected[expected_start + 0] == actual[actual_start + 0] and
                expected[expected_start + 1] == actual[actual_start + 1] and
                expected[expected_start + 2] == actual[actual_start + 2])
            {
                matched[actual_triangle] = true;
                found = true;
                break;
            }
        }

        try std.testing.expect(found);
    }
}

test "removeDegenerateTriangles drops repeated and zero-area triangles and updates submeshes" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(0, 1, 0),
        makeVertex(2, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{
        0, 1, 2, 0, 0, 1,
        0, 1, 3, 2, 1, 3,
    });
    const submeshes = try allocator.dupe(RawSubmesh, &.{
        .{ .index_offset = 0, .index_count = 6, .material_index = 0 },
        .{ .index_offset = 6, .index_count = 6, .material_index = 1 },
    });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = submeshes,
        .name = null,
    };

    _ = try mesh.removeDegenerateTriangles(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);
    defer allocator.free(mesh.submeshes);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 2, 1, 3 }, mesh.indices);
    try std.testing.expectEqual(@as(u32, 0), mesh.submeshes[0].index_offset);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[0].index_count);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[1].index_offset);
    try std.testing.expectEqual(@as(u32, 3), mesh.submeshes[1].index_count);
}

test "removeUnusedVertices compacts vertices in original order and remaps indices" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(2, 0, 0),
        makeVertex(3, 0, 0),
        makeVertex(4, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 4, 2, 4 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.removeUnusedVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 2), mesh.vertices.len);
    try std.testing.expectEqual([3]f32{ 2, 0, 0 }, mesh.vertices[0].position);
    try std.testing.expectEqual([3]f32{ 4, 0, 0 }, mesh.vertices[1].position);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 1 }, mesh.indices);
}

test "optimizeVertexFetch orders referenced vertices by first index use" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(2, 0, 0),
        makeVertex(3, 0, 0),
        makeVertex(4, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 3, 1, 4, 3, 1, 2 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    try mesh.optimizeVertexFetchWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 1, 3 }, mesh.indices);
    try std.testing.expectEqual([3]f32{ 3, 0, 0 }, mesh.vertices[0].position);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, mesh.vertices[1].position);
    try std.testing.expectEqual([3]f32{ 4, 0, 0 }, mesh.vertices[2].position);
    try std.testing.expectEqual([3]f32{ 2, 0, 0 }, mesh.vertices[3].position);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, mesh.vertices[4].position);
}

test "vertex cache optimization preserves triangles and reduces misses on shuffled grid" {
    const allocator = std.testing.allocator;

    const grid_size = 9;
    const row_vertices = grid_size + 1;
    const vertex_count = row_vertices * row_vertices;
    const triangle_count = grid_size * grid_size * 2;

    const vertices = try allocator.alloc(RawVertex, vertex_count);
    for (0..row_vertices) |y| {
        for (0..row_vertices) |x| {
            vertices[y * row_vertices + x] = makeVertex(@floatFromInt(x), @floatFromInt(y), 0);
        }
    }

    const ordered_indices = try allocator.alloc(u32, triangle_count * 3);
    defer allocator.free(ordered_indices);

    var triangle_index: usize = 0;
    for (0..grid_size) |y| {
        for (0..grid_size) |x| {
            const v0: u32 = @intCast(y * row_vertices + x);
            const v1: u32 = @intCast(y * row_vertices + x + 1);
            const v2: u32 = @intCast((y + 1) * row_vertices + x);
            const v3: u32 = @intCast((y + 1) * row_vertices + x + 1);

            ordered_indices[triangle_index * 3 + 0] = v0;
            ordered_indices[triangle_index * 3 + 1] = v1;
            ordered_indices[triangle_index * 3 + 2] = v2;
            triangle_index += 1;

            ordered_indices[triangle_index * 3 + 0] = v1;
            ordered_indices[triangle_index * 3 + 1] = v3;
            ordered_indices[triangle_index * 3 + 2] = v2;
            triangle_index += 1;
        }
    }

    const indices = try allocator.alloc(u32, triangle_count * 3);
    for (0..triangle_count) |out_triangle| {
        const in_triangle = (out_triangle * 37) % triangle_count;
        indices[out_triangle * 3 + 0] = ordered_indices[in_triangle * 3 + 0];
        indices[out_triangle * 3 + 1] = ordered_indices[in_triangle * 3 + 1];
        indices[out_triangle * 3 + 2] = ordered_indices[in_triangle * 3 + 2];
    }

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    const original_indices = try allocator.dupe(u32, mesh.indices);
    defer allocator.free(original_indices);
    const misses_before = countVertexCacheMisses(mesh.indices);

    try mesh.optimizeVertexCache(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    const misses_after = countVertexCacheMisses(mesh.indices);
    try std.testing.expect(misses_after < misses_before);
    try expectSameTriangles(allocator, original_indices, mesh.indices);
}

test "vertex cache optimization does not move triangles across submesh ranges" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.alloc(RawVertex, 12);
    for (vertices, 0..) |*vertex, i| {
        vertex.* = makeVertex(@floatFromInt(i), 0, 0);
    }

    const indices = try allocator.dupe(u32, &.{
        0, 1, 2, 2, 1, 3, 2, 3, 4,  4,  3, 5,
        6, 7, 8, 8, 7, 9, 8, 9, 10, 10, 9, 11,
    });
    const submeshes = try allocator.dupe(RawSubmesh, &.{
        .{ .index_offset = 0, .index_count = 12, .material_index = 0 },
        .{ .index_offset = 12, .index_count = 12, .material_index = 1 },
    });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = submeshes,
        .name = null,
    };

    const first_submesh_before = try allocator.dupe(u32, mesh.indices[0..12]);
    defer allocator.free(first_submesh_before);
    const second_submesh_before = try allocator.dupe(u32, mesh.indices[12..24]);
    defer allocator.free(second_submesh_before);

    try mesh.optimizeVertexCache(allocator);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);
    defer allocator.free(mesh.submeshes);

    try expectSameTriangles(allocator, first_submesh_before, mesh.indices[0..12]);
    try expectSameTriangles(allocator, second_submesh_before, mesh.indices[12..24]);
}

test "quad with shared edge deduplicates from 6 to 4 vertices" {
    const allocator = std.testing.allocator;

    // Quad: two triangles sharing edge v1-v2
    //   v0 --- v1
    //   |  \    |
    //   |   \   |
    //   v2 --- v3
    //
    // Triangle A: v0, v1, v2
    // Triangle B: v1, v3, v2  (duplicates v1 and v2)

    const v0 = makeVertex(0, 1, 0);
    const v1 = makeVertex(1, 1, 0);
    const v2 = makeVertex(0, 0, 0);
    const v3 = makeVertex(1, 0, 0);

    const vertices = try allocator.dupe(RawVertex, &.{ v0, v1, v2, v1, v3, v2 });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len);
}

test "mesh with no duplicates is unchanged" {
    const allocator = std.testing.allocator;

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(0, 1, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    // Early-return path: original slices are still owned by us
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    // Indices should be untouched
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, mesh.indices);
}

fn collidingVertexHash(vertex: *const RawVertex) u64 {
    return @intFromPtr(vertex) % 1;
}

test "deduplication handles hash collisions" {
    const allocator = std.testing.allocator;
    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0),
        makeVertex(1, 0, 0),
        makeVertex(0, 0, 0),
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2 });
    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };
    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithHashAndScratch(allocator, &scratch, collidingVertexHash);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 2), mesh.vertices.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, mesh.indices);
}

test "all remapped indices are valid" {
    const allocator = std.testing.allocator;

    // 4 triangles, heavy duplication
    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(0, 0, 0), // 0
        makeVertex(1, 0, 0), // 1
        makeVertex(0, 1, 0), // 2
        makeVertex(1, 0, 0), // 3 = dup of 1
        makeVertex(0, 1, 0), // 4 = dup of 2
        makeVertex(1, 1, 0), // 5
        makeVertex(0, 0, 0), // 6 = dup of 0
        makeVertex(1, 1, 0), // 7 = dup of 5
        makeVertex(0, 1, 0), // 8 = dup of 2
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    for (mesh.indices) |index| {
        try std.testing.expect(index < mesh.vertices.len);
    }
}

test "dedup preserves rendered triangles" {
    const allocator = std.testing.allocator;

    const v0 = makeVertex(0, 1, 0);
    const v1 = makeVertex(1, 1, 0);
    const v2 = makeVertex(0, 0, 0);
    const v3 = makeVertex(1, 0, 0);

    // Two triangles with duplicated vertices on the shared edge
    const original_verts = [_]RawVertex{ v0, v1, v2, v1, v3, v2 };
    const original_indices = [_]u32{ 0, 1, 2, 3, 4, 5 };

    // Capture the triangles before dedup (resolved to positions)
    const tri0_before = resolveTriangle(&original_verts, &original_indices, 0);
    const tri1_before = resolveTriangle(&original_verts, &original_indices, 3);

    const vertices = try allocator.dupe(RawVertex, &original_verts);
    const indices = try allocator.dupe(u32, &original_indices);

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    // Resolve triangles after dedup — should produce the same geometry
    const tri0_after = resolveTriangle(mesh.vertices, mesh.indices, 0);
    const tri1_after = resolveTriangle(mesh.vertices, mesh.indices, 3);

    try std.testing.expectEqualDeep(tri0_before, tri0_after);
    try std.testing.expectEqualDeep(tri1_before, tri1_after);
}

test "all vertices identical deduplicates to one" {
    const allocator = std.testing.allocator;

    const v = makeVertex(1, 2, 3);
    const vertices = try allocator.dupe(RawVertex, &.{ v, v, v, v, v });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 3, 4, 0 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 1), mesh.vertices.len);
    // Every index should now point to 0
    for (mesh.indices) |index| {
        try std.testing.expectEqual(@as(u32, 0), index);
    }
}

test "vertices differing only in optional fields are not deduplicated" {
    const allocator = std.testing.allocator;

    var v_with_normal = makeVertex(1, 0, 0);
    v_with_normal.normal = .{ 0, 1, 0 };

    const vertices = try allocator.dupe(RawVertex, &.{
        makeVertex(1, 0, 0), // no normal
        v_with_normal, // has normal
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1 });

    var mesh = RawMesh{
        .vertices = vertices,
        .indices = indices,
        .submeshes = &.{},
        .name = null,
    };

    var scratch = MeshScratch.init(allocator);
    defer scratch.deinit();
    _ = try mesh.deduplicateVerticesWithScratch(allocator, &scratch);
    defer allocator.free(mesh.vertices);
    defer allocator.free(mesh.indices);

    try std.testing.expectEqual(@as(usize, 2), mesh.vertices.len);
}

test "quantizeUV maps the normalized range to all u16 values" {
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    const result = RawVertex.quantizeUV(.{ 0.0, 1.0 }, &bounds);
    try std.testing.expectEqual(@as(u16, 0), result[0]);
    try std.testing.expectEqual(@as(u16, 65535), result[1]);
}

test "quantizeUV rounds to nearest" {
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    try std.testing.expectEqual([2]u16{ 32768, 32768 }, RawVertex.quantizeUV(.{ 0.5, 0.5 }, &bounds));
    try std.testing.expectEqual([2]u16{ 16384, 49151 }, RawVertex.quantizeUV(.{ 0.25, 0.75 }, &bounds));
}

test "quantizeUV clamps out-of-range and NaN values" {
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    try std.testing.expectEqual([2]u16{ 0, 0 }, RawVertex.quantizeUV(.{ -0.5, std.math.nan(f32) }, &bounds));
    try std.testing.expectEqual([2]u16{ 65535, 65535 }, RawVertex.quantizeUV(.{ 1.5, 2.0 }, &bounds));
}

test "quantizeUV0 and quantizeUV1 return null when absent" {
    const v = makeVertex(0, 0, 0);
    const bounds = UV0Bounds{ .min = .{ 0, 0 }, .scale = .{ 1, 1 } };
    try std.testing.expectEqual(@as(?[2]u16, null), v.quantizeUV0(&bounds));
    try std.testing.expectEqual(@as(?[2]u16, null), v.quantizeUV1());
}

test "quantizeUV1 quantizes over [0, 1]" {
    var v = makeVertex(0, 0, 0);
    v.uv1 = .{ 0.5, 0.25 };
    try std.testing.expectEqual([2]u16{ 32768, 16384 }, v.quantizeUV1().?);
}

test "quantizePosition maps the AABB to the full u16 range" {
    const min: [3]f32 = .{ -1, 0, 5 };
    const max: [3]f32 = .{ 1, 10, 5 };
    try std.testing.expectEqual([4]u16{ 0, 0, 0, 0 }, quantizePosition(.{ -1, 0, 5 }, min, max));
    try std.testing.expectEqual([4]u16{ 65535, 65535, 0, 0 }, quantizePosition(.{ 1, 10, 5 }, min, max));
    try std.testing.expectEqual([4]u16{ 32768, 6554, 0, 0 }, quantizePosition(.{ 0, 1, 5 }, min, max));
}

test "encodeTangentOctahedral round-trips direction and handedness" {
    var v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[4]i8, null), v.encodeTangentOctahedral());
    v.tangent = .{ 1, 0, 0, 1 };
    try std.testing.expectEqual([4]i8{ 127, 0, 127, 0 }, v.encodeTangentOctahedral().?);
    v.tangent = .{ 0, 0, -1, -1 };
    const t = v.encodeTangentOctahedral().?;
    try std.testing.expectEqual(@as(i8, -127), t[2]);
    const decoded = decodeOctahedral(.{ @as(i16, t[0]) * 258, @as(i16, t[1]) * 258 });
    try expectNormalApproxEq(.{ 0, 0, -1 }, decoded, 0.01);
}

test "quantizeJointWeights renormalizes to sum 255" {
    var v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[4]u8, null), v.quantizeJointWeights());
    v.joint_weights = .{ 1.0, 0.0, 0.0, 0.0 };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 0 }, v.quantizeJointWeights().?);
    v.joint_weights = .{ 0.0, 0.0, 0.0, 0.0 };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 0 }, v.quantizeJointWeights().?);
    v.joint_weights = .{ std.math.inf(f32), 0.0, 0.0, 0.0 };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 0 }, v.quantizeJointWeights().?);
    v.joint_weights = .{ std.math.nan(f32), 0.5, -1.0, 0.5 };
    try std.testing.expectEqual([4]u8{ 0, 128, 0, 127 }, v.quantizeJointWeights().?);
    v.joint_weights = .{ std.math.floatMax(f32), std.math.floatMax(f32), 0.0, 0.0 };
    const huge = v.quantizeJointWeights().?;
    try std.testing.expectEqual(@as(u32, 255), @as(u32, huge[0]) + huge[1] + huge[2] + huge[3]);

    var prng = std.Random.DefaultPrng.init(9);
    const random = prng.random();
    for (0..1000) |_| {
        v.joint_weights = .{ random.float(f32), random.float(f32), random.float(f32), random.float(f32) * 0.01 };
        const w = v.quantizeJointWeights().?;
        try std.testing.expectEqual(@as(u32, 255), @as(u32, w[0]) + w[1] + w[2] + w[3]);
    }
}

test "encodeNormalOctahedral maps zero-length normals to +Z" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 0, 0, 0 };
    try std.testing.expectEqual([2]i16{ 0, 0 }, v.encodeNormalOctahedral().?);
}

/// Decode octahedral-encoded normal back to a unit vector (test helper).
fn decodeOctahedral(encoded: [2]i16) [3]f32 {
    var oct: [2]f32 = .{
        @as(f32, @floatFromInt(encoded[0])) / 32767.0,
        @as(f32, @floatFromInt(encoded[1])) / 32767.0,
    };

    const z = 1.0 - @abs(oct[0]) - @abs(oct[1]);

    if (z < 0.0) {
        const ox = oct[0];
        const oy = oct[1];
        oct[0] = (1.0 - @abs(oy)) * RawVertex.signNonZero(ox);
        oct[1] = (1.0 - @abs(ox)) * RawVertex.signNonZero(oy);
    }

    // Normalize
    const len = @sqrt(oct[0] * oct[0] + oct[1] * oct[1] + z * z);
    return .{ oct[0] / len, oct[1] / len, z / len };
}

fn expectNormalApproxEq(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(expected[i], actual[i], tolerance);
    }
}

test "octahedral encode/decode [0, 0, 1] (up)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 0, 0, 1 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 0, 0, 1 }, decoded, 0.001);
}

test "octahedral encode/decode [1, 0, 0] (right)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 1, 0, 0 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 1, 0, 0 }, decoded, 0.001);
}

test "octahedral encode/decode [0.577, 0.577, 0.577] (diagonal)" {
    var v = makeVertex(0, 0, 0);
    const s = 1.0 / @sqrt(3.0);
    v.normal = .{ s, s, s };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ s, s, s }, decoded, 0.001);
}

test "octahedral encode/decode [0, 0, -1] (down, exercises fold)" {
    var v = makeVertex(0, 0, 0);
    v.normal = .{ 0, 0, -1 };
    const encoded = v.encodeNormalOctahedral().?;
    const decoded = decodeOctahedral(encoded);
    try expectNormalApproxEq(.{ 0, 0, -1 }, decoded, 0.001);
}

test "encodeNormalOctahedral returns null when normal is absent" {
    const v = makeVertex(0, 0, 0);
    try std.testing.expectEqual(@as(?[2]i16, null), v.encodeNormalOctahedral());
}

test "octahedral encode/decode 1000 random normals within 1 degree" {
    // 1 degree in radians
    const max_angle = 1.0 * std.math.pi / 180.0;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..1000) |_| {
        // Generate random unit normal via spherical coordinates
        const theta = rand.float(f32) * 2.0 * std.math.pi;
        const cos_phi = rand.float(f32) * 2.0 - 1.0;
        const sin_phi = @sqrt(1.0 - cos_phi * cos_phi);

        const normal: [3]f32 = .{
            sin_phi * @cos(theta),
            sin_phi * @sin(theta),
            cos_phi,
        };

        var v = makeVertex(0, 0, 0);
        v.normal = normal;
        const encoded = v.encodeNormalOctahedral().?;
        const decoded = decodeOctahedral(encoded);

        // Angular error: acos(dot(normal, decoded))
        const dot = normal[0] * decoded[0] + normal[1] * decoded[1] + normal[2] * decoded[2];
        const angle = std.math.acos(std.math.clamp(dot, -1.0, 1.0));
        try std.testing.expect(angle < max_angle);
    }
}
