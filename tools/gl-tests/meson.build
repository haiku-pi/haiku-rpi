# GL and Vulkan smoke tests for Haiku, cross-built with tools/meson/haiku-arm64.cross against the sysroot
# that scripts/build-gl-stack.sh fills (libglvnd's EGL/GLESv2).
project('gl-tests', 'c', 'cpp', default_options : ['c_std=gnu11', 'warning_level=2'])

dep_egl = dependency('egl')
dep_glesv2 = dependency('glesv2')

executable('gltri', 'gltri.c', dependencies : [dep_egl, dep_glesv2], install : true)

# windowed: BGLView (libglvnd's HGL libGL.so) + desktop GL
dep_gl = dependency('gl')
dep_be = meson.get_compiler('cpp').find_library('be')
executable('glview', 'glview.cpp', dependencies : [dep_gl, dep_be], install : true)

# the display's retrace semaphore (BScreen::WaitForRetrace)
executable('retrace', 'retrace.cpp', dependencies : [dep_be], install : true)

# the mouse pointer moved from a program (the hardware cursor plane's test)
executable('cursor-move', 'cursor-move.cpp', dependencies : [dep_be], install : true)

# headless Vulkan: the Khronos loader (scripts/build-gl-stack.sh "vulkan") and V3DV
dep_vulkan = dependency('vulkan')
executable('vktest', 'vktest.c', dependencies : [dep_vulkan], install : true)

# windowed Vulkan: a BWindow's view as the surface (Mesa's <vulkan/vk_haiku_surface.h>)
executable('vkcube', 'vkcube.cpp', dependencies : [dep_vulkan, dep_be], install : true)
