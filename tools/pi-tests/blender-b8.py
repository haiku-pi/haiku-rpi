# blender-b8.py — blender -8 (docs/design/blender.md §7.15): the features -8 adds, each graded by a
# "BB8X <name>: PASS/FAIL ..." line. The same script runs on the official x86-64 Blender 3.6.23, whose
# numbers are the reference the Pi's must equal (blender-b8.sh compares them):
#   options   bpy.app.build_options: openvdb, potrace, haru, international (and what -7 had)
#   voxel     voxel remesh (OpenVDB): a Remesh modifier in Voxel mode on Suzanne, and the Voxel Remesh
#             operator on a UV sphere; vertex/face counts must change (without OpenVDB both leave the
#             mesh as it was) and equal the reference
#   quadriflow  the QuadriFlow Remesh operator on Suzanne (target 1000 faces)
#   boolean   the Boolean modifier, Exact solver (GMP) and Fast, on two boxes sharing faces (coplanar
#             union) and on a cube minus a sphere with self-intersection on; without GMP Exact silently
#             gives Fast's result, so Exact must differ from Fast where the reference's does
#   vdbwrite  a Mantaflow smoke domain baked with the OpenVDB cache format, Blosc compression (the
#             reference makes the .vdb that "vdbrender" imports on the Pi)
#   vdbrender VDB  a .vdb imported as a Volume object (Principled Volume on its density grid), rendered
#             by Cycles at 320x240, 32 samples; the mean of the render must match the reference
#   vdbmesh   the Volume to Mesh modifier (OpenVDB's mesher) on the imported volume's density grid
#   gltf      glTF export of Suzanne (subdivided twice) without and with Draco compression; the Draco
#             file must be smaller, carry KHR_draco_mesh_compression and import again
#   i18n      the interface language set to German: a translated string, the locale files
#   pdf       Grease Pencil PDF export (libharu) of the Stroke object (needs a window: a 3D view)
#   trace     Grease Pencil Trace Image (potrace) of a generated PNG of a disc
#
#   blender -b --factory-startup --python blender-b8.py -- OUTDIR [NAME ...] [--vdb FILE]
import glob
import json
import os
import sys
import time
import traceback

import bpy

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else ["/tmp/bb8x"]
vdb = None
if "--vdb" in args:
    vdb = args[args.index("--vdb") + 1]
    del args[args.index("--vdb"):args.index("--vdb") + 2]
out = args[0]
names = args[1:]
os.makedirs(out, exist_ok=True)


def say(*a):
    print("BB8X", *a, flush=True)


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


def counts(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    me = ob.evaluated_get(dg).to_mesh()
    c = (len(me.vertices), len(me.polygons))
    ob.evaluated_get(dg).to_mesh_clear()
    return c


def activate(ob):
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob


def options():
    o = bpy.app.build_options
    keys = ["openvdb", "potrace", "haru", "international", "alembic", "fluid", "mod_oceansim", "mod_remesh",
            "opencolorio", "opensubdiv", "audaspace", "codec_ffmpeg"]
    have = {k: bool(getattr(o, k, False)) for k in keys}
    return all(have.values()), " ".join("%s=%d" % (k, v) for k, v in have.items())


def voxel():
    empty_scene()
    bpy.ops.mesh.primitive_monkey_add()
    monkey = bpy.context.active_object
    before = counts(monkey)
    m = monkey.modifiers.new("remesh", 'REMESH')
    m.mode = 'VOXEL'
    m.voxel_size = 0.05
    after = counts(monkey)
    bpy.ops.mesh.primitive_uv_sphere_add(location=(3, 0, 0))
    sphere = bpy.context.active_object
    sphere.data.remesh_voxel_size = 0.1
    activate(sphere)
    s0 = counts(sphere)
    result = bpy.ops.object.voxel_remesh()
    s1 = counts(sphere)
    ok = after != before and s1 != s0 and result == {'FINISHED'}
    return ok, "modifier %s -> %s; operator %s %s -> %s" % (before, after, sorted(result), s0, s1)


def quadriflow():
    empty_scene()
    bpy.ops.mesh.primitive_monkey_add()
    monkey = bpy.context.active_object
    activate(monkey)
    before = counts(monkey)
    result = bpy.ops.object.quadriflow_remesh(target_faces=1000, seed=0)
    after = counts(monkey)
    quads = sum(1 for p in monkey.data.polygons if len(p.vertices) == 4)
    return after != before and quads == after[1], "%s %s -> %s, %d quads" % (sorted(result), before, after, quads)


def boolean():
    res = {}
    for solver in ('EXACT', 'FAST'):
        empty_scene()
        # two 2x2x2 boxes overlapping by half, top and bottom faces coplanar
        bpy.ops.mesh.primitive_cube_add(size=2)
        a = bpy.context.active_object
        bpy.ops.mesh.primitive_cube_add(size=2, location=(1, 0, 0))
        b = bpy.context.active_object
        m = a.modifiers.new("bool", 'BOOLEAN')
        m.operation = 'UNION'
        m.object = b
        m.solver = solver
        res["union", solver] = counts(a)
        # a cube minus a sphere that pokes through it, self-intersection on
        bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 5, 0))
        c = bpy.context.active_object
        bpy.ops.mesh.primitive_uv_sphere_add(radius=1.2, location=(0.8, 5, 0.8))
        s = bpy.context.active_object
        m = c.modifiers.new("bool", 'BOOLEAN')
        m.operation = 'DIFFERENCE'
        m.object = s
        m.solver = solver
        if solver == 'EXACT':
            m.use_self = True
        res["diff", solver] = counts(c)
    detail = " ".join("%s/%s=%s" % (k[0], k[1], v) for k, v in res.items())
    differs = res["union", "EXACT"] != res["union", "FAST"] or res["diff", "EXACT"] != res["diff", "FAST"]
    return differs, detail


