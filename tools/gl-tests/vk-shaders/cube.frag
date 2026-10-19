#version 450
// vkcube: the face's colour
layout(location = 0) in vec3 color;
layout(location = 0) out vec4 outColor;

void main()
{
	outColor = vec4(color, 1.0);
}
