# blender-input.py — an observer for input tests of Blender's UI (docs/design/blender.md §7, M4): every 0.5 s
# one line "BMI <seconds> mode=<active object's mode> windows=<n> draws=<viewport redraws so far>
# rot=<view rotation>", so that injected input (tools/haiku-tests/uiinject.cpp: Tab, middle-drag, numpad,
# F12) can be checked from the log, and the viewport frame rate while orbiting is the change of draws over time.
#
#   blender FILE.blend --python blender-input.py
import time

import bpy

start = time.perf_counter()
draws = [0]


def counted():
    draws[0] += 1


def install():
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                bpy.types.SpaceView3D.draw_handler_add(counted, (), 'WINDOW', 'POST_PIXEL')
                return area
    return None


area = [None]


def report():
    if area[0] is None:
        area[0] = install()
    obj = bpy.context.view_layer.objects.active
    rot = "-"
    for win in bpy.context.window_manager.windows:
        for a in win.screen.areas:
            if a.type == 'VIEW_3D':
                q = a.spaces.active.region_3d.view_rotation
                rot = "%.3f,%.3f,%.3f,%.3f" % tuple(q)
                break
    print("BMI %.1f mode=%s windows=%d draws=%d rot=%s" % (
        time.perf_counter() - start, obj.mode if obj else "-",
        len(bpy.context.window_manager.windows), draws[0], rot), flush=True)
    return 0.5


bpy.app.timers.register(report, first_interval=2.0, persistent=True)
