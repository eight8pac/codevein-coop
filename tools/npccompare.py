"""Compare the newest NPC census ("rec census" / "rec npc" lines of CoopProbe) of the host and the guest (read-only).
Prints every story / side-quest character either PC has, with its visibility flags on both sides and its distance to a point.
Usage: python -I tools/npccompare.py [X Y Z] [--all]   (default: only characters within 100 m of the point, when given)
Guest log: game2 (one-PC test, local/onepc-guest.txt) or local/incoming/live/guest-UE4SS.log."""
import os, re, sys, math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = os.path.join(ROOT, 'game', 'CodeVein', 'Binaries', 'Win64', 'ue4ss', 'UE4SS.log')
if os.path.exists(os.path.join(ROOT, 'local', 'onepc-guest.txt')):
    GUEST = os.path.join(ROOT, 'game2', 'CodeVein', 'Binaries', 'Win64', 'ue4ss', 'UE4SS.log')
else:
    GUEST = os.path.join(ROOT, 'local', 'incoming', 'live', 'guest-UE4SS.log')
NPC = re.compile(r'rec npc ([0-9A-F]+) (\S+) lvl=(\S+) role=(\S+) pv=(\S+) sv=(\S+) hid=(\S+) meshHid=(\S+) meshVis=(\S+) sq=(\S+) at (-?\d+),(-?\d+),(-?\d+)')

def newest(path):
    """the npc lines of the last census in the file"""
    lines = open(path, encoding='utf-8', errors='replace').read().splitlines()
    start = max((i for i, l in enumerate(lines) if 'rec census (' in l), default=None)
    if start is None: return None, {}
    head = lines[start].split('] ')[-1]
    out = {}
    for l in lines[start + 1:]:
        if 'rec census (' in l: break
        m = NPC.search(l)
        if m:
            nm = m.group(2)
            if nm.startswith('BP_Player'): continue
            out[nm] = dict(lvl=m.group(3), role=m.group(4), pv=m.group(5), hid=m.group(7), meshVis=m.group(9), sq=m.group(10),
                           at=(int(m.group(11)), int(m.group(12)), int(m.group(13))))
    return head, out

args = [a for a in sys.argv[1:] if not a.startswith('--')]
pt = tuple(float(a) for a in args[:3]) if len(args) >= 3 else None
hh, h = newest(HOST)
gh, g = newest(GUEST)
print('host : ' + str(hh)); print('guest: ' + str(gh))
def shown(e):
    """visible as far as the flags tell: progress visibility on, actor not hidden, mesh visible"""
    if e is None: return '-'
    return 'SHOWN' if (e['pv'] != 'false' and e['hid'] != 'true' and e['meshVis'] != 'false') else 'hidden'
rows = []
for nm in sorted(set(h) | set(g)):
    e = h.get(nm) or g.get(nm)
    d = math.dist(pt, e['at']) / 100 if pt else 0
    if pt and d > 100 and '--all' not in sys.argv: continue
    hs, gs = shown(h.get(nm)), shown(g.get(nm))
    flag = '  <-- differs' if hs != gs else ''
    def f(x): return '-' if x is None else 'pv=%s hid=%s mesh=%s sq=%s' % (x['pv'], x['hid'], x['meshVis'], x['sq'])
    rows.append((d, '%6.0f m  %-48s host %-6s (%s) | guest %-6s (%s) lvl %s%s' % (d, nm, hs, f(h.get(nm)), gs, f(g.get(nm)), e['lvl'], flag)))
for _, r in sorted(rows): print(r)
print('# %d character(s) listed' % len(rows))
