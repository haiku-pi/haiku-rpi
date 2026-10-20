#!/bin/sh
# python.sh — a UserBootscript for CPython 3.14 (scripts/build-python.sh) that runs a set of checks
# with python3.14 from, in this order:
#   - the python3.14 package in the image (/boot/system/bin);
#   - the packages of artifacts/python-tests/packages (scripts/mkimage-pi4.sh --add-tree: python3.14
#     and the libffi it needs, in non-packaged/data/python-packages), installed by copying them into
#     /boot/system/packages (the package daemon activates them);
#   - the test tree artifacts/python-tests/non-packaged (--add-tree: python3.14, libpython, libffi
#     and the standard library, in /boot/system/non-packaged).
#   start-up (cold: compiles the standard library's bytecode; warm), version, platform and paths,
#   arithmetic (big integers, decimal, float), threads, json, sqlite3 in memory, hashlib sha256 and
#   the ssl module's OpenSSL, zlib/bz2/lzma/zstd round trips, ctypes (getpid from libroot), a TCP echo
#   over the loopback interface, subprocess, and timed loops (seconds; CPU-bound, one core).
# Does not configure any network interface (loopback only).
# Serial console lines: "PY "; per check "PY <name> PASS ..." or "PY <name> FAIL ..."; "PY end".
sleep 20
out=/dev/dprintf
say() { echo "PY $*" > $out; }
cd /tmp || exit 1
packages=/boot/system/non-packaged/data/python-packages
if [ ! -x /boot/system/bin/python3.14 ] && ls $packages/*.hpkg > /dev/null 2>&1; then
	# copied beside the directory and moved in whole: the package daemon reads a package as soon as
	# its entry appears, and a half-copied file fails ("failed to init package")
	for p in $packages/*.hpkg; do
		cp "$p" /boot/system/cache/tmp/incoming.hpkg && mv /boot/system/cache/tmp/incoming.hpkg "/boot/system/packages/${p##*/}"
	done
	waited=0
	while [ ! -x /boot/system/bin/python3.14 ] && [ $waited -lt 60 ]; do
		sleep 2
		waited=$((waited + 2))
	done
	if [ -x /boot/system/bin/python3.14 ]; then
		say "packages PASS activated after ${waited} s: $(ls $packages | tr '\n' ' ')"
	else
		say "packages FAIL not activated after ${waited} s"
		grep -a -i 'package' /var/log/syslog | tail -n 10 | while IFS= read -r line; do say "  $line"; done
	fi
fi
py=/boot/system/bin/python3.14
[ -x "$py" ] || py=/boot/system/non-packaged/bin/python3.14
if [ ! -x "$py" ]; then
	say "python3.14 FAIL not installed"
	say end
	exit 0
fi
say "binary $py"
TIMEFORMAT=%R
for run in cold warm; do
	{ time "$py" -c pass > /tmp/py-start.txt 2>&1; } 2> /tmp/py-time.txt
	status=$?
	if [ $status -eq 0 ]; then
		say "startup-$run PASS $(cat /tmp/py-time.txt) s"
	else
		say "startup-$run FAIL exit $status"
		while IFS= read -r line; do say "  $line"; done < /tmp/py-start.txt
	fi
done

cat > /tmp/pytest.py <<'EOF'
import os, sys, time, traceback

out = open(os.environ.get('PY_OUT', '/dev/dprintf'), 'w', buffering=1)   # PY_OUT: elsewhere
failures = 0


def say(text):
    out.write('PY ' + text + '\n')


def check(name):
    def run(fn):
        global failures
        try:
            detail = fn()
            say(f'{name} PASS {detail if detail is not None else ""}'.rstrip())
        except BaseException as e:
            failures += 1
            say(f'{name} FAIL {type(e).__name__}: {e}')
            for line in traceback.format_exc().splitlines()[-6:]:
                say('  ' + line)
    return run


@check('version')
def _():
    import platform, sysconfig
    say('  ' + sys.version.replace('\n', ' '))
    say(f'  platform {sys.platform} {sysconfig.get_platform()} {platform.machine()}')
    say(f'  prefix {sys.prefix} exec_prefix {sys.exec_prefix}')
    say(f'  path {sys.path}')
    assert sys.version_info[:2] == (3, 14), sys.version_info
    return sys.version.split()[0]


@check('compute')
def _():
    import decimal, fractions, math
    big = math.factorial(200)
    assert len(str(big)) == 375
    assert 2 ** 521 % 1000003 == pow(2, 521, 1000003)
    decimal.getcontext().prec = 50
    d = decimal.Decimal(2).sqrt()
    assert str(d).startswith('1.4142135623730950488016887242096980785696718753769')
    assert fractions.Fraction(1, 3) + fractions.Fraction(1, 6) == fractions.Fraction(1, 2)
    assert abs(math.fsum([0.1] * 10) - 1.0) < 1e-15
    return f'sqrt(2)={str(d)[:22]}... 200! has {len(str(big))} digits'


