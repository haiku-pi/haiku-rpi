# GL and Vulkan smoke tests for Haiku, cross-built with tools/meson/haiku-arm64.cross against the sysroot
# that scripts/build-gl-stack.sh fills (libglvnd's EGL/GLESv2).
project('gl-tests', 'c', 'cpp', default_options : ['c_std=gnu11', 'warning_level=2'])

dep_egl = dependency('egl')
dep_glesv2 = dependency('glesv2')

executable('gltri', 'gltri.c', dependencies : [dep_egl, dep_glesv2], install : true)
# glGenerateMipmap on non-power-of-two textures, every level read back (docs/design/gpu-v3d.md §6)
executable('glmipnpot', 'glmipnpot.c', dependencies : [dep_egl, dep_glesv2], install : true)

# GL_MESA_map_buffer_client_pointer the way Wine's WoW64 OpenGL uses it (docs/design/gl-client-pointer.md);
# desktop GL through EGL (libglvnd's libOpenGL)
dep_opengl = dependency('opengl')
executable('clientptr', 'clientptr.c', dependencies : [dep_egl, dep_opengl], install : true)

# windowed: BGLView (libglvnd's HGL libGL.so) + desktop GL
dep_gl = dependency('gl')
dep_be = meson.get_compiler('cpp').find_library('be')
executable('glview', 'glview.cpp', dependencies : [dep_gl, dep_be], install : true)
# windowed OpenGL ES: BGLView with BGL_CONTEXT_ES (the GLES functions from libGLESv2)
executable('glview-es', 'glview-es.cpp', dependencies : [dep_gl, dep_glesv2, dep_be], install : true)

# full-screen GL on an overlay plane: page flips, vsync, missed flips (docs/design/gpu-stage6.md)
executable('glflip', 'glflip.cpp', dependencies : [dep_gl, dep_be], install : true)

# the display's retrace semaphore (BScreen::WaitForRetrace)
executable('retrace', 'retrace.cpp', dependencies : [dep_be], install : true)

# the mouse pointer moved from a program (the hardware cursor plane's test)
executable('cursor-move', 'cursor-move.cpp', dependencies : [dep_be], install : true)

# the cost of each step of presenting a frame: CPU copies, SYNC_BO, app_server's DrawBitmap
# (docs/design/gpu-present.md)
dep_drm = dependency('libdrm')
# app_server's keyed row writers at app_server's -O2 (-O3 turns the old one into another loop)
lib_keying = static_library('present-bench-keying', 'present-bench-keying.cpp',
  override_options : ['optimization=2'])
executable('present-bench', 'present-bench.cpp', dependencies : [dep_be, dep_drm],
  link_with : lib_keying, install : true)

# headless Vulkan: the Khronos loader (scripts/build-gl-stack.sh "vulkan") and V3DV
dep_vulkan = dependency('vulkan')
executable('vktest', 'vktest.c', dependencies : [dep_vulkan], install : true)

# windowed Vulkan: a BWindow's view as the surface (Mesa's <vulkan/vk_haiku_surface.h>)
executable('vkcube', 'vkcube.cpp', dependencies : [dep_vulkan, dep_be], install : true)

# which OpenGL versions/profiles each context kind gets, and the version gates' missing extensions
# (docs/design/desktop-gl.md); EGL only, GL entry points through eglGetProcAddress
executable('glinfo', 'glinfo.c', dependencies : [dep_egl], install : true)
# OpenGL 3.2/3.3 core features rendered and read back, emulated depth clamping above all (docs/design/desktop-gl.md)
executable('glcore', 'glcore.c', dependencies : [dep_egl, dep_opengl], install : true)
# windowed core-profile desktop GL: BGLView with BGL_CONTEXT_CORE (docs/design/desktop-gl.md)
executable('glview-core', 'glview-core.cpp', dependencies : [dep_gl, dep_be], install : true)
