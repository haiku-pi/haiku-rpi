#version 450
// vkcube: a cube without vertex buffers, 36 vertices (6 faces of 2 triangles), each face its colour
layout(push_constant) uniform Push {
	mat4 mvp;
	vec4 tint; // a > 0: every face this colour (vkcube's screen check)
} pc;

layout(location = 0) out vec3 color;

const vec3 kCorners[8] = vec3[8](
	vec3(-1, -1, -1), vec3(1, -1, -1), vec3(1, 1, -1), vec3(-1, 1, -1),
	vec3(-1, -1, 1), vec3(1, -1, 1), vec3(1, 1, 1), vec3(-1, 1, 1));
const int kIndices[36] = int[36](
	0, 1, 2, 2, 3, 0,  // z = -1
	4, 6, 5, 6, 4, 7,  // z = +1
	0, 3, 7, 7, 4, 0,  // x = -1
	1, 5, 6, 6, 2, 1,  // x = +1
	0, 4, 5, 5, 1, 0,  // y = -1
	3, 2, 6, 6, 7, 3); // y = +1
const vec3 kColors[6] = vec3[6](
	vec3(1.0, 0.2, 0.2), vec3(0.2, 1.0, 0.2), vec3(0.2, 0.2, 1.0),
	vec3(1.0, 1.0, 0.2), vec3(0.2, 1.0, 1.0), vec3(1.0, 0.2, 1.0));

void main()
{
	gl_Position = pc.mvp * vec4(kCorners[kIndices[gl_VertexIndex]], 1.0);
	color = pc.tint.a > 0.0 ? pc.tint.rgb : kColors[gl_VertexIndex / 6];
}
