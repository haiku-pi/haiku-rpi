#!/bin/sh
# launch-env.sh — UserBootscript: reports on the serial console ("LENV ") the variables this job got from
# /system/boot/SetupEnvironment, which launch_daemon evaluates for the user session's "desktop" target (its
# "env" source file: BaseJob::_GetSourceFileEnvironment()). Unset values print as "-". Used by the
# launch_daemon pipe check (design/renkuos-fixes.md): `scripts/boot-bench.sh N --netboot --bootscript` this.
out=/dev/dprintf
echo "LENV XDG_CONFIG_HOME=${XDG_CONFIG_HOME:--} LC_MESSAGES=${LC_MESSAGES:--} USER=${USER:--} GROUP=${GROUP:--}" > $out
