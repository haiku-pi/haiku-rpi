# Initial cache (cmake -C) for Blender 3.6.23 on Haiku arm64: the minimal build of
# docs/design/blender.md §4 (milestone M2). scripts/build-blender.sh configures both the host build of
# the generators (makesdna, makesrna, ...) and the cross build with this one file, and fails when the two
# end with different WITH_* values: RNA output depends on them.
#
# On: GHOST through SDL2, Python 3.10, Cycles (CPU) with TBB, OpenEXR/WebP/Cineon images, libmv, Bullet.
# Off: everything §4 marks optional for the first build, the other windowing systems, the platform
# extras (X11, Wayland, NDOF, IME, jemalloc), the linkers other than ld.bfd, tests and the man page
# (which runs the built blender).

macro(blender_option name value)
  set(${name} ${value} CACHE BOOL "" FORCE)
endmacro()

# windowing + GPU
blender_option(WITH_GHOST_SDL ON)
blender_option(WITH_SDL ON)
blender_option(WITH_SDL_DYNLOAD OFF)
blender_option(WITH_GHOST_X11 OFF)
blender_option(WITH_GHOST_WAYLAND OFF)
blender_option(WITH_GHOST_XDND OFF)
blender_option(WITH_X11_XINPUT OFF)
blender_option(WITH_X11_XF86VMODE OFF)
blender_option(WITH_X11_XFIXES OFF)
blender_option(WITH_HEADLESS OFF)
blender_option(WITH_VULKAN_BACKEND OFF)
blender_option(WITH_GPU_BUILDTIME_SHADER_BUILDER OFF)
blender_option(WITH_INPUT_NDOF OFF)
blender_option(WITH_INPUT_IME OFF)
blender_option(WITH_XR_OPENXR OFF)

# Python (3.10: blender.md §4.1)
blender_option(WITH_PYTHON ON)
set(PYTHON_VERSION 3.10 CACHE STRING "" FORCE)
blender_option(WITH_PYTHON_INSTALL OFF)
blender_option(WITH_PYTHON_INSTALL_NUMPY OFF)
blender_option(WITH_PYTHON_INSTALL_REQUESTS OFF)
blender_option(WITH_PYTHON_INSTALL_ZSTANDARD OFF)
# -7: NumPy 1.26 for Python 3.10 (numpy_python3.10): the `aud` module (audaspace's Python API)
blender_option(WITH_PYTHON_NUMPY ON)
blender_option(WITH_PYTHON_MODULE OFF)
blender_option(WITH_PYTHON_SAFETY OFF)

# Cycles: CPU only, its own BVH
blender_option(WITH_TBB ON)
blender_option(WITH_CYCLES ON)
blender_option(WITH_CYCLES_EMBREE OFF)
blender_option(WITH_CYCLES_OSL OFF)
blender_option(WITH_CYCLES_PATH_GUIDING OFF)
blender_option(WITH_CYCLES_LOGGING OFF)
blender_option(WITH_CYCLES_DEVICE_CUDA OFF)
blender_option(WITH_CYCLES_DEVICE_OPTIX OFF)
blender_option(WITH_CYCLES_DEVICE_HIP OFF)
blender_option(WITH_CYCLES_DEVICE_HIPRT OFF)
blender_option(WITH_CYCLES_DEVICE_METAL OFF)
blender_option(WITH_CYCLES_DEVICE_ONEAPI OFF)
blender_option(WITH_CYCLES_CUDA_BINARIES OFF)
blender_option(WITH_CYCLES_HIP_BINARIES OFF)
blender_option(WITH_CYCLES_STANDALONE OFF)
blender_option(WITH_CYCLES_STANDALONE_GUI OFF)
blender_option(WITH_CYCLES_HYDRA_RENDER_DELEGATE OFF)
blender_option(WITH_CYCLES_NATIVE_ONLY OFF)
# -7: OpenImageDenoise 2.5 (the oidn package; its NEON CPU device, patches/blender/0011)
blender_option(WITH_OPENIMAGEDENOISE ON)
# -8: NanoVDB (OpenVDB 10.1's headers): Cycles renders OpenVDB volumes from the compact NanoVDB form
blender_option(WITH_NANOVDB ON)

