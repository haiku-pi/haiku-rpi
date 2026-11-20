# blender-b9-gui.py — blender -9 (docs/design/blender.md §7.16): USD export and import as the GUI runs them.
# File > Export/Import opens a file browser (the operator's invoke), and its exec then runs as a window-manager
# job (as_background_job: export_startjob/import_startjob on a worker thread), unlike the headless runs of
# blender-b9.py. This script invokes both operators, confirms each file browser with file.execute, waits for the
# job and grades by "BB9G <name>: PASS/FAIL ..." lines.
#
#   blender --factory-startup -p 0 0 1280 720 --python blender-b9-gui.py -- OUTDIR
import os
import sys
import time

import bpy

out = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "/tmp/bb9g"
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "gui.usdc")
if os.path.exists(path):
    os.remove(path)
state = {"step": "export-invoke", "t": time.time()}


def say(*a):
    print("BB9G", *a, flush=True)


def window_area(kind):
    for w in bpy.context.window_manager.windows:
        for a in w.screen.areas:
            if a.type == kind:
                for r in a.regions:
                    if r.type == 'WINDOW':
                        return w, a, r
    return None


def tick():
    s = state["step"]
    elapsed = time.time() - state["t"]
    try:
        if s == "export-invoke":
            w, a, r = window_area('VIEW_3D')
            with bpy.context.temp_override(window=w, area=a, region=r):
                say("export invoke:", bpy.ops.wm.usd_export('INVOKE_DEFAULT', filepath=path))
            state.update(step="export-confirm", t=time.time())
        elif s == "export-confirm":
            fb = window_area('FILE_BROWSER')
            if fb is None:
                if elapsed > 20:
                    say("export: FAIL no file browser")
                    bpy.ops.wm.quit_blender()
                    return None
                return 0.5
            w, a, r = fb
            with bpy.context.temp_override(window=w, area=a, region=r):
                say("export confirm:", bpy.ops.file.execute())
            state.update(step="export-wait", t=time.time(), size=-1)
        elif s == "export-wait":
            size = os.path.getsize(path) if os.path.exists(path) else -1
            if size > 0 and size == state["size"]:
                say("export: PASS %s, %d bytes, written by the job in %.1f s" % (path, size, elapsed))
                bpy.ops.wm.read_homefile(use_empty=True)
                state.update(step="import-invoke", t=time.time())
                return 1.0
            state["size"] = size
            if elapsed > 60:
                say("export: FAIL no file after 60 s")
                bpy.ops.wm.quit_blender()
                return None
            return 1.0
        elif s == "import-invoke":
            w, a, r = window_area('VIEW_3D')
            with bpy.context.temp_override(window=w, area=a, region=r):
                r = bpy.ops.wm.usd_import('INVOKE_DEFAULT', filepath=path)
            say("import invoke:", r)
            # (with the file path given, the invoke starts the import job without a file browser)
            state.update(step="import-wait" if r == {'FINISHED'} else "import-confirm", t=time.time())
        elif s == "import-confirm":
            fb = window_area('FILE_BROWSER')
            if fb is None:
                if elapsed > 20:
                    say("import: FAIL no file browser")
                    bpy.ops.wm.quit_blender()
                    return None
                return 0.5
            w, a, r = fb
            with bpy.context.temp_override(window=w, area=a, region=r):
                say("import confirm:", bpy.ops.file.execute())
            state.update(step="import-wait", t=time.time())
        elif s == "import-wait":
            obs = bpy.context.scene.objects
            if len(obs) >= 3:
                time.sleep(1)
                types = sorted(o.type for o in obs)
                verts = sum(len(o.data.vertices) for o in obs if o.type == 'MESH')
                say("import: PASS %d objects %s, %d mesh vertices, in %.1f s" % (len(obs), types, verts, elapsed))
                say("done")
                bpy.ops.wm.quit_blender()
                return None
            if elapsed > 60:
                say("import: FAIL %d objects after 60 s" % len(obs))
                bpy.ops.wm.quit_blender()
                return None
            return 1.0
    except Exception as e:  # report, then quit
        say("%s: FAIL %s: %s" % (s, type(e).__name__, e))
        bpy.ops.wm.quit_blender()
        return None
    return 1.0


bpy.app.timers.register(tick, first_interval=8.0, persistent=True)
