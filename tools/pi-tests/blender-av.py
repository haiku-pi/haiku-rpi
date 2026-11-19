# blender-av.py — Blender's video and audio on the Pi (docs/design/blender.md §7, blender -5): lines "BAV <what>
# PASS|FAIL ...". Two modes, the word after "--":
#
#   blender -b --factory-startup --python blender-av.py -- render OUTDIR
#       the default cube turning over 24 frames, Workbench, 640x360, rendered to OUTDIR/cube.mp4 (FFmpeg: MPEG-4
#       Part 2 video in MP4 — libavcodec's mpeg4; our FFmpeg has no software H.264 encoder) + a 1 s 440 Hz WAV
#       (OUTDIR/tone.wav); then a new scene whose Video Sequencer holds that MP4 and the WAV: the strips' lengths,
#       and the sequencer's frame 12 rendered to OUTDIR/vse_0012.png
#   blender -b --factory-startup --python blender-av.py -- h264 OUTDIR [CRF]
#       48 frames of the turning cube at 1280x720, Workbench, to OUTDIR/h264_0001-0048.mp4: H.264 video (the
#       VideoCore encoder h264_mmal, the only H.264 encoder of our FFmpeg) and AAC audio (FFmpeg's native
#       encoder) from a 2 s WAV in the scene's sequencer; CRF: Blender's constant-rate-factor setting (default
#       MEDIUM; NONE: the bitrate setting)
#   blender OUTDIR/vse.blend --python blender-av.py -- play OUTDIR
#       (windowed) the audio device (Preferences > System > Sound: SDL); the sequencer scene played with
#       AUDIO_SYNC (the frame follows the audio device's clock: it advances only while SDL audio runs), then
#       without sync (frame_current must advance)
import math
import os
import struct
import sys
import time
import wave

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
mode, out = args[0], args[1]


def say(*a):
    print("BAV", *a, flush=True)


def render():
    scene = bpy.context.scene
    cube = bpy.data.objects["Cube"]
    cube.rotation_euler = (0, 0, 0)
    cube.keyframe_insert("rotation_euler", frame=1)
    cube.rotation_euler = (0, 0, math.pi / 2)
    cube.keyframe_insert("rotation_euler", frame=24)
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.frame_start, scene.frame_end = 1, 24
    scene.render.fps = 24
    scene.render.resolution_x, scene.render.resolution_y = 640, 360
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'FFMPEG'
    scene.render.ffmpeg.format = 'MPEG4'
    scene.render.ffmpeg.codec = 'MPEG4'
    scene.render.ffmpeg.constant_rate_factor = 'NONE'
    scene.render.ffmpeg.video_bitrate = 2000
    scene.render.filepath = os.path.join(out, "cube")
    start = time.perf_counter()
    bpy.ops.render.render(animation=True)
    mp4 = scene.render.frame_path(frame=1)
    ok = os.path.exists(mp4) and os.path.getsize(mp4) > 10000
    say("video", "PASS" if ok else "FAIL", mp4, os.path.getsize(mp4) if os.path.exists(mp4) else 0,
        "bytes, %.1f s" % (time.perf_counter() - start))

    tone = os.path.join(out, "tone.wav")
    with wave.open(tone, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 48000)))
                               for i in range(48000)))

    vse = bpy.data.scenes.new("VSE")
    vse.render.resolution_x, vse.render.resolution_y = 640, 360
    vse.render.resolution_percentage = 100
    vse.render.fps = 24
    vse.frame_start, vse.frame_end = 1, 24
    ed = vse.sequence_editor_create()
    movie = ed.sequences.new_movie("cube", mp4, channel=1, frame_start=1)
    sound = ed.sequences.new_sound("tone", tone, channel=2, frame_start=1)
    element = movie.elements[0] if len(movie.elements) else None
    say("vse-movie", "PASS" if movie.frame_final_duration == 24 else "FAIL",
        "duration", movie.frame_final_duration,
        "size %dx%d" % ((element.orig_width, element.orig_height) if element else (0, 0)))
    say("vse-sound", "PASS" if sound.frame_final_duration == 24 else "FAIL",
        "duration", sound.frame_final_duration, "samplerate", sound.sound.samplerate)
    vse.render.image_settings.file_format = 'PNG'
    vse.render.filepath = os.path.join(out, "vse_####")
    vse.frame_set(12)
    bpy.ops.render.render(write_still=True, scene=vse.name)
    png = os.path.join(out, "vse_0012.png")
    say("vse-frame", "PASS" if os.path.exists(png) else "FAIL", png)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out, "vse.blend"))