# images: OpenImageIO is required; OpenEXR, WebP, Cineon/DPX on, OpenJPEG off
blender_option(WITH_IMAGE_OPENEXR ON)
blender_option(WITH_IMAGE_WEBP ON)
blender_option(WITH_IMAGE_CINEON ON)
blender_option(WITH_IMAGE_OPENJPEG OFF)
blender_option(WITH_SYSTEM_FREETYPE OFF)

# M6: OpenColorIO (Filmic and the other view transforms) and OpenSubdiv (Subdivision Surface, Multires)
blender_option(WITH_OPENCOLORIO ON)
blender_option(WITH_OPENSUBDIV ON)
# -5: video (FFmpeg 6.1: the ffmpeg6 package) and audio (audaspace on SDL2; OpenAL, JACK, PulseAudio stay off)
blender_option(WITH_CODEC_FFMPEG ON)
blender_option(WITH_AUDASPACE ON)

# off in the minimal build (blender.md §4; M6, -7 and -8 added most of them back)
# -8: OpenVDB 10.1 with Blosc (voxel remesh, .vdb import, volume nodes, the OpenVDB fluid cache)
blender_option(WITH_OPENVDB ON)
blender_option(WITH_OPENVDB_BLOSC ON)
# -9: USD import/export (usd 24.08: libusd_ms, oneTBB; blender.md §7.16)
blender_option(WITH_USD ON)
# -7: Alembic import/export (alembic 1.8.3), fluid simulation (Mantaflow, bundled), the Ocean modifier (FFTW)
blender_option(WITH_ALEMBIC ON)
blender_option(WITH_MATERIALX OFF)
blender_option(WITH_OPENCOLLADA OFF)
blender_option(WITH_MOD_FLUID ON)
blender_option(WITH_MOD_OCEANSIM ON)
blender_option(WITH_CODEC_SNDFILE OFF)
blender_option(WITH_OPENAL OFF)
blender_option(WITH_JACK OFF)
blender_option(WITH_PULSEAUDIO OFF)
blender_option(WITH_COREAUDIO OFF)
blender_option(WITH_WASAPI OFF)
blender_option(WITH_FFTW3 ON)
# -8: GMP (the Boolean modifier's Exact solver), potrace (Grease Pencil Trace Image), libharu (Grease
# Pencil PDF export), Boost 1.83 -2 (OpenVDB, Quadriflow, i18n through Boost.Locale), translations,
# Quadriflow (remesh) and Draco (glTF mesh compression; patches/blender/0014) — the last two bundled
blender_option(WITH_GMP ON)
blender_option(WITH_POTRACE ON)
blender_option(WITH_HARU ON)
blender_option(WITH_BOOST ON)
blender_option(WITH_INTERNATIONAL ON)
blender_option(WITH_QUADRIFLOW ON)
blender_option(WITH_DRACO ON)
blender_option(WITH_MEM_JEMALLOC OFF)
blender_option(WITH_OPENMP OFF)

# on (bundled in extern/ and intern/)
blender_option(WITH_LIBMV ON)
blender_option(WITH_BULLET ON)
blender_option(WITH_FREESTYLE ON)
blender_option(WITH_COMPOSITOR_CPU ON)
# Cycles' XML reader needs it (OIIO 2.4's own copy is not where Blender 3.6 looks for it)
blender_option(WITH_PUGIXML ON)

# build: a missing library is an error, not a silently disabled option (set_and_warn_library_found
# only shadows the cache entry with a normal variable, so a WITH_* compare of the caches cannot see it)
blender_option(WITH_STRICT_BUILD_OPTIONS ON)
blender_option(WITH_GTESTS OFF)
blender_option(WITH_BUILDINFO OFF)
blender_option(WITH_DOC_MANPAGE OFF)
blender_option(WITH_BLENDER_THUMBNAILER OFF)
blender_option(WITH_LINKER_GOLD OFF)
blender_option(WITH_LINKER_LLD OFF)
blender_option(WITH_LINKER_MOLD OFF)
blender_option(WITH_COMPILER_ASAN OFF)
blender_option(WITH_INSTALL_PORTABLE ON)
