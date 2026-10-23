#!/usr/bin/env python3
"""package-port.py — package a port built by scripts/cross-port.sh as HaikuPorts-style hpkgs.

    scripts/package-port.py RECIPE [--revision N] [--static-suffix SUFFIX] [--provides P]... [--requires R]...
        [--devel-requires R]... [--no-devel] [--architecture any]

From artifacts/cross-ports/<port>-<version>/install/boot/system/non-packaged (what cross-port.sh
installed) it makes, in artifacts/packages/:

  <port>-<version>-<N>-arm64.hpkg        the shared libraries (named by their soname, stripped) and
                                         the programs in bin/ (stripped; provides cmd:<name>)
  <port>_devel-<version>-<N>-arm64.hpkg  headers (develop/headers), static libraries, develop/lib
                                         symlinks (lib<name>.so and the soname, as HaikuPorts'
                                         prepareInstalledDevelLibs makes them), pkg-config files
                                         with the packaged paths

Provides come from the sonames, requires from the libraries' NEEDED entries (other ports in the
sysroot, libstdc++/libgcc_s/libatomic; the system's own libraries need nothing but "haiku"), the
license and summary from the recipe. --static-suffix renames lib<name>.a to lib<name><SUFFIX>.a
(fluidlite: "-static", as jam's fluidlite build feature expects). Both packages are also extracted into the
sysroot's boot/system, as the image will have them. Other run-time names of a library, symlinks to its
soname in lib/ (ncurses6: libncurses.so.6 -> libncursesw.so.6), are kept and provided too.

A port installed with the packaged prefix (--system-prefix: install/boot/system, e.g. CPython, whose
build bakes its prefix into sysconfig) may also have develop/headers/ (to the _devel package as they
are), lib/<DIR>/ trees that go into the runtime package as they are (--lib-tree DIR, e.g. python3.14:
the standard library and its lib-dynload modules, ELF objects stripped and their NEEDED entries
turned into requires) and global writable directories (--global-writable PATH, relative to
/boot/system). A daemon's package may also create Unix users and groups on activation (--user SPEC,
--group NAME, as the recipe's PACKAGE_USERS/PACKAGE_GROUPS) and run scripts then (--post-install FILE:
packaged as boot/post-install/<name>, e.g. openssh's host key generation). The vendor is the
HaikuPorts repository's ("Haiku Project"): package_repo refuses another one in it; the packager says
who built them.

As the recipe has it: --devel-requires adds a requirement of the _devel package (wayland_devel:
devel:libffi), --no-devel makes no _devel package (wayland_server: an add-on, nothing to link), and
--architecture any makes an architecture-independent package (ARCHITECTURES="any": data only,
wayland_protocols).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
gen = os.path.join(root, 'sources/haiku/generated.arm64')
tools = os.path.join(gen, 'cross-tools-arm64/bin/aarch64-unknown-haiku-')
pkgtool = os.path.join(gen, 'objects/linux/x86_64/release/tools/package/package')
sysroot = os.path.join(root, 'artifacts/sysroot-arm64')
nonPackaged = '/boot/system/non-packaged'


def recipe_field(text, key):
    m = re.search(r'^' + key + r'="(.*?)"', text, re.M | re.S)
    # a backslash-newline inside the quotes continues the line, as bash reads it
    return re.sub(r'\s*\\\n\s*', ' ', m.group(1)).strip() if m else ''


def elf_dynamic(path):
    out = subprocess.run([tools + 'readelf', '-d', path], capture_output=True, text=True,
        check=True).stdout
    soname = re.findall(r'\(SONAME\).*\[(.*)\]', out)
    needed = re.findall(r'\(NEEDED\).*\[(.*)\]', out)
    return (soname[0] if soname else None), needed


def has_resources(path):
    # Haiku resources (xres, rc) sit after the ELF's last byte, the section header table: strip
    # rewrites the file and drops them (NetSurf: its CSS, icons, messages)
    data = open(path, 'rb').read(64)
    if data[4] != 2:    # ELFCLASS64 only (arm64)
        return False
    shoff = int.from_bytes(data[0x28:0x30], 'little')
    shentsize = int.from_bytes(data[0x3a:0x3c], 'little')
    shnum = int.from_bytes(data[0x3c:0x3e], 'little')
    return os.path.getsize(path) > shoff + shentsize * shnum


def lib_base(soname):
    return soname.split('.so')[0]


def resolvable(name):
    # '-' is not allowed in package resolvable names (HaikuPorts: libSDL2-2.0 -> libSDL2_2.0)
    return name.replace('-', '_')


def package_info(name, version, revision, summary, licenses, copyrights, provides, requires,
        writable=(), extra='', architecture='arm64'):
    def block(items):
        return '\n'.join('\t' + i for i in items)
    writable = ''.join(f'global-writable-files {{\n\t"{w}" directory keep-old\n}}\n'
        for w in writable)
    licenses = ' '.join('"%s"' % l for l in licenses)
    copyrights = ' '.join('"%s"' % c.replace('"', "'") for c in copyrights)
    return f'''name			{name}
version			{version}-{revision}
architecture	{architecture}
summary			"{summary}"
description		"{summary}. Cross-built for the Raspberry Pi 4 by the haiku-pi project from the HaikuPorts recipe."
packager		"haiku-pi build farm <build@haiku-pi.invalid>"
vendor			"Haiku Project"
licenses		{{ {licenses} }}
copyrights		{{ {copyrights} }}
provides {{
{block(provides)}
}}
requires {{
{block(requires)}
}}
{writable}{extra}'''


def create(directory, info, out, extract=True):
    with open(os.path.join(directory, '.PackageInfo'), 'w') as f:
        f.write(info)
    if os.path.exists(out):
        os.remove(out)
    subprocess.run([pkgtool, 'create', '-q', '-C', directory, '-i',
        os.path.join(directory, '.PackageInfo'), out], check=True)
    os.remove(os.path.join(directory, '.PackageInfo'))
    if extract:
        subprocess.run([pkgtool, 'extract', '-C', os.path.join(sysroot, 'boot/system'), out],
            check=True)
    print(f'package-port: {out} ({os.path.getsize(out)} bytes)')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('recipe')
    parser.add_argument('--revision', default='1')
    parser.add_argument('--static-suffix', default='')
    parser.add_argument('--lib-version', default='',
        help='the version the libraries are provided at, as the recipe has it (ncurses6: 6.6.0; '
            'default: from the file name)')
    parser.add_argument('--source-package', action='store_true',
        help='also <port>_source: the patched sources, as HaikuPorts source packages hold them '
            '(jam builds parts of some, e.g. zstd for packagefs)')
    parser.add_argument('--provides', action='append', default=[],
        help='a further resolvable of the runtime package, at the port\'s version (e.g. app:NetSurf)')
    parser.add_argument('--requires', action='append', default=[],
        help='a further requirement of the runtime package, one that NEEDED entries cannot show '
            '(e.g. ca_root_certificates for openssl3 and curl)')
    parser.add_argument('--devel-requires', action='append', default=[],
        help='a further requirement of the _devel package (the recipe\'s REQUIRES_devel)')
    parser.add_argument('--no-devel', action='store_true',
        help='no _devel package (the recipe has none)')
    parser.add_argument('--architecture', default='arm64', choices=['arm64', 'any'],
        help='any: an architecture-independent package (the recipe\'s ARCHITECTURES="any")')
    parser.add_argument('--devel-bin', action='append', default=[],
        help='a program of bin/ that goes into the _devel package (e.g. sdl2-config)')
    parser.add_argument('--system-prefix', action='store_true',
        help='the port is installed with prefix /boot/system (install/boot/system), not non-packaged')
    parser.add_argument('--lib-tree', action='append', default=[],
        help='a directory of lib/ that goes into the runtime package as it is (python3.14)')
    parser.add_argument('--global-writable', action='append', default=[],
        help='a directory of the runtime package, relative to /boot/system, that is writable '
            '(non-packaged/lib/python3.14/site-packages)')
    parser.add_argument('--user', action='append', default=[],
        help='a Unix user the package creates, in .PackageInfo syntax (the recipe\'s PACKAGE_USERS)')
    parser.add_argument('--group', action='append', default=[],
        help='a Unix group the package creates (the recipe\'s PACKAGE_GROUPS)')
    parser.add_argument('--post-install', action='append', default=[],
        help='a script run on package activation and first boot (the recipe\'s POST_INSTALL_SCRIPTS)')
    args = parser.parse_args()

    recipeName = os.path.basename(args.recipe)[:-len('.recipe')]
    port, version = recipeName.rsplit('-', 1)
    text = open(args.recipe).read()
    summary = recipe_field(text, 'SUMMARY') or port
    licenses = [l.strip() for l in recipe_field(text, 'LICENSE').split('\n') if l.strip()]
    copyrights = [c.strip() for c in recipe_field(text, 'COPYRIGHT').split('\n') if c.strip()] \
        or [f'The {port} authors']

    install = os.path.join(root, 'artifacts/cross-ports', recipeName, 'install') \
        + ('/boot/system' if args.system_prefix else nonPackaged)
    if not os.path.isdir(install):
        sys.exit(f'package-port: {install} missing: run scripts/cross-port.sh first')
    work = os.path.join(root, 'artifacts/packages/build', port)
    shutil.rmtree(work, ignore_errors=True)
    runtime = os.path.join(work, 'runtime')
    devel = os.path.join(work, 'devel')
    os.makedirs(os.path.join(runtime, 'lib'))
    os.makedirs(os.path.join(devel, 'develop/lib'))

    # shared libraries: the real files, by soname
    libs = []
    programNeeded = []
    libDir = os.path.join(install, 'lib')
    for f in (sorted(os.listdir(libDir)) if os.path.isdir(libDir) else []):
        path = os.path.join(libDir, f)
        if os.path.islink(path) or not os.path.isfile(path) or '.so' not in f:
            continue
        soname, needed = elf_dynamic(path)
        if soname is None:
            continue
        subprocess.run([tools + 'strip', '--strip-unneeded', '-o',
            os.path.join(runtime, 'lib', soname), path], check=True)
        libVersion = args.lib_version or f.split('.so')[1].lstrip('.') or version
        libs.append((soname, libVersion, needed))
    sonames = {s for s, _, _ in libs}
    # other names the port gives its libraries at run time, as symlinks to a soname (ncurses6:
    # libncurses.so.6 -> libncursesw.so.6): kept, and provided as libraries of their own
    libLinks = []
    for f in (sorted(os.listdir(libDir)) if os.path.isdir(libDir) else []):
        path = os.path.join(libDir, f)
        if not os.path.islink(path) or '.so.' not in f or f in sonames:
            continue
        soname, _ = elf_dynamic(os.path.realpath(path))
        if soname in sonames:
            os.symlink(soname, os.path.join(runtime, 'lib', f))
            libLinks.append((f, next(v for s, v, _ in libs if s == soname)))

    # programs (symlinks between them kept: gunzip -> gzip)
    commands = []
    binDir = os.path.join(install, 'bin')
    if os.path.isdir(binDir):
        os.makedirs(os.path.join(runtime, 'bin'))
        for f in sorted(os.listdir(binDir)):
            path = os.path.join(binDir, f)
            if f in args.devel_bin:
                os.makedirs(os.path.join(devel, 'bin'), exist_ok=True)
                if os.path.islink(path):
                    os.symlink(os.readlink(path), os.path.join(devel, 'bin', f))
                else:
                    shutil.copy(path, os.path.join(devel, 'bin', f))
                continue
            target = os.path.join(runtime, 'bin', f)
            if os.path.islink(path):
                os.symlink(os.readlink(path), target)
            elif open(path, 'rb').read(4) == b'\x7fELF':
                subprocess.run([tools + 'strip', '-o', target, path], check=True)
                libs_needed = elf_dynamic(path)[1]
                programNeeded.extend(libs_needed)
            else:
                shutil.copy(path, target)
            commands.append(f)

    # applications and their data go in as they are (QuakeSpasm: apps/QuakeSpasm/...)
    for d in ('apps', 'data'):
        if os.path.isdir(os.path.join(install, d)):
            shutil.copytree(os.path.join(install, d), os.path.join(runtime, d), symlinks=True)
            for dirpath, _, files in os.walk(os.path.join(runtime, d)):
                for f in files:
                    path = os.path.join(dirpath, f)
                    if not os.path.islink(path) and open(path, 'rb').read(4) == b'\x7fELF':
                        programNeeded.extend(elf_dynamic(path)[1])
                        if has_resources(path):
                            print(f'package-port: {path}: has resources, not stripped')
                        else:
                            subprocess.run([tools + 'strip', path], check=True)

    # lib/ trees (python3.14: the standard library, lib-dynload)
    for tree in args.lib_tree:
        shutil.copytree(os.path.join(libDir, tree), os.path.join(runtime, 'lib', tree),
            symlinks=True)
        for dirpath, _, files in os.walk(os.path.join(runtime, 'lib', tree)):
            for f in files:
                path = os.path.join(dirpath, f)
                # executables and shared objects (not python's config/python.o)
                head = open(path, 'rb').read(18) if not os.path.islink(path) else b''
                if head[:4] == b'\x7fELF' and head[16] in (2, 3):
                    programNeeded.extend(elf_dynamic(path)[1])
                    subprocess.run([tools + 'strip', '--strip-unneeded', path], check=True)

    # global writable directories: in the package, extracted to the writable location on activation
    for w in args.global_writable:
        if os.path.isdir(os.path.join(install, w)):
            shutil.copytree(os.path.join(install, w), os.path.join(runtime, w), symlinks=True)

    # post-install scripts: in boot/post-install/, run on activation (and on first boot)
    postInstall = []
    for script in args.post_install:
        os.makedirs(os.path.join(runtime, 'boot/post-install'), exist_ok=True)
        target = os.path.join(runtime, 'boot/post-install', os.path.basename(script))
        shutil.copy(script, target)
        os.chmod(target, 0o755)
        postInstall.append('boot/post-install/' + os.path.basename(script))
    extra = ''
    if args.group:
        extra += 'groups {\n' + ''.join(f'\t{g}\n' for g in args.group) + '}\n'
    if args.user:
        extra += 'users {\n' + ''.join(f'\t{u}\n' for u in args.user) + '}\n'
    if postInstall:
        extra += 'post-install-scripts {\n' + ''.join(f'\t"{p}"\n' for p in postInstall) + '}\n'

    provides = [f'{port} = {version}-{args.revision}'] + [f'{p} = {version}' for p in args.provides]
    develProvides = [f'{port}_devel = {version}-{args.revision}']
    requires = {'haiku'} | set(args.requires)
    for soname, libVersion, needed in libs:
        base = lib_base(soname)
        major = libVersion.split('.')[0]
        compat = f' compat >= {major}' if major.isdigit() else ''
        provides.append(f'lib:{resolvable(base)} = {libVersion}{compat}')
        develProvides.append(f'devel:{resolvable(base)} = {libVersion}{compat}')
        programNeeded.extend(needed)
    for name, libVersion in libLinks:
        major = libVersion.split('.')[0]
        compat = f' compat >= {major}' if major.isdigit() else ''
        provides.append(f'lib:{resolvable(lib_base(name))} = {libVersion}{compat}')
        develProvides.append(f'devel:{resolvable(lib_base(name))} = {libVersion}{compat}')
    for c in commands:
        provides.append(f'cmd:{resolvable(c.replace("+", "_"))} = {version}')
    for c in args.devel_bin:
        develProvides.append(f'cmd:{resolvable(c)} = {version}')
    for n in programNeeded:
        if n in sonames:
            continue
        if os.path.exists(os.path.join(sysroot + nonPackaged, 'lib', n)) \
                or lib_base(n) in ('libstdc++', 'libgcc_s', 'libatomic'):
            requires.add(f'lib:{resolvable(lib_base(n))}')
        # else: a system library (libroot, libbe, ...), in "haiku"

    # devel: headers, static libraries, symlinks, pkg-config
    if os.path.isdir(os.path.join(install, 'include')):
        shutil.copytree(os.path.join(install, 'include'), os.path.join(devel, 'develop/headers'),
            symlinks=True)
    if os.path.isdir(os.path.join(install, 'develop/headers')):
        shutil.copytree(os.path.join(install, 'develop/headers'),
            os.path.join(devel, 'develop/headers'), symlinks=True, dirs_exist_ok=True)
    for f in (sorted(os.listdir(libDir)) if os.path.isdir(libDir) else []):
        if f.endswith('.a'):
            target = f[:-2] + args.static_suffix + '.a'
            shutil.copy(os.path.join(libDir, f), os.path.join(devel, 'develop/lib', target))
    for soname, _, _ in libs:
        for linkName in {lib_base(soname) + '.so', soname}:
            os.symlink('../../lib/' + soname, os.path.join(devel, 'develop/lib', linkName))
    # other link names the port installs for its libraries (SDL2: libSDL2.so)
    for f in (sorted(os.listdir(libDir)) if os.path.isdir(libDir) else []):
        path = os.path.join(libDir, f)
        if not os.path.islink(path) or not f.endswith('.so') \
                or os.path.lexists(os.path.join(devel, 'develop/lib', f)):
            continue
        soname, _ = elf_dynamic(os.path.realpath(path))
        if soname in sonames:
            os.symlink('../../lib/' + soname, os.path.join(devel, 'develop/lib', f))
    # lib/pkgconfig, or develop/lib/pkgconfig (meson's default on Haiku)
    for pkgconfigDir in (os.path.join(libDir, 'pkgconfig'),
            os.path.join(install, 'develop/lib/pkgconfig')):
        if not os.path.isdir(pkgconfigDir):
            continue
        os.makedirs(os.path.join(devel, 'develop/lib/pkgconfig'), exist_ok=True)
        for f in sorted(os.listdir(pkgconfigDir)):
            pc = open(os.path.join(pkgconfigDir, f)).read()
            pc = re.sub(r'^prefix=.*$', 'prefix=/boot/system', pc, flags=re.M)
            pc = re.sub(r'^libdir=.*$', 'libdir=${prefix}/develop/lib', pc, flags=re.M)
            pc = re.sub(r'^includedir=.*$', 'includedir=${prefix}/develop/headers', pc,
                flags=re.M)
            pc = pc.replace(nonPackaged + '/include', '/boot/system/develop/headers')
            pc = pc.replace(nonPackaged + '/lib', '/boot/system/develop/lib')
            open(os.path.join(devel, 'develop/lib/pkgconfig', f), 'w').write(pc)

    # licenses that are not among the system's come with the port (as haikuporter does)
    portLicenses = os.path.join(os.path.dirname(os.path.realpath(args.recipe)), 'licenses')
    for license in licenses:
        text = os.path.join(portLicenses, license)
        if os.path.isfile(text):
            for directory in (runtime, devel):
                os.makedirs(os.path.join(directory, 'data/licenses'), exist_ok=True)
                shutil.copy(text, os.path.join(directory, 'data/licenses', license))

    out = os.path.join(root, 'artifacts/packages')
    if args.source_package:
        source = os.path.join(work, 'source')
        revisioned = f'{port}-{version}-{args.revision}'
        shutil.copytree(os.path.join(root, 'artifacts/cross-ports', recipeName, 'source'),
            os.path.join(source, 'develop/sources', revisioned, 'sources'), symlinks=True)
        info = package_info(port + '_source', version, args.revision, summary
            + ' (source)', licenses, copyrights, [f'{port}_source = {version}-{args.revision}'],
            []).replace('architecture\tarm64', 'architecture\tsource')
        create(source, info, os.path.join(out, f'{port}_source-{version}-{args.revision}-source.hpkg'),
            extract=False)
    runtimeFiles = [f for d, _, fs in os.walk(runtime) for f in fs if '/data/licenses' not in d]
    if runtimeFiles:
        create(runtime, package_info(port, version, args.revision, summary, licenses,
            copyrights, provides, sorted(requires), args.global_writable, extra, args.architecture),
            os.path.join(out, f'{port}-{version}-{args.revision}-{args.architecture}.hpkg'))
        develRequires = [f'{port} == {version}-{args.revision}']
    else:
        develRequires = ['haiku']
    develRequires += args.devel_requires
    develFiles = [os.path.join(d, f) for d, _, fs in os.walk(devel) for f in fs
            if '/data/licenses' not in d] \
        + [os.path.join(d, x) for d, xs, _ in os.walk(devel) for x in xs
            if os.path.islink(os.path.join(d, x))]
    if not develFiles or args.no_devel:
        return
    create(devel, package_info(port + '_devel', version, args.revision, summary
        + ' (development files)', licenses, copyrights, develProvides, develRequires),
        os.path.join(out, f'{port}_devel-{version}-{args.revision}-arm64.hpkg'))


main()
