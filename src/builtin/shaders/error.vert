#version 330 core
layout(location = 0) in vec4 a_position; // unorm16 over the part AABB

uniform mat4 u_model;
uniform mat4 u_view;
uniform mat4 u_projection;
uniform vec3 u_pos_min;
uniform vec3 u_pos_scale;

out vec3 v_object_pos;

void main() {
  v_object_pos = u_pos_min + a_position.xyz * u_pos_scale;
  gl_Position = u_projection * u_view * u_model * vec4(v_object_pos, 1.0);
}
