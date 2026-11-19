#!/usr/bin/env bash
# gen-avsync-clip.sh [OUT] — an A/V sync test clip (host ffmpeg + libx264 + aac): 1280x720 at 30 fps, dark grey
# with a white flash of 2 frames at every whole second, and a 1 kHz beep of the same 66.7 ms at the same instants
# (sample-exact, aevalsrc). 60 s, H.264 High + AAC 128 kbit/s. Measured with tools/pi-tests/avsync-measure.sh.
set -euo pipefail
out=${1:-artifacts/media-tests/h264/avsync-720p30.mp4}
mkdir -p "$(dirname "$out")"
ffmpeg -hide_banner -loglevel error -y \
	-f lavfi -i "color=c=0x202020:s=1280x720:r=30,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t\,1)\,0.0667)'" \
	-f lavfi -i "aevalsrc='if(lt(mod(t\,1)\,0.0667)\,0.8*sin(2*PI*1000*t)\,0)':s=48000" \
	-t 60 -c:v libx264 -preset fast -profile:v high -pix_fmt yuv420p -g 30 -b:v 2M -c:a aac -b:a 128k \
	-movflags +faststart "$out"
echo "gen-avsync-clip: $out"
