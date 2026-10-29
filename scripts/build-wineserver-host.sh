#!/usr/bin/env bash
# build-wineserver-host.sh — the wineserver of the patched tree (patches/wine-<version>, as scripts/build-wine.sh
# applies them) for this x86-64 Linux host, with AddressSanitizer (or another -fsanitize), to run under the
# reference Wine (scripts/build-wine-ref.sh: same version, same protocol): a use-after-free or double free in the
# server is named there with the stacks of the allocation, the free and the bad access.
#
#   [HAIKU_SIGNALS=1] scripts/build-wineserver-host.sh [SANITIZE [EXTRA_CFLAGS...]]   (SANITIZE default: address;
#                                                                                       "none": no sanitizer)
#
# HAIKU_SIGNALS=1: the server cannot signal a client thread, as on Haiku (ntdll has no Unix thread ID there,
# unix_tid is -1, so send_thread_signal() always fails): a system APC (APC_ASYNC_IO) for a thread that is not in a
# wait cannot be queued, and the async completes at once in the server. Output then in server-<SANITIZE>-haiku and
# install-<SANITIZE>-haiku. TAG=x: a further "-x" on both names (to keep two builds, e.g. before and after a fix).
#
# Output: artifacts/wine-ref/server-<SANITIZE>/wineserver, and artifacts/wine-ref/install-<SANITIZE>: the reference
# install (hard links) with that wineserver in bin/ (ntdll starts the wineserver next to it; it finds its NLS files
# relative to itself): run Wine from there (tools/wine-ref/wineboot-loop.sh N DIR INSTALL). Only the server is
# rebuilt (~45 files, a few seconds); the reference build's config.h and generated headers are used, so the
# server's Linux code paths (epoll, not Haiku's kqueue) are built.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version=$(sed -n 's/^defaultVersion=//p' "$root/scripts/build-wine.sh")
src="$root/sources/wine/wine-haiku-$version"
ref="$root/artifacts/wine-ref/build"
san=${1:-address}
shift || true
[ -d "$src/server" ] && [ -f "$ref/compile_commands.json" ] || { echo "build-wineserver-host: needs $src and scripts/build-wine-ref.sh" >&2; exit 1; }
tag=$san
[ "${HAIKU_SIGNALS:-0}" = 1 ] && tag=$san-haiku
tag=$tag${TAG:+-$TAG}
out="$root/artifacts/wine-ref/server-$tag"
mkdir -p "$out"
srv="$src/server"
if [ "${HAIKU_SIGNALS:-0}" = 1 ]; then
	# a copy of the server's sources with ptrace.c's send_thread_signal() failing as on Haiku
	rm -rf "$out/src"; mkdir -p "$out/src"; cp -a "$src/server" "$out/src/server"; ln -s "$src/include" "$out/src/include"
	grep -q 'if (thread->unix_tid != -1)' "$out/src/server/ptrace.c" || { echo "build-wineserver-host: ptrace.c changed" >&2; exit 1; }
	sed -i 's/if (thread->unix_tid != -1)/if (0 \&\& thread->unix_tid != -1)  \/* as on Haiku: no Unix thread ID *\//' "$out/src/server/ptrace.c"
	srv="$out/src/server"
fi
flags=(-O1 -g -fno-omit-frame-pointer)
[ "$san" = none ] || flags+=(-fsanitize="$san")
flags+=("$@")

# each server file with the reference build's command, from the patched tree, with the sanitizer
python3 -I - "$ref/compile_commands.json" "$src" "$srv" "$out" "$root/artifacts/wine-ref/install" "${flags[@]}" > "$out/build.sh" <<'EOF'
import json, shlex, sys
db, src, srv, out, prefix, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6:]
for e in json.load(open(db)):
    f = e['file']
    if '/server/' not in f or not f.endswith('.c'): continue
    args = e.get('arguments') or shlex.split(e['command'])
    pristine = f[:f.index('/server/')]
    # (the database keeps unicode.c's make variables unexpanded)
    args = [a.replace(pristine + '/server', srv).replace(pristine, src).replace('${bindir}', prefix + '/bin').replace('${datadir}', prefix + '/share')
            for a in args]
    o = args.index('-o'); args[o + 1] = out + '/' + f.rsplit('/', 1)[1][:-2] + '.o'
    args = [a for a in args if a not in ('-O2',)] + extra
    print('cd ' + shlex.quote(e['directory']) + ' && ' + shlex.join(args) + ' &')
print('wait')
EOF
bash -e "$out/build.sh"
ld=(-fno-omit-frame-pointer)
[ "$san" = none ] || ld+=(-fsanitize="$san")
gcc -m64 "${ld[@]}" -o "$out/wineserver" "$out"/*.o
inst="$root/artifacts/wine-ref/install-$tag"
[ -d "$inst" ] || cp -al "$root/artifacts/wine-ref/install" "$inst"
rm -f "$inst/bin/wineserver"
cp "$out/wineserver" "$inst/bin/wineserver"
echo "$inst/bin/wineserver"
