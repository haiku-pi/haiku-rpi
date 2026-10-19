#version 450
// vktest: a triangle without vertex buffers (Vulkan clip space: y points down)
const vec2 kPositions[3] = vec2[3](vec2(0.0, -0.75), vec2(0.75, 0.75), vec2(-0.75, 0.75));

void main()
{
	gl_Position = vec4(kPositions[gl_VertexIndex], 0.0, 1.0);
}
