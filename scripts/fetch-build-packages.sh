#!/usr/bin/env bash
# fetch-build-packages.sh — download the upstream arm64 build packages (gcc_syslibs, zlib, icu74, ...)
# into jam's download directory. jam fetches a package from <server>/<SHA-256 of the repository
# definition>/packages/, but our definition (sources/haiku build/jam/repositories/HaikuPorts/arm64)
# also lists our own packages, so its checksum names no directory on Haiku's server and a fresh
# build could not download anything. This uses upstream's version of the file instead: the newest
# commit touching it whose subject does not mention haiku-pi (all of ours do).
#
#   scripts/fetch-build-packages.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
haiku="$root/sources/haiku"
definition=build/jam/repositories/HaikuPorts/arm64
download="$haiku/generated.arm64/download"
mkdir -p "$download"

commit="$(git -C "$haiku" log -1 --format=%H --invert-grep --grep=haiku-pi -- "$definition")"
git -C "$haiku" show "$commit:$definition" > "$download/upstream-arm64-definition"
python3 - "$download/upstream-arm64-definition" "$download" <<'PY'
import hashlib, os, re, sys, urllib.request
path, download = sys.argv[1], sys.argv[2]
text = open(path, 'rb').read()
checksum = hashlib.sha256(text).hexdigest()
# RemotePackageRepository NAME : ARCH : URL : any packages : arch packages : source packages ...
lines = [re.sub(r'#.*', '', l).strip() for l in text.decode().split('\n')]
sections = [[]]
for token in ' '.join(lines).replace(';', ' ').split():
    if token == ':':
        sections.append([])
    else:
        sections[-1].append(token)
url = sections[2][0]
anyPackages, archPackages = sections[3], sections[4]
files = [p + '-any.hpkg' for p in anyPackages] + [p + '-arm64.hpkg' for p in archPackages]
for f in files:
    target = os.path.join(download, f)
    if os.path.exists(target):
        continue
    data = urllib.request.urlopen(f'{url}/{checksum}/packages/{f}', timeout=120).read()
    open(target + '.part', 'wb').write(data)
    os.rename(target + '.part', target)
    print(f'fetch-build-packages: {f} ({len(data)} bytes)')
print(f'fetch-build-packages: {len(files)} packages of {url}/{checksum[:12]}... in {download}')
PY
