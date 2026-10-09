#version 330 core
// VARIANTS: ALPHA_TEST, ALPHA_BLEND, DOUBLE_SIDED, HAS_ALBEDO_MAP, HAS_NORMAL_MAP, HAS_AO, HAS_EMISSIVE, HAS_METALLIC_ROUGHNESS_MAP

// Positions are unorm16 over the part AABB; tangents are snorm8 octahedral
// xy plus a handedness sign in z.
layout(location = 0) in vec4 a_position;
layout(location = 1) in vec2 a_normal_oct;
layout(location = 2) in vec2 a_uv0;
layout(location = 3) in vec2 a_uv1;
layout(location = 4) in vec4 a_tangent;

uniform mat4 u_model;
uniform mat4 u_view;
uniform mat4 u_projection;
uniform mat3 u_normal_matrix;
uniform vec2 u_uv0_min;
uniform vec2 u_uv0_scale;
uniform vec3 u_pos_min;
uniform vec3 u_pos_scale;

out vec3 v_world_pos;
out vec3 v_normal;
out vec4 v_tangent;
out vec2 v_uv0;
out vec2 v_uv1;

// Meshopt-style octahedral decode. Normals arrive as two normalized shorts.
vec3 decodeOctNormal(vec2 e) {
  vec3 n = vec3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
  float t = max(-n.z, 0.0);
  n.x += (n.x >= 0.0) ? -t : t;
  n.y += (n.y >= 0.0) ? -t : t;
  return normalize(n);
}

void main() {
  vec4 world = u_model * vec4(u_pos_min + a_position.xyz * u_pos_scale, 1.0);
  v_world_pos = world.xyz;

  v_normal = normalize(u_normal_matrix * decodeOctNormal(a_normal_oct));
  float handedness = a_tangent.z < 0.0 ? -1.0 : 1.0;
  v_tangent = vec4(normalize(u_normal_matrix * decodeOctNormal(a_tangent.xy)), handedness);

  v_uv0 = u_uv0_min + a_uv0 * u_uv0_scale;
  v_uv1 = a_uv1;

  gl_Position = u_projection * u_view * world;
}
