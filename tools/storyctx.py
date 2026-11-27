"""storyctx.py <story code dir> <regex> <before> <after> <file> [file...]: decompiled lines around matches (merged windows)."""
import sys, re
root, rx, b, a = sys.argv[1], re.compile(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
for f in sys.argv[5:]:
    L = open(root + '/' + f, encoding='utf-8').read().split('\n')
    idx = [i for i, l in enumerate(L) if rx.search(l)]
    wins = []
    for i in idx:
        s, e = max(0, i - b), min(len(L), i + a + 1)
        if wins and s <= wins[-1][1]: wins[-1][1] = e
        else: wins.append([s, e])
    fn = None
    for s, e in wins:
        for j in range(s, -1, -1):
            if L[j].startswith('== function'): fn = L[j]; break
        print('--- %s  [%s]' % (f.replace('Cinematics/Scenario/', 'C/S/'), fn[12:] if fn else '?'))
        for l in L[s:e]: print(l[:220])
