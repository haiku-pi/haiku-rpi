#!/usr/bin/env python3
"""games-bench-table.py — the before/after table of tools/pi-tests/games-bench.sh runs.

    scripts/games-bench-table.py --a NAME LOG... --b NAME LOG...

Reads the "GB <game> <setting>: <fps> fps (...) | <thermal>" lines of each serial log and prints a
Markdown table: per game and setting, each side's mean over its logs with the per-boot figures, the
change in percent, and the highest temperature seen after any of the runs.
"""
import re
import sys

LINE = re.compile(r'\bGB (?!thermal|image|packages|shader|wine:|wine prefix|end|crash|  )(.+?): (\S+) fps(.*)$')
TEMP = re.compile(r'\| ([0-9.]+) C, throttled (0x[0-9a-f]+)')


def read(logs):
    """{test: [fps per log]}, max temperature, throttle flags seen, wine prefix seconds"""
    results, temps, throttled, prefix = {}, [], set(), []
    for log in logs:
        with open(log, 'rb') as f:
            text = f.read().decode('utf-8', 'replace')
        for raw in text.splitlines():
            m = LINE.search(raw)
            if m:
                test, fps, rest = m.group(1), m.group(2), m.group(3)
                try:
                    results.setdefault(test, []).append(float(fps))
                except ValueError:
                    results.setdefault(test, [])
                t = TEMP.search(rest)
                if t:
                    temps.append(float(t.group(1)))
                    throttled.add(t.group(2))
            p = re.search(r'GB wine prefix: (\d+) s', raw)
            if p:
                prefix.append(int(p.group(1)))
    return results, temps, throttled, prefix


def fmt(values):
    if not values:
        return 'n/a'
    mean = sum(values) / len(values)
    return '**%.1f** (%s)' % (mean, ' / '.join('%.1f' % v for v in values))


def main(argv):
    sides, cur = [], None
    for a in argv:
        if a in ('--a', '--b'):
            cur = [None, []]
            sides.append(cur)
        elif cur is not None and cur[0] is None:
            cur[0] = a
        elif cur is not None:
            cur[1].append(a)
    if len(sides) != 2:
        sys.exit(__doc__)
    (na, la), (nb, lb) = sides
    ra, ta, tha, pa = read(la)
    rb, tb, thb, pb = read(lb)
    print('| game, setting | %s fps | %s fps | change |' % (na, nb))
    print('|---|---|---|---|')
    for test in list(dict.fromkeys(list(ra) + list(rb))):
        a, b = ra.get(test, []), rb.get(test, [])
        change = ''
        if a and b:
            change = '%+.0f %%' % ((sum(b) / len(b)) / (sum(a) / len(a)) * 100 - 100)
        print('| %s | %s | %s | %s |' % (test, fmt(a), fmt(b), change))
    for name, temps, th, prefix in ((na, ta, tha, pa), (nb, tb, thb, pb)):
        print('\n%s: %d boots; temperature after the runs %s-%s C, throttled flags %s; Wine prefix %s s' % (
            name, len(la if name == na else lb), min(temps, default=0), max(temps, default=0),
            ','.join(sorted(th)) or '-', '/'.join(map(str, prefix)) or '-'))


if __name__ == '__main__':
    main(sys.argv[1:])
