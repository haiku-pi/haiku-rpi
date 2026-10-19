#!/usr/bin/env bash
# haikuports-fetch.sh RECIPE... — fetch a HaikuPorts recipe's (first) source on the host, for native
# builds on images without wget/git: into the port's download/ directory, checked against the recipe's
# CHECKSUM_SHA256, with the "<file>.uri" haikuporter expects next to it (without it, haikuporter takes
# the file for an incomplete download, deletes it and tries to fetch it again).
#
#   scripts/haikuports-fetch.sh sources/haikuports/app-text/hoedown/hoedown-3.0.7.recipe
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 RECIPE..." >&2; exit 2; }
for recipe in "$@"; do
	python3 - "$recipe" <<'PY'
import hashlib, os, re, sys, urllib.request
recipe = sys.argv[1]
text = open(recipe).read()
name = os.path.basename(recipe)[:-len('.recipe')]
port, version = name.rsplit('-', 1)
def field(key):
    m = re.search(r'^' + key + r'="([^"]*)"', text, re.M)
    return m.group(1) if m else None
uris = (field('SOURCE_URI') or '').split()
checksum = field('CHECKSUM_SHA256')
if not uris:
    sys.exit(f'{recipe}: no SOURCE_URI')
subst = lambda s: s.replace('${portVersion}', version).replace('$portVersion', version) \
    .replace('${portName}', port).replace('$portName', port)
download = os.path.join(os.path.dirname(recipe), 'download')
os.makedirs(download, exist_ok=True)
filename = field('SOURCE_FILENAME')
for uri in map(subst, uris):
    target = os.path.join(download, subst(filename) if filename else uri.split('#')[0].rsplit('/', 1)[1])
    try:
        data = urllib.request.urlopen(uri, timeout=60).read()
    except Exception as e:
        print(f'{recipe}: {uri}: {e}', file=sys.stderr)
        continue
    digest = hashlib.sha256(data).hexdigest()
    if checksum and digest != checksum:
        print(f'{recipe}: {uri}: checksum {digest} != {checksum}', file=sys.stderr)
        continue
    open(target, 'wb').write(data)
    open(target + '.uri', 'w').write(uri)
    print(f'haikuports-fetch: {target} ({len(data)} bytes, sha256 ok)')
    break
else:
    sys.exit(f'{recipe}: no source could be fetched')
PY
done
