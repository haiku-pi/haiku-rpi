#!/usr/bin/env python3
"""mmal-abi-check.py — check that MMAL's VideoCore messages keep their 32-bit layout on a 64-bit host.

    tools/haiku-tests/mmal-abi-check.py ORIGINAL PATCHED SYSROOT

ORIGINAL and PATCHED: raspberrypi/userland source trees (unpatched; with patches/raspberrypi_userland),
SYSROOT: the arm64 Haiku sysroot (its headers serve both ABIs: Haiku's headers know 32-bit ARM too).

The VideoCore firmware parses the messages of interface/mmal/vc/mmal_vc_msgs.h with the layout they have on
a 32-bit ARM host (pointers 32 bits, int64_t 8-aligned: the EABI). The patch gives them that layout on every
host. This compiles the header with clang three times — ORIGINAL for 32-bit ARM (the reference), PATCHED for
32-bit ARM and PATCHED for arm64 — dumps every record layout (-fdump-record-layouts-complete) and compares,
for each message structure and the structures they embed, the size and every field's offset and name
(not its type: the patch changes pointers to uint32_t). Prints "mmal-abi-check: N structures, all equal"
or the differences (exit status 1).
"""
import os
import re
import subprocess
import sys
import tempfile

# the structures the messages are made of (typedef names; the anonymous structs are named by their
# typedef), and the public ones that travel inside them
CHECKED_PREFIXES = ('mmal_worker_',)
CHECKED_NAMES = {'MMAL_ES_SPECIFIC_FORMAT_T', 'MMAL_BUFFER_HEADER_TYPE_SPECIFIC_T', 'MMAL_VC_STATS_T',
	'MMAL_CORE_STATISTICS_T', 'MMAL_PARAMETER_HEADER_T', 'MMAL_VIDEO_FORMAT_T', 'MMAL_AUDIO_FORMAT_T',
	'MMAL_SUBPICTURE_FORMAT_T', 'MMAL_BUFFER_HEADER_VIDEO_SPECIFIC_T'}
# replaced by mmal_worker_* equivalents in the patch: the original's MMAL_PORT_T etc. inside a message are
# compared through the message's own layout
RENAMED = {'struct MMAL_DRIVER_BUFFER_T': 'mmal_worker_driver_buffer'}


def typedef_names(header):
	"""line number of each 'typedef struct ... {' -> its typedef name"""
	lines = open(header).read().split('\n')
	names = {}
	for i, line in enumerate(lines):
		if re.match(r'\s*typedef\s+(struct|union)\b', line):
			for j in range(i, len(lines)):
				m = re.match(r'\s*\}\s*(\w+)\s*;', lines[j])
				if m:
					names[i + 1] = m.group(1)
					break
	return names


def layouts(tree, target, sysroot, renamed={}):
	headers = os.path.join(sysroot, 'boot/system/develop/headers')
	resource = subprocess.run(['clang', '-print-resource-dir'], capture_output=True, text=True,
		check=True).stdout.strip()
	with tempfile.NamedTemporaryFile('w', suffix='.c', delete=False) as f:
		f.write('#include "interface/mmal/vc/mmal_vc_msgs.h"\n')
		probe = f.name
	try:
		cmd = ['clang', '--target=' + target, '-nostdinc', '-std=gnu11', '-fsyntax-only', '-w',
			'-Xclang', '-fdump-record-layouts-complete', '-D__VIDEOCORE4__', '-DUSE_VCHIQ_ARM',
			'-isystem', os.path.join(resource, 'include')]
		for d in ('', 'os', 'os/kernel', 'os/support', 'posix', 'bsd'):
			cmd += ['-isystem', os.path.join(headers, d)]
		for d in ('', 'interface/vcos', 'interface/vcos/pthreads', 'interface/vchiq_arm', 'interface/mmal'):
			cmd += ['-I', os.path.join(tree, d)]
		out = subprocess.run(cmd + [probe], capture_output=True, text=True)
	finally:
		os.unlink(probe)
	if out.returncode != 0:
		sys.exit(f'mmal-abi-check: {target} build of {tree} failed:\n{out.stdout[-2000:]}{out.stderr[-2000:]}')

	msgs = os.path.realpath(os.path.join(tree, 'interface/mmal/vc/mmal_vc_msgs.h'))
	names = {}
	for path in (msgs, os.path.realpath(os.path.join(tree, 'interface/mmal/mmal_format.h')),
			os.path.realpath(os.path.join(tree, 'interface/mmal/mmal_buffer.h')),
			os.path.realpath(os.path.join(tree, 'interface/mmal/vc/mmal_vc_api.h'))):
		for line, name in typedef_names(path).items():
			names[(path, line)] = name

	result = {}
	for block in out.stdout.split('*** Dumping AST Record Layout')[1:]:
		rows = [r for r in block.strip().split('\n') if '|' in r]
		title = rows[0].split('|', 1)[1].strip()
		m = re.match(r'(struct|union) \((?:unnamed|anonymous) at (.*):(\d+):\d+\)$', title)
		if m:
			key = (os.path.realpath(m.group(2)), int(m.group(3)))
			if key not in names:
				continue
			name = names[key]
		else:
			name = renamed.get(title, title)
			name = re.sub(r'^(struct|union) ', '', name)
		if not (name.startswith(CHECKED_PREFIXES) or name in CHECKED_NAMES):
			continue
		fields = []
		for r in rows[1:]:
			offset, rest = r.split('|', 1)
			if rest.strip().startswith('['):
				fields.append(rest.strip())		# [sizeof=N, align=M]
				continue
			depth = (len(rest) - len(rest.lstrip())) // 2
			fields.append(f'{offset.strip():>5} {"  " * depth}{rest.split()[-1]}')
		result[name] = fields
	return result


def main():
	if len(sys.argv) != 4:
		sys.exit(__doc__.split('\n\n')[1])
	original, patched, sysroot = sys.argv[1:]
	reference = layouts(original, 'arm-unknown-haiku', sysroot, RENAMED)
	problems = 0
	for target in ('arm-unknown-haiku', 'aarch64-unknown-haiku'):
		got = layouts(patched, target, sysroot)
		for name in sorted(set(reference) | set(got)):
			if name not in got:
				if name != 'mmal_worker_driver_buffer':	# (new in the patch)
					print(f'mmal-abi-check: {target}: {name} missing')
					problems += 1
				continue
			if name not in reference:
				if name.startswith(CHECKED_PREFIXES) and name not in ('mmal_worker_port',
						'mmal_worker_es_format', 'mmal_worker_buffer_header',
						'mmal_worker_event_format_changed', 'mmal_worker_driver_buffer'):
					print(f'mmal-abi-check: {target}: {name} is new')
					problems += 1
				continue
			# the fields the patch added structure to (an embedded MMAL_PORT_T now an mmal_worker_port)
			# have the same members: compare the whole expansion
			if got[name] != reference[name]:
				problems += 1
				print(f'mmal-abi-check: {target}: {name} differs:')
				for a, b in zip(reference[name] + [''] * len(got[name]), got[name] + [''] * len(reference[name])):
					if a != b and (a or b):
						print(f'    32-bit original: {a!r:50} {target} patched: {b!r}')
	checked = len(reference)
	if problems:
		print(f'mmal-abi-check: {problems} differences ({checked} structures)')
		sys.exit(1)
	print(f'mmal-abi-check: {checked} structures, all equal (32-bit original = 32-bit and arm64 patched)')


main()
