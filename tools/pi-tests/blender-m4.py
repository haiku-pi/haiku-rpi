# blender-m4.py — Blender milestone M4 (docs/design/blender.md §7): the UI through GHOST_SDL, driven from inside
# Blender so every step is the same each run. Started by tools/pi-tests/blender-m4.sh:
#
#   blender --factory-startup -p 0 0 1600 900 --python blender-m4.py -- OUTDIR
#
# Each step prints "BM4 <step> ..." (flushed); at "BM4 SNAP <name>" it holds still until the host has taken an
# HDMI frame and acknowledged it (scripts/pi-snap-on.sh ... ACK: the file ACK-<name>; at most HOLD seconds). Frame rates come from wm.redraw_timer
# (DRAW_WIN_SWAP: the whole window drawn and swapped, N times, timed here).
import os
import sys
import time

import bpy
import gpu

HOLD = 40.0
ACK = os.environ.get("BM4_ACK", "/tmp/bm4-ack")


def snapped(name):
    """Yields until the host acknowledged the frame of SNAP name (or HOLD seconds)."""
    path = "%s-%s" % (ACK, name)
    end = time.perf_counter() + HOLD
    while not os.path.exists(path) and time.perf_counter() < end:
        yield 0.25
    say("snapped", name, "ack" if os.path.exists(path) else "no ack")
out = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/boot/home/bm4"
os.makedirs(out, exist_ok=True)
blend = os.path.join(out, "m4.blend")


def say(*args):
    if args and args[0] == "SNAP" and PRESENT:
        present()
    print("BM4", *args, flush=True)


# BM4_PRESENT=1 in the environment: every window drawn and swapped once right before each SNAP line —
# whether a frame on screen lags behind what Blender has drawn
PRESENT = os.environ.get("BM4_PRESENT") == "1"


def present():
    for w in bpy.context.window_manager.windows:
        with bpy.context.temp_override(window=w):
            bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=1)


def view3d():
    """(window, area, region) of the first 3D viewport."""
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                for region in area.regions:
                    if region.type == 'WINDOW':
                        return win, area, region
    return None, None, None


def fps(label, iterations=60):
    """Frames per second of the whole window, drawn and swapped (redraw_timer DRAW_WIN_SWAP); the
    region-only DRAW type does not redraw an untagged region (it measured ~0.001 ms)."""
    win, area, region = view3d()
    if win is None:
        say("fps", label, "FAIL no 3D viewport")
        return
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=3)  # shaders compiled, caches warm
        start = time.perf_counter()
        bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=iterations)
        elapsed = time.perf_counter() - start
    say("fps", label, "%.1f" % (iterations / elapsed), "(%d frames, %.2f s, window %dx%d, viewport %dx%d)"
        % (iterations, elapsed, win.width, win.height, region.width, region.height))