def vdbwrite():
    empty_scene()
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.4, location=(0, 0, -1.2))
    flow = bpy.context.active_object
    fm = flow.modifiers.new("fluid", 'FLUID')
    fm.fluid_type = 'FLOW'
    fm.flow_settings.flow_type = 'SMOKE'
    fm.flow_settings.flow_behavior = 'INFLOW'
    bpy.ops.mesh.primitive_cube_add(size=4)
    domain = bpy.context.active_object
    mod = domain.modifiers.new("fluid", 'FLUID')
    mod.fluid_type = 'DOMAIN'
    st = mod.domain_settings
    st.domain_type = 'GAS'
    st.resolution_max = 32
    cache = os.path.join(out, "vdb-cache")
    st.cache_directory = cache
    st.cache_type = 'ALL'
    st.cache_frame_start = 1
    st.cache_frame_end = 12
    st.cache_data_format = 'OPENVDB'
    st.openvdb_cache_compress_type = 'BLOSC'
    activate(domain)
    with bpy.context.temp_override(object=domain, active_object=domain):
        result = bpy.ops.fluid.bake_all()
    files = sorted(glob.glob(os.path.join(cache, "data", "*.vdb")))
    size = sum(os.path.getsize(f) for f in files)
    return len(files) >= 12, "%s, %d .vdb files, %d bytes, last %s" % (
        sorted(result), len(files), size, os.path.basename(files[-1]) if files else "-")


def volume_scene(path):
    empty_scene()
    bpy.ops.object.volume_import(filepath=path, align='WORLD', location=(0, 0, 0))
    vol = bpy.context.active_object
    grids = vol.data.grids
    grids.load()
    names = sorted(g.name for g in grids)
    mat = bpy.data.materials.new("smoke")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    pv = nt.nodes.new('ShaderNodeVolumePrincipled')
    pv.inputs['Density'].default_value = 5.0
    mo = nt.nodes.new('ShaderNodeOutputMaterial')
    nt.links.new(pv.outputs['Volume'], mo.inputs['Volume'])
    vol.data.materials.append(mat)
    return vol, names


def vdbrender():
    if not vdb:
        return False, "no --vdb FILE"
    vol, names = volume_scene(vdb)
    sc = bpy.context.scene
    bpy.ops.object.camera_add(location=(0, -9, 0), rotation=(1.5708, 0, 0))
    sc.camera = bpy.context.active_object
    bpy.ops.object.light_add(type='SUN', rotation=(0.6, 0.3, 0))
    bpy.context.active_object.data.energy = 4.0
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 32
    sc.cycles.use_adaptive_sampling = False
    sc.cycles.use_denoising = False
    sc.cycles.seed = 1
    sc.render.resolution_x = 320
    sc.render.resolution_y = 240
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = True
    sc.render.image_settings.file_format = 'PNG'
    sc.render.filepath = os.path.join(out, "vdbrender.png")
    start = time.perf_counter()
    bpy.ops.render.render(write_still=True)
    t = time.perf_counter() - start
    img = bpy.data.images.load(sc.render.filepath)
    px = list(img.pixels)
    n = len(px) // 4
    alpha = [px[i * 4 + 3] for i in range(n)]
    cover = sum(1 for a in alpha if a > 0.02) / n
    mean_a = sum(alpha) / n
    mean_r = sum(px[i * 4] for i in range(n)) / n
    stats = {"grids": names, "cover": round(cover, 4), "alpha": round(mean_a, 4), "red": round(mean_r, 4)}
    with open(os.path.join(out, "vdbrender.json"), "w") as f:
        json.dump(stats, f)
    return cover > 0.01 and "density" in names, "%s, render %.1f s" % (json.dumps(stats), t)


