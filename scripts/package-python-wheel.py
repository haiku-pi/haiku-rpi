#!/usr/bin/env python3
"""package-python-wheel.py — package a Python wheel for Haiku arm64 as a HaikuPorts-style python
module package, <module>_python3.14 (as HaikuPorts' dev-python recipes name them).

    scripts/package-python-wheel.py WHEEL [--revision N] [--requires R]... [--provides P]...
        [--replace OLD NEW]...

Run it with a Python 3.14 that has the `installer` and `packaging` modules (scripts/build-numpy.sh's
venv). The wheel is a cross-built one (numpy) or a pure-Python one (py3-none-any: pytest, ...).
What the recipes' INSTALL() does with `python3.14 -m installer -p $prefix`, done on the host:

  - installed (`installer` API) under the packaged prefix: the modules in
    /boot/system/lib/python3.14/vendor-packages (the haiku_vendor scheme HaikuPorts builds with),
    the console scripts in bin/ with "#!/boot/system/bin/python3.14", renamed <name>-3.14 with a
    <name> symlink (python3.14 is the default python), C headers of the wheel's .data in
    develop/headers/python3.14/<dist>
  - bytecode for every module, compiled by this Python (the same 3.14 as the target) with the
    paths on Haiku and --invalidation-mode unchecked-hash: packagefs is read-only, a stale .pyc
    can never happen and Python never stats the source to check one
  - ELF objects stripped (--strip-unneeded); their NEEDED entries become requires as in
    package-port.py; a host path in any file fails the packaging

In artifacts/packages/: <module>_python3.14-<version>-<N>-<arch>.hpkg, arch "any" for a pure-Python
wheel (Root-Is-Purelib and no ELF objects), arm64 otherwise. Provides <module>_python3.14 and
<module>_python314 (the name other recipes require) and cmd:<script>_3.14 / cmd:<script>; requires
haiku, cmd:python3.14 and <dep>_python314 for every Requires-Dist that applies on Haiku (markers
evaluated, extras left out). Like package-port.py's, the package is also extracted into the sysroot.
"""

import argparse
import email.parser
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import zipfile

import installer
from installer.destinations import SchemeDictionaryDestination
from installer.sources import WheelFile
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
spec = importlib.util.spec_from_file_location('package_port',
    os.path.join(root, 'scripts/package-port.py'))
pp = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True  # no scripts/__pycache__
spec.loader.exec_module(pp)

pythonVersion = '3.14'
prefix = '/boot/system'
vendor = f'{prefix}/lib/python{pythonVersion}/vendor-packages'
# what Requires-Dist markers see on Haiku arm64 (python3.14's sys.platform, platform.system())
markerEnvironment = {'python_version': pythonVersion, 'python_full_version': '3.14.8',
    'sys_platform': 'haiku1', 'platform_system': 'Haiku', 'os_name': 'posix',
    'platform_machine': 'arm64', 'implementation_name': 'cpython',
    'platform_python_implementation': 'CPython', 'extra': ''}
# SPDX identifiers (License-Expression) to the names of Haiku's data/licenses
licenseNames = {'MIT': 'MIT', 'BSD-2-Clause': 'BSD (2-clause)', 'BSD-3-Clause': 'BSD (3-clause)',
    'Apache-2.0': 'Apache v2', 'MPL-2.0': 'MPL v2.0', 'PSF-2.0': 'Python', 'ISC': 'ISC',
    'Zlib': 'Zlib'}


