#version 450
// vktest: the triangle's colour (exact in UNORM8: 255, 0, 255, 255)
layout(location = 0) out vec4 color;

void main()
{
	color = vec4(1.0, 0.0, 1.0, 1.0);
}