@check('threads')
def _():
    import threading
    from concurrent.futures import ThreadPoolExecutor
    total = [0]
    lock = threading.Lock()

    def work(n):
        s = sum(range(n))
        with lock:
            total[0] += s
    threads = [threading.Thread(target=work, args=(100000,)) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert total[0] == 8 * sum(range(100000)), total[0]
    with ThreadPoolExecutor(4) as pool:
        squares = list(pool.map(lambda x: x * x, range(100)))
    assert squares[99] == 9801
    return f'8 threads + pool of 4, active now {threading.active_count()}'


@check('json')
def _():
    import json
    data = {'name': 'Haiku', 'board': 'Raspberry Pi 4', 'cores': 4, 'ok': True,
        'nested': [1, 2.5, None, {'x': 'ż'}]}
    text = json.dumps(data, ensure_ascii=False, sort_keys=True)
    assert json.loads(text) == data
    return text[:60]


@check('sqlite3')
def _():
    import sqlite3
    db = sqlite3.connect(':memory:')
    db.execute('create table t (id integer primary key, v text)')
    db.executemany('insert into t (v) values (?)', [(f'row{i}',) for i in range(1000)])
    count, = db.execute('select count(*) from t').fetchone()
    total, = db.execute('select sum(id) from t').fetchone()
    assert (count, total) == (1000, 500500), (count, total)
    db.close()
    return f'sqlite {sqlite3.sqlite_version}, 1000 rows'


@check('hashlib-ssl')
def _():
    import hashlib, ssl
    digest = hashlib.sha256(b'abc').hexdigest()
    assert digest == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', digest
    assert hashlib.md5(b'').hexdigest() == 'd41d8cd98f00b204e9800998ecf8427e'
    context = ssl.create_default_context()
    assert context.verify_mode == ssl.CERT_REQUIRED
    say(f'  verify paths {ssl.get_default_verify_paths()}')
    return f'sha256 ok, {ssl.OPENSSL_VERSION}'


@check('compression')
def _():
    import bz2, lzma, zlib
    from compression import zstd
    data = b'Haiku on the Raspberry Pi 4. ' * 2000
    sizes = []
    for name, mod in (('zlib', zlib), ('bz2', bz2), ('lzma', lzma), ('zstd', zstd)):
        packed = mod.compress(data)
        assert mod.decompress(packed) == data, name
        sizes.append(f'{name} {len(packed)}')
    return f'{len(data)} bytes -> ' + ', '.join(sizes)


@check('ctypes')
def _():
    import ctypes, ctypes.util
    libroot = ctypes.CDLL('libroot.so')
    pid = libroot.getpid()
    assert pid == os.getpid(), (pid, os.getpid())
    libc_strlen = libroot.strlen
    libc_strlen.restype = ctypes.c_size_t
    assert libc_strlen(b'haiku') == 5
    return f'getpid() = {pid}, find_library("root") = {ctypes.util.find_library("root")}'


@check('socket')
def _():
    import socket, threading
    server = socket.create_server(('127.0.0.1', 0))
    server.settimeout(10)
    port = server.getsockname()[1]

    def serve():
        conn, _ = server.accept()
        with conn:
            conn.settimeout(10)
            while chunk := conn.recv(4096):
                conn.sendall(chunk)
    thread = threading.Thread(target=serve)
    thread.start()
    payload = os.urandom(65536)
    with socket.create_connection(('127.0.0.1', port), timeout=10) as client:
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        received = b''
        while chunk := client.recv(65536):
            received += chunk
    thread.join(10)
    server.close()
    assert received == payload, (len(received), len(payload))
    return f'64 KiB echoed over 127.0.0.1:{port}'


@check('subprocess')
def _():
    import subprocess
    child = subprocess.run([sys.executable, '-c', 'import sys; print(6 * 7, sys.platform)'],
        capture_output=True, text=True, timeout=60)
    assert child.returncode == 0 and child.stdout.split()[0] == '42', child
    shell = subprocess.run('uname -m; echo $((40 + 2))', shell=True, capture_output=True,
        text=True, timeout=30)
    assert shell.stdout.split()[-1] == '42', shell
    return f'child python: {child.stdout.strip()}; sh: {" ".join(shell.stdout.split())}'


@check('benchmark')
def _():
    t = time.perf_counter()
    s = sum(range(10_000_000))
    t_sum = time.perf_counter() - t
    assert s == 49999995000000

    def loop(n):    # integer arithmetic, calls, a dict and a list (pystone-like)
        d = {}
        acc = 0
        items = []
        for i in range(n):
            acc = (acc + i * 7) % 1000003
            d[i & 1023] = acc
            if i % 3 == 0:
                items.append(acc)
        return acc, len(d), len(items)
    t = time.perf_counter()
    loop(1_000_000)
    t_loop = time.perf_counter() - t
    t = time.perf_counter()
    words = sorted(str(i * 7919 % 100003) for i in range(200_000))
    t_sort = time.perf_counter() - t
    assert len(words) == 200_000
    return f'sum(range(1e7)) {t_sum:.3f} s, loop(1e6) {t_loop:.3f} s, sort(2e5 str) {t_sort:.3f} s'


say(f'checks done: {failures} failed')
sys.exit(1 if failures else 0)
EOF
"$py" /tmp/pytest.py > /tmp/pytest.txt 2>&1
status=$?
say "pytest.py exit $status"
# what the program said outside the checks (an early crash, a traceback at import)
tail -n 20 /tmp/pytest.txt | while IFS= read -r line; do say "  $line"; done
say end
