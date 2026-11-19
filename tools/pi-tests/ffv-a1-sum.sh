#!/bin/bash
# ffv-a1-sum.sh LABEL... — one line per measure run of tools/pi-tests/ffv-a1-run.sh (artifacts/ffa1/LABEL.out):
# Renderer, SwComposite, their sum, the app_server window thread (ms per 10 s), all Firefox teams, idle (of 40 000),
# frames decoded and dropped, frames on the plane and composites that drew into the window (HVO counters)
cd "$(dirname "$0")/../../artifacts/ffa1"
printf "%-8s %7s %7s %7s %7s %7s %7s %6s %6s %6s %6s\n" run Render SwComp R+S apwin FFteam idle frames drop plane winfr
for l in "$@"; do
  f=$l.out
  r=$(awk '$10=="Firefox" && $12=="Renderer" {s+=$4} END {print s+0}' $f)
  s=$(awk '$10=="Firefox" && $12=="SwComposite" {s+=$4} END {print s+0}' $f)
  a=$(awk '$10=="app_server" && $12 ~ /^w:.*ffa/ {s+=$4} END {print s+0}' $f)
  t=$(awk '$3=="team" && $6=="Firefox" {print $4}' $f)
  i=$(awk '$3=="idle" {print $4}' $f)
  q0=$(grep "quality before" $f | grep -o "frames [0-9]* dropped [0-9]*"); q1=$(grep "quality after" $f | grep -o "frames [0-9]* dropped [0-9]*")
  fr=$(( $(echo $q1 | awk '{print $2}') - $(echo $q0 | awk '{print $2}') )); dr=$(( $(echo $q1 | awk '{print $4}') - $(echo $q0 | awk '{print $4}') ))
  p0=$(grep "overlay before" $f | grep -o "plane [0-9]*" | awk '{print $2}'); p1=$(grep "overlay after" $f | grep -o "plane [0-9]*" | awk '{print $2}')
  w0=$(grep "overlay before" $f | grep -o "window frames [0-9]*" | awk '{print $3}'); w1=$(grep "overlay after" $f | grep -o "window frames [0-9]*" | awk '{print $3}')
  pl=$(( ${p1:-0} - ${p0:-0} )); wf=$(( ${w1:-0} - ${w0:-0} ))
  printf "%-8s %7s %7s %7s %7s %7s %7s %6s %6s %6s %6s\n" $l $r $s $((r+s)) $a "$t" "$i" $fr $dr $pl $wf
done
