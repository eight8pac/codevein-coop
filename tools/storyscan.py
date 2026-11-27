"""Story audit, pass 1 (read-only): for every .uasset/.umap in the paks (latest pak wins) list the native functions it calls
(imports of class Function, as Class:Function), plus its exports' class names. Writes a JSON map path -> {f: [...], x: [...]}.
Usage: python -I storyscan.py <tools dir> <paks dir> <out.json>"""
import sys, os, struct, json, time
sys.path.insert(0, sys.argv[1])
import pakv4
paks, out = sys.argv[2], sys.argv[3]
order = sorted([f for f in os.listdir(paks) if f.endswith('.pak')],
               key=lambda f: (f.replace('_0_P', '').replace('_0_p', ''), '_0_p' in f.lower()))
latest = {}
for f in order:
    p = pakv4.Pak(os.path.join(paks, f))
    for n in p.entries:
        if n.endswith(('.uasset', '.umap')): latest[n] = p

def header(ua):
    o = 8 + 4 + 4 + 4
    nc, = struct.unpack_from('<i', ua, o); o += 4 + nc * 20 + 4
    _, o = pakv4._fstr(ua, o); o += 4
    name_count, name_off, _gtc, _gto, exp_count, exp_off, imp_count, imp_off = struct.unpack_from('<8i', ua, o)
    q = name_off; names = []
    for _ in range(name_count):
        s, q = pakv4._fstr(ua, q); q += 4; names.append(s)
    imports = []
    for i in range(imp_count):
        b = imp_off + i * 28
        _cp, _, cls_name, _, outer, obj_name, _ = struct.unpack_from('<iiiiiii', ua, b)
        imports.append((names[cls_name], names[obj_name], outer))
    return names, imports, exp_count, exp_off

res = {}; t0 = time.time(); bad = 0
for i, (n, p) in enumerate(sorted(latest.items())):
    path = n.split('Content/', 1)[-1]
    if not path.startswith(('Cinematics/', 'Maps/', 'Characters/Blueprints/', 'Blueprints/', 'UserInterface/', 'Environment/', 'Systems/', 'GameData/')):
        pass
    try:
        ua = p.read(n)
        names, imports, ec, eo = header(ua)
    except Exception:
        bad += 1; continue
    fn = []
    for c, o, outer in imports:
        if c == 'Function':
            oc = imports[-outer - 1][1] if outer < 0 and -outer - 1 < len(imports) else '?'
            fn.append(oc + ':' + o)
    xs = set()
    for k in range(ec):
        ci, = struct.unpack_from('<i', ua, eo + k * 104)
        if ci < 0 and -ci - 1 < len(imports): xs.add(imports[-ci - 1][1])
    if not fn and 'Function' not in xs: continue
    res[path] = {'f': sorted(set(fn)), 'x': sorted(xs)}
    if i % 5000 == 0: print(i, len(latest), len(res), '%.0fs' % (time.time() - t0), flush=True)
json.dump(res, open(out, 'w'))
print('done', len(res), 'assets with native calls,', bad, 'unreadable, %.0fs' % (time.time() - t0))
