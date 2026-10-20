#!/bin/sh
# llama2.sh — a UserBootscript for llama2.c (scripts/build-llama2.sh): the TinyStories models
# generate text on the CPU, with OpenMP across the 4 cores (llama2-run) and on one core
# (llama2-run-st). Serial console lines: "LLM " — each run's story (first lines) and its
# "achieved tok/s"; "LLM end". Image: scripts/mkimage-pi4.sh --add-tree artifacts/llama2/non-packaged.
sleep 20
out=/dev/dprintf
np=/boot/system/non-packaged
data=$np/data/llama2
say() { echo "LLM $*" > $out; }
run() {	# label binary args...
	label=$1; shift
	say "$label: $*"
	"$@" > /tmp/llm.out 2> /tmp/llm.err
	say "$label: exit $?"
	head -n 4 /tmp/llm.out | while read -r l; do say "$label text: $l"; done
	grep -a "tok/s" /tmp/llm.err | while read -r l; do say "$label $l"; done
}
say begin
run 260K-omp $np/bin/llama2-run $data/stories260K.bin -z $data/tok512.bin -n 256 -s 42 -i "Once upon a time"
run 15M-omp $np/bin/llama2-run $data/stories15M.bin -z $data/tokenizer.bin -n 256 -s 42 -i "Once upon a time"
run 15M-1core $np/bin/llama2-run-st $data/stories15M.bin -z $data/tokenizer.bin -n 256 -s 42 -i "Once upon a time"
run 260K-1core $np/bin/llama2-run-st $data/stories260K.bin -z $data/tok512.bin -n 256 -s 42 -i "Once upon a time"
say end
