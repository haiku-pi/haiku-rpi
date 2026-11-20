# blender-b7-extras.py — blender -7 (docs/design/blender.md §7.14): the features -7 adds besides denoising
# and aud, each checked headless and graded by a "BB7X <name>: PASS/FAIL ..." line:
#   alembic  the factory scene exported to Alembic, imported into an empty scene (camera and cube: Alembic
#            has no lights)
#   ocean    an Ocean modifier (FFTW) on a plane: evaluated vertex count and a displaced z
#   fluid    a Mantaflow smoke domain baked for 6 frames at resolution 24 (cache files written)
#
#   blender -b --factory-startup --python blender-b7-extras.py -- OUTDIR
import glob
import os
import sys
import time
import traceback

import bpy

out = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/bb7x"
os.makedirs(out, exist_ok=True)


def say(*args):
    print("BB7X", *args, flush=True)


def check(name, fn):
    start = time.perf_counter()
    try:
        ok, detail = fn()
    except Exception as e:  # report and go on with the next check
        ok, detail = False, "%s: %s" % (type(e).__name__, e)
        traceback.print_exc()
    say("%s: %s %s (%.1f s)" % (name, "PASS" if ok else "FAIL", detail, time.perf_counter() - start))


def alembic():
    path = os.path.join(out, "factory.abc")
    bpy.ops.wm.alembic_export(filepath=path, start=1, end=1)
    size = os.path.getsize(path)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.alembic_import(filepath=path)
    objects = sorted(o.name for o in bpy.data.objects)
    cube = bpy.data.objects.get("Cube")
    verts = len(cube.data.vertices) if cube and cube.type == 'MESH' else -1
    return verts == 8 and len(objects) >= 2, "%d bytes, objects %s, Cube vertices %d" % (size, objects, verts)


def ocean():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.mesh.primitive_plane_add(size=2)
    plane = bpy.context.active_object
    mod = plane.modifiers.new("ocean", 'OCEAN')
    mod.resolution = 7
    mod.wave_scale = 2.0
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = plane.evaluated_get(dg).data
    zs = [v.co.z for v in mesh.vertices]
    span = max(zs) - min(zs)
    return len(zs) > 4 and span > 0.0, "%d vertices, z span %.3f" % (len(zs), span)


def fluid():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    # the smoke source first: a domain made before its flow object fails its first evaluation in a script
    # (also with the official x86-64 Blender 3.6.23, always with -t 1: mantaflow's smoke grids are not
    # made yet, "'NoneType' object has no attribute 'getDataPointer'")
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.4, location=(0, 0, -1.2))
    flow = bpy.context.active_object
    fm = flow.modifiers.new("fluid", 'FLUID')
    fm.fluid_type = 'FLOW'
    fm.flow_settings.flow_type = 'SMOKE'
    fm.flow_settings.flow_behavior = 'INFLOW'
    bpy.ops.mesh.primitive_cube_add(size=4, location=(0, 0, 0))
    domain = bpy.context.active_object
    mod = domain.modifiers.new("fluid", 'FLUID')
    mod.fluid_type = 'DOMAIN'
    settings = mod.domain_settings
    settings.domain_type = 'GAS'
    settings.resolution_max = 24
    cache = os.path.join(out, "fluid-cache")
    settings.cache_directory = cache
    settings.cache_type = 'ALL'
    settings.cache_frame_start = 1
    settings.cache_frame_end = 6
    bpy.context.view_layer.objects.active = domain
    domain.select_set(True)
    with bpy.context.temp_override(object=domain, active_object=domain):
        result = bpy.ops.fluid.bake_all()
    files = glob.glob(os.path.join(cache, "**", "*.*"), recursive=True)
    data = [f for f in files if "/data/" in f]
    return bool(data), "%s, %d cache files (%d data), format %s" % (
        sorted(result), len(files), len(data), settings.cache_data_format)


check("alembic", alembic)
check("ocean", ocean)
check("fluid", fluid)
say("done")