def licenses_of(meta):
    expression = meta.get('License-Expression')
    if expression:
        ids = re.findall(r'[A-Za-z0-9.+-]+', expression)
        ids = [i for i in ids if i not in ('AND', 'OR', 'WITH')]
        return [licenseNames.get(i, i) for i in ids]
    for classifier in meta.get_all('Classifier') or []:
        m = re.match(r'License :: OSI Approved :: (.*)', classifier)
        if m:
            text = m.group(1)
            for key, name in (('MIT', 'MIT'), ('Apache', 'Apache v2'), ('Mozilla Public License 2', 'MPL v2.0'),
                    ('BSD', 'BSD (3-clause)')):
                if key in text:
                    return [name]
    return [meta.get('License') or 'Unknown']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('wheel')
    parser.add_argument('--revision', default='1')
    parser.add_argument('--requires', action='append', default=[],
        help='a further requirement, one the wheel\'s metadata cannot show')
    parser.add_argument('--provides', action='append', default=[],
        help='a further resolvable of the package, at its version')
    parser.add_argument('--replace', nargs=2, action='append', default=[], metavar=('OLD', 'NEW'),
        help='replace OLD by NEW in the installed text files (a build-time path on the host by '
            'its name on Haiku: numpy/__config__.py names the cross compiler)')
    args = parser.parse_args()

    with zipfile.ZipFile(args.wheel) as z:
        metaName = next(n for n in z.namelist() if re.match(r'[^/]+\.dist-info/METADATA$', n))
        meta = email.parser.Parser().parsestr(z.read(metaName).decode())
        wheelInfo = z.read(metaName.replace('/METADATA', '/WHEEL')).decode()
    dist = canonicalize_name(meta['Name']).replace('-', '_')
    version = meta['Version']
    name = f'{dist}_python{pythonVersion}'
    work = os.path.join(root, 'artifacts/cross-ports', f'{dist}-{version}')
    stage = os.path.join(work, 'install')
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)

    scheme = {'purelib': vendor, 'platlib': vendor, 'scripts': f'{prefix}/bin', 'data': prefix,
        'headers': f'{prefix}/develop/headers/python{pythonVersion}/{dist}'}
    destination = SchemeDictionaryDestination(scheme, interpreter=f'{prefix}/bin/python{pythonVersion}',
        script_kind='posix', destdir=stage)
    with WheelFile.open(args.wheel) as source:
        installer.install(source, destination, {'INSTALLER': b'haiku-pi\n'})
    sys_ = stage + prefix

    # console scripts: <name>-3.14 and a <name> symlink (the recipes' INSTALL())
    commands = []
    binDir = os.path.join(sys_, 'bin')
    if os.path.isdir(binDir):
        for f in sorted(os.listdir(binDir)):
            os.rename(os.path.join(binDir, f), os.path.join(binDir, f'{f}-{pythonVersion}'))
            os.symlink(f'{f}-{pythonVersion}', os.path.join(binDir, f))
            commands += [f'{f}_{pythonVersion}', f]

    # ELF objects: stripped, NEEDED -> requires
    needed = []
    elf = False
    for dirpath, _, files in os.walk(sys_):
        for f in files:
            path = os.path.join(dirpath, f)
            if os.path.islink(path) or open(path, 'rb').read(4) != b'\x7fELF':
                continue
            elf = True
            needed += pp.elf_dynamic(path)[1]
            subprocess.run([pp.tools + 'strip', '--strip-unneeded', path], check=True)

    # host paths in text files, by their names on Haiku (the wheel's RECORD keeps the old hashes;
    # only pip's uninstall reads it, and a packaged module is not uninstalled with pip)
    if args.replace:
        for dirpath, _, files in os.walk(sys_):
            for f in files:
                path = os.path.join(dirpath, f)
                data = b'' if os.path.islink(path) else open(path, 'rb').read()
                if b'\0' in data:
                    continue
                new = data
                for old, replacement in args.replace:
                    new = new.replace(old.encode(), replacement.encode())
                if new != data:
                    open(path, 'wb').write(new)

    # bytecode, with the paths on Haiku
    site = sys_ + f'/lib/python{pythonVersion}/vendor-packages'
    result = subprocess.run([sys.executable, '-m', 'compileall', '-q', '-o', '0',
        '--invalidation-mode', 'unchecked-hash', '-s', stage, '-p', '/', site],
        capture_output=True, text=True)
    if result.returncode != 0:
        # (modules that are not meant to compile: test data of a package; reported, not fatal)
        print(f'package-python-wheel: compileall: {result.stdout.strip()}', file=sys.stderr)

    # no host paths in anything that goes on the Pi
    leaks = []
    for dirpath, _, files in os.walk(stage):
        for f in files:
            path = os.path.join(dirpath, f)
            if not os.path.islink(path) and root.encode() in open(path, 'rb').read():
                leaks.append(path)
    if leaks:
        sys.exit('package-python-wheel: host paths in: ' + ' '.join(leaks))

    requires = {'haiku', f'cmd:python{pythonVersion}'} | set(args.requires)
    for r in meta.get_all('Requires-Dist') or []:
        req = Requirement(r)
        if req.marker is None or req.marker.evaluate(markerEnvironment):
            requires.add(canonicalize_name(req.name).replace('-', '_') + '_python'
                + pythonVersion.replace('.', ''))
    for n in needed:
        if os.path.exists(os.path.join(pp.sysroot + pp.nonPackaged, 'lib', n)) \
                or pp.lib_base(n) in ('libstdc++', 'libgcc_s', 'libatomic'):
            requires.add(f'lib:{pp.resolvable(pp.lib_base(n))}')
        # else: libroot and the other system libraries, in "haiku"; libpython's symbols come
        # from the running python3.14 (extension modules do not link it, as on Linux)
    provides = [f'{name} = {version}-{args.revision}',
        f'{dist}_python{pythonVersion.replace(".", "")} = {version}'] \
        + [f'cmd:{pp.resolvable(c)} = {version}' for c in commands] \
        + [f'{p} = {version}' for p in args.provides]

    pure = 'Root-Is-Purelib: true' in wheelInfo and not elf
    architecture = 'any' if pure else 'arm64'
    author = meta.get('Author') or re.sub(r'\s*<.*?>', '', meta.get('Author-email') or '') \
        or f'The {meta["Name"]} authors'
    info = pp.package_info(name, version, args.revision, (meta.get('Summary') or name).rstrip('.'),
        licenses_of(meta), [author], provides, sorted(requires), architecture=architecture)
    info = info.replace(' from the HaikuPorts recipe', f' from the {meta["Name"]} {version} wheel')
    runtime = os.path.join(work, 'package')
    shutil.rmtree(runtime, ignore_errors=True)
    shutil.copytree(sys_, runtime, symlinks=True)
    # a license Haiku has no text of (numpy: CC0-1.0, 0BSD) comes with the package, as haikuporter
    # does it: here a pointer to the wheel's license files, which are in the package
    # (Haiku's own license texts, as the package tool checks them: the sysroot's data/licenses also
    # has those other packages brought along)
    systemLicenses = os.listdir(os.path.join(root, 'sources/haiku/data/system/data/licenses'))
    distInfo = os.path.basename(metaName.split('/')[0])
    for license in licenses_of(meta):
        if license not in systemLicenses:
            os.makedirs(os.path.join(runtime, 'data/licenses'), exist_ok=True)
            with open(os.path.join(runtime, 'data/licenses', license), 'w') as f:
                f.write(f'{meta["Name"]} {version} is licensed under '
                    f'{meta.get("License-Expression") or license}.\nThe license texts are in '
                    f'{vendor}/{distInfo}/ (licenses/, LICENSE*).\n')
    out = os.path.join(root, 'artifacts/packages', f'{name}-{version}-{args.revision}-{architecture}.hpkg')
    pp.create(runtime, info, out)


if __name__ == '__main__':
    main()