def play():
    def steps():
        yield 3.0
        say("audio-device", bpy.context.preferences.system.audio_device)
        # (no `aud` Python module: Blender builds it only with NumPy) — the audio clock is checked through
        # playback synced to it: with AUDIO_SYNC the frame follows the audio device's position, so it
        # advances only while the device (SDL) plays
        win = bpy.context.window_manager.windows[0]
        vse = bpy.data.scenes["VSE"]
        win.scene = vse
        vse.sync_mode = 'AUDIO_SYNC'
        vse.frame_set(1)
        yield 1.0
        with bpy.context.temp_override(window=win):
            bpy.ops.screen.animation_play()
        f0, t0 = vse.frame_current, time.perf_counter()
        yield 1.5
        f1, t1 = vse.frame_current, time.perf_counter()
        say("audio-clock", "PASS" if f1 > f0 else "FAIL", "AUDIO_SYNC playback: frame %d -> %d in %.1f s (24 fps)"
            % (f0, f1, t1 - t0))
        vse.sync_mode = 'NONE'
        f0 = vse.frame_current
        yield 2.0
        f1 = vse.frame_current
        say("vse-play", "PASS" if f1 != f0 else "FAIL", "frame %d -> %d in 2 s" % (f0, f1))
        say("SNAP", "vse-play")
        yield 4.0
        with bpy.context.temp_override(window=win):
            bpy.ops.screen.animation_cancel()
        say("end")
        bpy.ops.wm.quit_blender()

    gen = steps()

    def tick():
        try:
            return next(gen)
        except StopIteration:
            return None
        except Exception as e:
            say("ERROR", repr(e))
            bpy.ops.wm.quit_blender()
            return None

    bpy.app.timers.register(tick, first_interval=5.0)


def h264():
    scene = bpy.context.scene
    cube = bpy.data.objects["Cube"]
    cube.rotation_euler = (0, 0, 0)
    cube.keyframe_insert("rotation_euler", frame=1)
    cube.rotation_euler = (0, 0, math.pi * 2 / 3)
    cube.keyframe_insert("rotation_euler", frame=48)
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.frame_start, scene.frame_end = 1, 48
    scene.render.fps = 24
    scene.render.resolution_x, scene.render.resolution_y = 1280, 720
    scene.render.resolution_percentage = 100
    tone = os.path.join(out, "tone2.wav")
    with wave.open(tone, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(b"".join(struct.pack("<hh", s, s) for s in
                               (int(12000 * math.sin(2 * math.pi * 440 * i / 48000)) for i in range(96000))))
    ed = scene.sequence_editor_create()
    ed.sequences.new_sound("tone", tone, channel=1, frame_start=1)
    ff = scene.render.ffmpeg
    scene.render.image_settings.file_format = 'FFMPEG'
    ff.format = 'MPEG4'
    ff.codec = 'H264'
    ff.constant_rate_factor = args[2] if len(args) > 2 else 'MEDIUM'
    ff.video_bitrate = 6000
    ff.audio_codec = 'AAC'
    ff.audio_bitrate = 192
    ff.audio_channels = 'STEREO'
    ff.audio_mixrate = 48000
    scene.render.filepath = os.path.join(out, "h264_")
    start = time.perf_counter()
    bpy.ops.render.render(animation=True)
    mp4 = scene.render.frame_path(frame=1)
    ok = os.path.exists(mp4) and os.path.getsize(mp4) > 10000
    say("h264", "PASS" if ok else "FAIL", mp4, os.path.getsize(mp4) if os.path.exists(mp4) else 0,
        "bytes, %.1f s, crf %s" % (time.perf_counter() - start, ff.constant_rate_factor))


if mode == "h264":
    try:
        h264()
    except Exception as e:
        import traceback
        traceback.print_exc()
        say("ERROR", repr(e))
elif mode == "render":
    try:
        render()
    except Exception as e:
        import traceback
        traceback.print_exc()
        say("ERROR", repr(e))
else:
    play()
