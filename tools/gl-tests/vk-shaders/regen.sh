#!/bin/sh
# regen.sh — compile vktest's shaders to SPIR-V C arrays (*.spv.h, checked in, so that the build
# needs no shader compiler). Needs glslangValidator (Debian/Ubuntu: glslang-tools).
set -e
cd "$(dirname "$0")"
glslangValidator -V --target-env vulkan1.1 --vn tri_vert_spv -o tri.vert.spv.h tri.vert
glslangValidator -V --target-env vulkan1.1 --vn tri_frag_spv -o tri.frag.spv.h tri.frag
glslangValidator -V --target-env vulkan1.1 --vn fill_comp_spv -o fill.comp.spv.h fill.comp
