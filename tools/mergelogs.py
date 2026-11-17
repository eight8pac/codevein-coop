"""Merge the host's and the guest's logs into one timeline on the host's clock (read-only).
Host: game\\CodeVein\\Binaries\\Win64\\ue4ss\\UE4SS.log and plugins\\CoopNative.log; guest: local\\incoming\\live\\guest-UE4SS.log and
guest-CoopNative.log (mirrored live by his CoopNative, live_logs=1). His clock is shifted by the last "clock: host time minus ours = +X s" line
in his log (the host sends its time every 30 s, ClientMessage CoopClock).
Usage: python -I tools/mergelogs.py [--from HH:MM:SS] [--to HH:MM:SS] [--grep REGEX] [--last N] [--nonative]
Output lines: HH:MM:SS.mmm H|G U|N text   (H host / G guest, U UE4SS / N CoopNative)"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W64 = os.path.join(ROOT, 'game', 'CodeVein', 'Binaries', 'Win64')
FILES = [('H', 'U', os.path.join(W64, 'ue4ss', 'UE4SS.log')), ('H', 'N', os.path.join(W64, 'plugins', 'CoopNative.log')),
         ('G', 'U', os.path.join(ROOT, 'local', 'incoming', 'live', 'guest-UE4SS.log')),
         ('G', 'N', os.path.join(ROOT, 'local', 'incoming', 'live', 'guest-CoopNative.log'))]
# one-PC tests (2026-11-17): the boxed guest copy game2 writes its logs in place (same clock as the host)
G2 = os.path.join(ROOT, 'game2', 'CodeVein', 'Binaries', 'Win64')
if os.path.exists(os.path.join(ROOT, 'local', 'onepc-guest.txt')) and '--live' not in sys.argv[1:]:
    FILES[2] = ('G', 'U', os.path.join(G2, 'ue4ss', 'UE4SS.log'))
    FILES[3] = ('G', 'N', os.path.join(G2, 'plugins', 'CoopNative.log'))
UE = re.compile(r'^\[\d{4}-\d\d-\d\d (\d\d):(\d\d):(\d\d(?:\.\d+)?)\]\s*(.*)$')
NA = re.compile(r'^(\d\d):(\d\d):(\d\d\.\d+) (.*)$')
CLOCK = re.compile(r'clock: host time minus ours = ([+-][\d.]+) s')

def secs(h, m, s): return int(h) * 3600 + int(m) * 60 + float(s)
def fmt(t):
    t %= 86400
    return '%02d:%02d:%06.3f' % (int(t // 3600), int(t % 3600 // 60), t % 60)

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name)
        return args[i + 1] if i + 1 < len(args) else default
    return default
t_from = opt('--from'); t_to = opt('--to'); pat = opt('--grep'); last = opt('--last')
t_from = secs(*t_from.split(':')) if t_from else None
t_to = secs(*t_to.split(':')) if t_to else None
rx = re.compile(pat, re.I) if pat else None

offset = 0.0
gu = FILES[2][2]
if os.path.exists(gu):
    for line in open(gu, encoding='utf-8', errors='replace'):
        m = CLOCK.search(line)
        if m: offset = float(m.group(1))

out = []
for who, kind, path in FILES:
    if kind == 'N' and '--nonative' in args: continue
    if not os.path.exists(path): continue
    cur = None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\r\n')
        m = (UE if kind == 'U' else NA).match(line)
        if m:
            cur = secs(m.group(1), m.group(2), m.group(3)) + (offset if who == 'G' else 0.0)
            text = m.group(4)
        elif cur is None or not line.strip():
            continue
        else:
            text = '    ' + line
        text = re.sub(r'^\[Lua\] \[(Coop\w+)\] \d\d:\d\d:\d\d\.\d+ ', r'[\1] ', text)
        if t_from is not None and cur < t_from: continue
        if t_to is not None and cur > t_to: continue
        if rx and not rx.search(text): continue
        out.append((cur, who, kind, text))
out.sort(key=lambda e: e[0])
if last: out = out[-int(last):]
print('# guest clock offset %+.3f s (applied to G lines)' % offset)
for t, who, kind, text in out:
    print('%s %s %s %s' % (fmt(t), who, kind, text[:300]))