def warp_cursor():
    """Operators that open a window place it at the mouse position of the event; called from a timer
    before any mouse event, that position is garbage (the preferences window opened at -17482, 18044).
    Put the cursor in the middle of the main window first."""
    win = bpy.context.window_manager.windows[0]
    win.cursor_warp(win.width // 2, win.height // 2)


def triangles(obj):
    obj.data.calc_loop_triangles()
    return len(obj.data.loop_triangles)


def with_view3d(op, *args, **kwargs):
    win, area, region = view3d()
    with bpy.context.temp_override(window=win, area=area, region=region):
        return op(*args, **kwargs)


render_start = [0.0]
render_done_flag = []


def render_done(scene, *rest):
    say("render", "done %.1f s" % (time.perf_counter() - render_start[0]))
    render_done_flag.append(True)


def steps():
    # 1. the window and its GL context
    import bgl
    say("gl", "version:", bgl.glGetString(bgl.GL_VERSION))
    say("gl", "renderer:", gpu.platform.renderer_get(), "vendor:", gpu.platform.vendor_get(),
        "glsl:", bgl.glGetString(bgl.GL_SHADING_LANGUAGE_VERSION))
    say("gl", "device:", gpu.platform.device_type_get())
    win = bpy.context.window_manager.windows[0]
    say("window", "%dx%d" % (win.width, win.height))
    say("SNAP", "1-start")
    yield from snapped("1-start")

    # 2. the default scene in the solid (Workbench) viewport; orbit and zoom
    fps("default-scene")
    for i in range(6):
        with_view3d(bpy.ops.view3d.view_orbit, angle=0.25, type='ORBITRIGHT')
    with_view3d(bpy.ops.view3d.zoom, delta=2)
    with_view3d(bpy.ops.wm.redraw_timer, type='DRAW_WIN_SWAP', iterations=1)
    say("view", "orbited 6 x 0.25 rad right, zoomed in")
    say("SNAP", "2-viewport")
    yield from snapped("2-viewport")

    # 3. edit mode on the cube
    cube = bpy.data.objects.get("Cube")
    bpy.context.view_layer.objects.active = cube
    cube.select_set(True)
    with_view3d(bpy.ops.object.mode_set, mode='EDIT')
    with_view3d(bpy.ops.mesh.select_all, action='SELECT')
    with_view3d(bpy.ops.mesh.subdivide, number_cuts=2)
    say("edit", "mode", cube.mode, "subdivided")
    fps("edit-mode")
    say("SNAP", "3-edit")
    yield from snapped("3-edit")
    with_view3d(bpy.ops.object.mode_set, mode='OBJECT')
    say("edit", "back to", cube.mode, "vertices", len(cube.data.vertices))

    # 4. save, reload
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    say("save", blend, os.path.getsize(blend), "bytes")
    bpy.ops.wm.open_mainfile(filepath=blend)
    yield 2.0
    cube = bpy.data.objects.get("Cube")
    say("load", bpy.data.filepath, "cube vertices", len(cube.data.vertices) if cube else "missing")
    say("SNAP", "4-reloaded")
    yield from snapped("4-reloaded")

    # ~100k triangles: a UV sphere of 320 segments x 160 rings (Subdivision Surface needs OpenSubdiv, which
    # the minimal build does not have: "Disabled, built without OpenSubdiv")
    with_view3d(bpy.ops.mesh.primitive_uv_sphere_add, segments=320, ring_count=160, location=(3, 0, 0))
    tris = sum(triangles(o) for o in bpy.data.objects if o.type == 'MESH')
    say("mesh", "scene triangles", tris)
    with_view3d(bpy.ops.view3d.view_all)
    fps("100k-triangles")
    say("SNAP", "4b-100k")
    yield from snapped("4b-100k")

    # 5. the preferences, a second SDL window
    warp_cursor()
    with_view3d(bpy.ops.screen.userpref_show, 'INVOKE_DEFAULT')
    yield 2.0
    say("prefs", "windows", ", ".join("%s %d,%d %dx%d" % (w.screen.name, w.x, w.y, w.width, w.height)
                                     for w in bpy.context.window_manager.windows))
    say("SNAP", "5-preferences")
    yield from snapped("5-preferences")
    for w in list(bpy.context.window_manager.windows)[1:]:
        with bpy.context.temp_override(window=w):
            bpy.ops.wm.window_close()
    yield 1.0
    say("prefs", "closed, windows", len(bpy.context.window_manager.windows))

    # 6. F12: a Cycles render into the image editor (its own window), on the render job's thread
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 16
    scene.cycles.use_denoising = False
    scene.render.resolution_percentage = 50
    bpy.app.handlers.render_complete.append(render_done)
    render_start[0] = time.perf_counter()
    warp_cursor()
    win, area, region = view3d()
    with bpy.context.temp_override(window=win, area=area, region=region):
        bpy.ops.render.render('INVOKE_DEFAULT')
    say("render", "started (F12), windows", ", ".join("%s %d,%d %dx%d" % (w.screen.name, w.x, w.y, w.width, w.height)
                                                     for w in bpy.context.window_manager.windows))
    end = time.perf_counter() + 120
    while not render_done_flag and time.perf_counter() < end:
        yield 0.5
    yield 1.0
    say("SNAP", "6-render")
    yield from snapped("6-render")

    say("end")
    yield 1.0
    bpy.ops.wm.quit_blender()


gen = steps()


def tick():
    try:
        return next(gen)
    except StopIteration:
        return None
    except Exception as e:  # report and go on: one broken step must not hide the others
        import traceback
        traceback.print_exc()
        say("ERROR", repr(e))
        sys.stdout.flush()
        return 1.0


bpy.app.timers.register(tick, first_interval=5.0, persistent=True)
