# blender-b7-view.py — blender -7 (docs/design/blender.md §7.14): Cycles' viewport denoising with
# OpenImageDenoise, for an HDMI frame of each state. Started by tools/pi-tests/blender-b7-view.sh:
#
#   blender --factory-startup -p 0 0 1024 600 SCENE.blend --python blender-b7-view.py
#
# The 3D view goes to the camera in Rendered shading (Cycles, CPU, 8 viewport samples), without
# denoising or (BB7_DENOISE=1) with OpenImageDenoise from the first sample; at "BB7V SNAP <name>"
# (view-noisy, view-denoised) it holds still until the host has taken the frame (scripts/pi-snap-on.sh
# ... ACK: the file ACK-<name>; at most HOLD seconds), then quits. A frame shows Cycles' own status line ("Sample 8/8", "Denoising" while it runs).
import os
import time

import bpy

HOLD = 40.0
ACK = os.environ.get("BB7_ACK", "/tmp/bb7v-ack")
WAIT = float(os.environ.get("BB7_WAIT", "45"))
# BB7_DENOISE=1: with viewport denoising from the start (switching it on in a running viewport render
# from this script did not restart the render with it)
DENOISE = os.environ.get("BB7_DENOISE") == "1"
# BB7_MODE: "cycles" (the default: Rendered shading with Cycles), "material" (Material Preview, EEVEE),
# "eevee-f12" (an EEVEE F12 render into the render window: the render job's GL context on its thread)
MODE = os.environ.get("BB7_MODE", "cycles")
NAME = {"cycles": "view-denoised" if DENOISE else "view-noisy", "material": "view-material",
        "eevee-f12": "view-eevee-f12"}[MODE]


def say(*args):
    print("BB7V", *args, flush=True)


def snapped(name):
    """Yields until the host acknowledged the frame of SNAP name (or HOLD seconds)."""
    say("SNAP", name)
    path = "%s-%s" % (ACK, name)
    end = time.perf_counter() + HOLD
    while not os.path.exists(path) and time.perf_counter() < end:
        yield 0.25
    say("snapped", name, "ack" if os.path.exists(path) else "no ack")


def view3d():
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                return window, area
    return None, None


def steps():
    yield 3.0
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.preview_samples = 8
    scene.cycles.use_preview_adaptive_sampling = False
    scene.cycles.use_preview_denoising = DENOISE
    try:
        scene.cycles.preview_denoiser = 'OPENIMAGEDENOISE'
    except TypeError:  # a build without OpenImageDenoise (blender -6 and earlier): only 'AUTO'
        say("no OpenImageDenoise in this build")
    scene.cycles.preview_denoising_start_sample = 1
    window, area = view3d()
    space = area.spaces.active
    space.region_3d.view_perspective = 'CAMERA'
    with bpy.context.temp_override(window=window, area=area, region=area.regions[-1]):
        bpy.ops.view3d.view_center_camera()
    if MODE == "cycles":
        space.shading.type = 'RENDERED'
        say("rendered", "denoising", "on" if DENOISE else "off", scene.cycles.preview_denoiser,
            scene.cycles.preview_denoising_input_passes, scene.cycles.preview_denoising_prefilter,
            area.width, area.height)
    elif MODE == "material":
        scene.render.engine = 'BLENDER_EEVEE'
        space.shading.type = 'MATERIAL'
        say("material preview", area.width, area.height)
    else:
        scene.render.engine = 'BLENDER_EEVEE'
        scene.render.resolution_percentage = 50
        # (the render window opens at the pointer; before any mouse event there is none: off screen)
        window.cursor_warp(400, 300)
        with bpy.context.temp_override(window=window, area=area):
            bpy.ops.render.render('INVOKE_DEFAULT')
        say("eevee F12 started")
    yield WAIT
    yield from snapped(NAME)
    say("quit")
    bpy.ops.wm.quit_blender()


gen = steps()


def tick():
    try:
        return next(gen)
    except StopIteration:
        return None


bpy.app.timers.register(tick, first_interval=5.0, persistent=True)