def vdbmesh():
    if not vdb:
        return False, "no --vdb FILE"
    vol, names = volume_scene(vdb)
    # the modifier sits on a mesh object and reads the volume object
    me = bpy.data.meshes.new("frommesh")
    ob = bpy.data.objects.new("frommesh", me)
    bpy.context.collection.objects.link(ob)
    m = ob.modifiers.new("tomesh", 'VOLUME_TO_MESH')
    m.object = vol
    m.grid_name = "density"
    m.threshold = 0.1
    c = counts(ob)
    return c[0] > 0, "%s -> mesh %s" % (names, c)


def gltf():
    empty_scene()
    bpy.ops.mesh.primitive_monkey_add()
    ob = bpy.context.active_object
    sub = ob.modifiers.new("sub", 'SUBSURF')
    sub.levels = 2
    plain = os.path.join(out, "monkey.glb")
    draco = os.path.join(out, "monkey-draco.glb")
    bpy.ops.export_scene.gltf(filepath=plain, export_draco_mesh_compression_enable=False)
    bpy.ops.export_scene.gltf(filepath=draco, export_draco_mesh_compression_enable=True,
                              export_draco_mesh_compression_level=6)
    sp, sd = os.path.getsize(plain), os.path.getsize(draco)
    with open(draco, "rb") as f:
        ext = b"KHR_draco_mesh_compression" in f.read(4096)
    empty_scene()
    bpy.ops.import_scene.gltf(filepath=draco)
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    v = len(meshes[0].data.vertices) if meshes else 0
    return ext and sd < sp and v > 0, "plain %d bytes, draco %d bytes (ext %s), re-imported %d vertices" % (
        sp, sd, ext, v)


def i18n():
    from bpy.app import translations
    view = bpy.context.preferences.view
    view.language = 'de_DE'
    view.use_translate_interface = True
    view.use_translate_tooltips = True
    s = translations.pgettext_iface("Delete")
    t = translations.pgettext_iface("Add")
    loc = translations.locale
    mo = glob.glob(os.path.join(bpy.utils.resource_path('LOCAL'), "datafiles", "locale", "*", "LC_MESSAGES",
                                "blender.mo"))
    if not mo:
        mo = glob.glob(os.path.join(bpy.utils.system_resource('DATAFILES'), "locale", "*", "LC_MESSAGES",
                                    "blender.mo"))
    view.language = 'en_US'
    return s != "Delete" and len(mo) > 10, "locale %s: Delete -> %r, Add -> %r; %d languages" % (
        loc, s, t, len(mo))


def view3d():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                region = next(r for r in area.regions if r.type == 'WINDOW')
                return win, area, region
    return None, None, None


def pdf():
    win, area, region = view3d()
    if area is None:
        return False, "no 3D view (run with a window)"
    empty_scene()
    win, area, region = view3d()
    bpy.ops.object.gpencil_add(type='MONKEY')
    ob = bpy.context.active_object
    path = os.path.join(out, "monkey.pdf")
    with bpy.context.temp_override(window=win, area=area, region=region, object=ob, active_object=ob):
        result = bpy.ops.wm.gpencil_export_pdf(filepath=path, selected_object_type='VISIBLE', frame_mode='ACTIVE')
    size = os.path.getsize(path) if os.path.exists(path) else 0
    head = open(path, "rb").read(5) if size else b""
    return head == b"%PDF-" and size > 1000, "%s %d bytes, %r" % (sorted(result), size, head)


def trace():
    empty_scene()
    w = h = 128
    img = bpy.data.images.new("disc", w, h)
    px = []
    for y in range(h):
        for x in range(w):
            inside = (x - 64) ** 2 + (y - 64) ** 2 < 40 ** 2
            v = 0.0 if inside else 1.0
            px += [v, v, v, 1.0]
    img.pixels = px
    path = os.path.join(out, "disc.png")
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    image = bpy.data.images.load(path)
    bpy.ops.object.empty_add(type='IMAGE')
    empty = bpy.context.active_object
    empty.data = image
    activate(empty)
    result = bpy.ops.gpencil.trace_image(target='NEW', thickness=10, resolution=5, scale=1.0, sample=0.0,
                                         threshold=0.5, turnpolicy='MINORITY', mode='SINGLE')
    gps = [o for o in bpy.data.objects if o.type == 'GPENCIL']
    points = 0
    for o in gps:
        for layer in o.data.layers:
            for frame in layer.frames:
                for stroke in frame.strokes:
                    points += len(stroke.points)
    return points > 8, "%s, %d GP objects, %d points" % (sorted(result), len(gps), points)


check("options", options)
check("voxel", voxel)
check("quadriflow", quadriflow)
check("boolean", boolean)
check("vdbwrite", vdbwrite)
check("vdbrender", vdbrender)
check("vdbmesh", vdbmesh)
check("gltf", gltf)
check("i18n", i18n)
check("pdf", pdf)
check("trace", trace)
say("done")
if not bpy.app.background:  # a window run (pdf): quit without the UI's exit handling
    os._exit(0)
