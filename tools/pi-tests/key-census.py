#!/usr/bin/env python3
"""key-census.py IMAGE... — where an overlay's key colour shows on the screen instead of the video
(MediaPlayer's full-screen toggle, docs/design/video-overlay.md §10). Per IMAGE (an HDMI snapshot,
scripts/hdmi-snap.sh, or a screenshot) one line:

  NAME key N (bbox X0,Y0-X1,Y1) bars M (bbox X0,Y0-X1,Y1)

key: pixels of app_server's overlay key {0, 80, 0} as the capture chain shows it (it adds ~10 to every channel);
a screen whose overlay sits where its key is drawn has none (the plane covers the key).
bars: pixels of the saturated colour bars of the test clips (tools/media-tests col-*.mp4: yellow, cyan, green,
magenta, red, blue at 75 %): the bounding box is where the video picture is on the screen.
"""
import sys

from PIL import Image

BARS = [(191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191)]


def is_key(r, g, b):
	return r < 40 and b < 40 and 60 <= g <= 115


def is_bar(r, g, b):
	return any(abs(r - br) < 45 and abs(g - bg) < 45 and abs(b - bb) < 45 for br, bg, bb in BARS)


def census(path):
	im = Image.open(path).convert('RGB')
	w, h = im.size
	px = im.load()
	key = [0, w, h, -1, -1]
	bars = [0, w, h, -1, -1]
	for y in range(0, h):
		for x in range(0, w):
			r, g, b = px[x, y]
			for hit, box in ((is_key(r, g, b), key), (is_bar(r, g, b), bars)):
				if hit:
					box[0] += 1
					box[1] = min(box[1], x)
					box[2] = min(box[2], y)
					box[3] = max(box[3], x)
					box[4] = max(box[4], y)

	def fmt(box):
		return f'{box[0]}' + (f' (bbox {box[1]},{box[2]}-{box[3]},{box[4]})' if box[0] else '')
	return f'key {fmt(key)} bars {fmt(bars)}'


for p in sys.argv[1:]:
	print(p.rsplit('/', 1)[-1], census(p))
