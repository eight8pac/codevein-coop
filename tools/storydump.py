"""Story audit, pass 2 (read-only): decompile every asset listed by pass 1 (storyscan.py) into <out>/code/<path>.txt and collect
all calls with their arguments into <out>/calls.json ({path: [[function, callee, [args]], ...]}).
Usage: python -I storydump.py <tools dir> <paks dir> <pass1.json> <out dir>"""
import sys, os, json, time
sys.path.insert(0, sys.argv[1])
import pakv4, kismetdump
paks, p1, out = sys.argv[2], sys.argv[3], sys.argv[4]
want = set(json.load(open(p1)))
order = sorted([f for f in os.listdir(paks) if f.endswith('.pak')],
               key=lambda f: (f.replace('_0_P', '').replace('_0_p', ''), '_0_p' in f.lower()))
latest = {}
for f in order:
    pk = pakv4.Pak(os.path.join(paks, f))
    for n in pk.entries:
        latest[n] = pk
calls, errs, t0, done = {}, [], time.time(), 0
for n, pk in sorted(latest.items()):
    if not n.endswith(('.uasset', '.umap')): continue
    path = n.split('Content/', 1)[-1]
    if path not in want: continue
    x = n.rsplit('.', 1)[0] + '.uexp'
    if x not in latest: continue
    try:
        text, cl = kismetdump.dump(pk.read(n), latest[x].read(x))
    except Exception as ex:
        errs.append('%s: %s' % (path, ex)); continue
    if 'DECODE ERROR' in text: errs.append('%s: %d function(s) not decoded' % (path, text.count('DECODE ERROR')))
    dst = os.path.join(out, 'code', path.rsplit('.', 1)[0] + '.txt')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, 'w', encoding='utf-8').write(text)
    calls[path] = [[f, c, a] for f, c, a in cl]
    done += 1
    if done % 500 == 0: print(done, len(want), '%.0fs' % (time.time() - t0), flush=True)
json.dump(calls, open(os.path.join(out, 'calls.json'), 'w'))
open(os.path.join(out, 'errors.txt'), 'w').write('\n'.join(errs))
print('done', done, 'assets,', len(errs), 'with errors, %.0fs' % (time.time() - t0))
