# blender-b9.py — blender -9 (docs/design/blender.md §7.16): USD import/export, each check graded by a
# "BB9X <name>: PASS/FAIL ..." line. The same script runs on the official x86-64 Blender 3.6.23, whose
# numbers are the reference the Pi's must equal (blender-b9.sh prints both):
#   options   bpy.app.build_options.usd
#   export    the factory scene plus a subdivided Suzanne with a material, exported to .usdc, .usda and
#             .usdz; each file re-imported into an empty scene: objects by type, mesh vertices/faces,
#             materials. The .usda text is hashed without its "doc" line (Blender's version string), so
#             the Pi's file can be compared with x86-64's byte for byte
#   refimport FILE...  files the reference wrote (--ref DIR: factory.usdc, factory.usda, factory.usdz)
#             imported: the same counts as the reference's own re-import
#   shapes    a hand-written .usda with the five UsdGeom gprims (Cube, Sphere, Cylinder, Cone, Capsule):
#             Blender meshes them through usdImaging's shape adapters; vertex/face counts per object
#
#   blender -b --factory-startup --python blender-b9.py -- OUTDIR [NAME ...] [--ref DIR]
import hashlib
import os
import sys
import time
import traceback

import bpy

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["/tmp/bb9x"]
ref = None
if "--ref" in args:
    ref = args[args.index("--ref") + 1]
    del args[args.index("--ref"):args.index("--ref") + 2]
out = args[0]
names = args[1:]
os.makedirs(out, exist_ok=True)


def say(*a):
    print("BB9X", *a, flush=True)


def check(name, fn):
    if names and name not in names:
        return
    start = time.perf_counter()
    try:
        ok, detail = fn()
    except Exception as e:  # report and go on with the next check
        ok, detail = False, "%s: %s" % (type(e).__name__, e)
        traceback.print_exc()
    say("%s: %s %s (%.1f s)" % (name, "PASS" if ok else "FAIL", detail, time.perf_counter() - start))


def empty_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def summary():
    """objects by type, total mesh vertices/faces (evaluated), materials: a comparable string"""
    types = {}
    verts = faces = 0
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in bpy.context.scene.objects:
        types[ob.type] = types.get(ob.type, 0) + 1
        if ob.type == 'MESH':
            me = ob.evaluated_get(dg).to_mesh()
            verts += len(me.vertices)
            faces += len(me.polygons)
            ob.evaluated_get(dg).to_mesh_clear()
    t = ",".join("%s=%d" % kv for kv in sorted(types.items()))
    return "objects %d [%s] verts %d faces %d materials %d" % (
        len(bpy.context.scene.objects), t, verts, faces, len(bpy.data.materials))


def usda_hash(path):
    with open(path, "rb") as f:
        lines = [l for l in f.read().split(b"\n") if not l.strip().startswith(b"doc = ")]
    return hashlib.sha256(b"\n".join(lines)).hexdigest()[:16]


def options():
    return bpy.app.build_options.usd, "usd=%d" % bpy.app.build_options.usd


def build_scene():
    bpy.ops.wm.read_factory_settings(use_empty=False)
    bpy.ops.mesh.primitive_monkey_add(location=(3, 0, 0))
    monkey = bpy.context.active_object
    monkey.modifiers.new("Subdivision", 'SUBSURF').levels = 1
    mat = bpy.data.materials.new("Red")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.1, 0.1, 1)
    monkey.data.materials.append(mat)


def export():
    results = []
    ok = True
    for ext in ("usdc", "usda", "usdz"):
        build_scene()
        before = summary()
        path = os.path.join(out, "factory." + ext)
        if os.path.exists(path):
            os.remove(path)
        r = bpy.ops.wm.usd_export(filepath=path, export_materials=True, evaluation_mode='RENDER')
        size = os.path.getsize(path) if os.path.exists(path) else 0
        empty_scene()
        r2 = bpy.ops.wm.usd_import(filepath=path)
        after = summary()
        extra = " sha %s" % usda_hash(path) if ext == "usda" else ""
        say("export-%s: %s, %d bytes%s; scene %s; re-import %s -> %s" % (
            ext, list(r), size, extra, before, list(r2), after))
        ok = ok and r == {'FINISHED'} and r2 == {'FINISHED'} and size > 0 and "MESH=" in after
        results.append("%s %d B" % (ext, size))
    return ok, ", ".join(results)


def refimport():
    if not ref:
        return False, "no --ref DIR"
    parts = []
    ok = True
    for ext in ("usdc", "usda", "usdz"):
        path = os.path.join(ref, "factory." + ext)
        empty_scene()
        r = bpy.ops.wm.usd_import(filepath=path)
        s = summary()
        say("refimport-%s: %s %s" % (ext, list(r), s))
        ok = ok and r == {'FINISHED'} and "MESH=" in s
        parts.append(ext)
    return ok, "imported " + ", ".join(parts) + " from " + ref


SHAPES = """#usda 1.0
(
    defaultPrim = "World"
    metersPerUnit = 1
    upAxis = "Z"
)

def Xform "World"
{
    def Cube "Cube"
    {
        double size = 2
        double3 xformOp:translate = (0, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Sphere "Sphere"
    {
        double radius = 1
        double3 xformOp:translate = (3, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Cylinder "Cylinder"
    {
        double radius = 1
        double height = 2
        uniform token axis = "Z"
        double3 xformOp:translate = (6, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Cone "Cone"
    {
        double radius = 1
        double height = 2
        uniform token axis = "Z"
        double3 xformOp:translate = (9, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Capsule "Capsule"
    {
        double radius = 0.5
        double height = 1
        uniform token axis = "Z"
        double3 xformOp:translate = (12, 0, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
}
"""


def shapes():
    path = os.path.join(out, "shapes.usda")
    with open(path, "w") as f:
        f.write(SHAPES)
    empty_scene()
    r = bpy.ops.wm.usd_import(filepath=path)
    dg = bpy.context.evaluated_depsgraph_get()
    per = []
    for ob in sorted(bpy.context.scene.objects, key=lambda o: o.name):
        if ob.type == 'MESH':
            me = ob.evaluated_get(dg).to_mesh()
            per.append("%s=%d/%d" % (ob.name, len(me.vertices), len(me.polygons)))
            ob.evaluated_get(dg).to_mesh_clear()
    return r == {'FINISHED'} and len(per) == 5 and all(not p.endswith("=0/0") for p in per), \
        "%s %s" % (list(r), " ".join(per))


check("options", options)
check("export", export)
check("refimport", refimport)
check("shapes", shapes)
say("done")
