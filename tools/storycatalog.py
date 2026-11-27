"""Story audit, pass 4 (read-only): one row per story asset with its area, kind, first dialog line, co-op features and a risk rating.
Inputs: <story dir>/calls.json, risk.json, game-en.tsv (tools/locres.py). Output: <story dir>/catalog.json + a printed summary.
Usage: python -I storycatalog.py <story dir>"""
import sys, os, re, json, collections
story = sys.argv[1]
calls = json.load(open(os.path.join(story, 'calls.json')))
risk = json.load(open(os.path.join(story, 'risk.json'), encoding='utf-8'))
text, areas = {}, {}
for line in open(os.path.join(story, 'game-en.tsv'), encoding='utf-8'):
    p = line.rstrip('\n').split('\t')
    if len(p) < 3: continue
    if p[0] == 'playbook': text[p[1].lower()] = p[2]
    if p[0] == 'FieldName': areas[p[1]] = re.sub(r'^AREA [^\s　]+[\s　]+', '', p[2])
AREA = {'St01': 'Provisional Government Outskirts', 'St02': 'Ruined City Underground', 'St04': 'Dried-up Trenches', 'St05': 'Ruined City Center',
        'St06': 'Howling Pit', 'St07': 'Cathedral of the Sacred Blood', 'St09': 'Ridge of Frozen Souls', 'St10': 'Ashen Cavern',
        'St11': 'City of Falling Flame', 'St12': 'Crown of Sand', 'St13': 'Crypt Spire', 'St14': 'Provisional Government Center',
        'St15': 'Gaol of the Stagnant Blood', 'St17': 'Military Research Facility (the past)', 'St18': 'Tutorial', 'St19': 'Training Sector',
        'Base01': 'Home Base', 'Base02': 'Hot Spring', 'Base03': 'Home Base (Slave camp)', 'Opening': 'Prologue', 'Tutorial': 'Tutorial'}
ORDER = ['Opening', 'Tutorial', 'St02', 'St05', 'St04', 'St06', 'St07', 'St17', 'St09', 'St10', 'St11', 'St12', 'St13', 'St14', 'St01', 'St15', 'Base01', 'Base02', 'Base03', 'St18', 'St19']

def area_of(p):
    for seg in p.split('/'):
        m = re.match(r'(St\d\d|Base0\d|Opening|Tutorial)', seg)
        if m: return m.group(1)
    m = re.search(r'Memory_e(\d+)', p)
    if m: return 'Memory'
    if 'SubQuest' in p: return 'SubQuest'
    if 'SpaArchive' in p: return 'Base02'
    return 'Common'

def kind_of(p):
    b = p.rsplit('/', 1)[-1]
    if b.startswith('Memory_'): return 'memory'
    if 'FlowDiagram' in b or b.startswith('BP_SpaSFD'): return 'flow'
    if re.search(r'_Menu|MenuInterchange', b): return 'menu'
    if '_talk' in b.lower() or 'Talk' in b or 'Greeting' in b or 'Achieve' in b or 'request' in b: return 'talk'
    if 'ScenarioChara' in b or 'ScenarioCharacter' in b or 'SubQuestChara' in b: return 'character'
    if 'Trigger' in b or 'Starter' in b: return 'trigger'
    if 'SequencePolyActor' in b or 'SequencePlayer' in b: return 'cutscene actor'
    if b.startswith('BP_Scenario'): return 'scene'
    if '_GameBP' in b or p.startswith('Maps/'): return 'level script'
    return 'other'

def first_line(p):
    b = p.rsplit('/', 1)[-1].replace('.txt', '').replace('.uasset', '')
    cands = []
    m = re.search(r'BP_Scenario_(\w+?)(?:_C)?$', b)
    if m: cands.append(m.group(1))
    for e in re.findall(r'(e\d{5})', b): cands.append(e)
    for c in cands:
        c = c.lower()
        for suf in ('_0010', '_0020', '_0030', '_s0010', '_0040', ''):
            k = c + suf if not c.endswith(suf) else c
            if k in text: return text[k]
        hits = sorted(k for k in text if k.startswith(c + '_'))
        if hits: return text[hits[0]]
    return ''

def has(lines, rx): return any(re.search(rx, l) for l in lines)
rows = []
for p, cs in calls.items():
    path = p.rsplit('.', 1)[0] + '.txt'
    rk = risk.get(path, {})
    if not rk and not (p.startswith('Cinematics/') or 'Scenario' in p): continue
    allc = set(c for _f, c, _a in cs)
    names = set(c.split('.')[-1] for c in allc)
    L = lambda k: rk.get(k, [])
    feat, notes, score = [], [], 0
    a = area_of(p); k = kind_of(p)
    if has(L('partner'), r'ChangeBuddy\(|\.SetBuddy\(|\.ResetBuddy\(|RegisterBuddyByte|ReleaseBuddy'):
        forced = k == 'flow'
        feat.append('partner change' + (' (forced, story)' if forced else ' (player choice)'))
        score += 3
    if has(L('memory'), r'PlayMemoryResidue\('):
        m = re.findall(r'PlayMemoryResidue\(self, "(\w+)"', ' '.join(L('memory')))
        feat.append('starts memory ' + ','.join(sorted(set(m)))); score += 3
    if k == 'memory': feat.append('memory script'); score += 1
    moves = re.findall(r'Save(?:Restore|Respawn)PositionByTag\(self, "(\w+?)_GameBP', ' '.join(L('move_player')))
    other = sorted(set(m for m in moves if not m.startswith(a if a.startswith('St') else '###')))
    if other and a.startswith(('St', 'Opening')): feat.append('moves the player to ' + ', '.join(other)); score += 3
    if has(L('move_player'), r'MigrateToPast'): feat.append('travel to/from the past (MigrateToPast)'); score += 3
    if has(L('move_player'), r'RequestFlowTransition|VanishField|GoBackHideout'): feat.append('leaves the field (flow transition)'); score += 2
    if has(L('host_only'), r'GetGameMode|OnSpawnPlayerDelegate'): feat.append('needs the GameMode (host only)'); score += 3
    if has(L('host_only'), r'IsOnlineMultiplay'): feat.append('option switched off in multiplayer'); score += 2
    if has(L('host_only'), r'IsServer|HasAuthority'): feat.append('host-only branch (IsServer)'); score += 1
    if has(L('host_only'), r'GetHostActor|GetHostPlayerActor'): feat.append('uses the host character'); score += 1
    if has(L('pick_player'), r'.'): feat.append('picks "the" player from all players'); score += 1
    sr = sum(1 for l in L('input_lock') if '.SetRestricted' in l); cr = sum(1 for l in L('input_lock') if '.ClearRestricted' in l)
    if sr and not cr and k != 'other' and a not in ('Base01', 'Base02'): feat.append('restricts actions (released elsewhere)'); score += 2
    elif sr: feat.append('restricts actions (released in the same scene)')
    if has(L('input_lock'), r'SetTemporaryInputMask'): feat.append('input lock')
    if has(L('fade'), r'RequestSolidFade|RequestLoadingFade|ShowEffectFade|LocalFadeOut'): feat.append('fade to black')
    rw = re.findall(r'(DA_BloodCode_\w+|DA_Item_[\w]+|DA_RenketsuArticle_\w+)', ' '.join(L('reward')))
    if rw: feat.append('gives ' + ', '.join(sorted(set(rw)))[:160]); score += 1 if k in ('talk', 'menu') else 2
    if has(L('choice'), r'CreateBranchWindow|OpenGeneralYesNoDialog|RingListChoice'): feat.append('choice window')
    if has(L('npc_world'), r'SetCheckPointVisibility|OpenCheckPoint'): feat.append('shows/hides/opens a Mistle'); score += 1
    if has(L('npc_world'), r'SetProgressVisibility|CharacterStopAndInvisible|Multicast_StopAndInvisible'): feat.append('NPC shown/hidden by story')
    if has(L('cutscene'), r'.'): feat.append('cutscene')
    if has(L('sync'), r'.'): feat.append('waits for both players')
    if has(L('progress'), r'SetGameProgress\(|SetGameTempProgress\(|SetProgressFlag\('):
        fl = sorted(set(re.findall(r'(?:SetGameProgress|SetGameTempProgress|SetProgressFlag)\((?:self, )?"(\w+)"', ' '.join(L('progress')))))
        if fl: feat.append('story flags ' + ', '.join(fl)[:120])
    if has(L('session'), r'.'): feat.append('closes the session to new joiners')
    if has(L('death'), r'TryExecuteDeath'): feat.append('kills the player')
    level = 'high' if score >= 3 else 'medium' if score >= 1 else 'low'
    rows.append({'path': p, 'area': a, 'areaName': AREA.get(a, a), 'kind': k, 'name': p.rsplit('/', 1)[-1].rsplit('.', 1)[0],
                 'line': first_line(p)[:160], 'features': feat, 'risk': level, 'score': score})
rows.sort(key=lambda r: (ORDER.index(r['area']) if r['area'] in ORDER else 99, r['name']))
json.dump(rows, open(os.path.join(story, 'catalog.json'), 'w', encoding='utf-8'), ensure_ascii=False)
c = collections.Counter((r['risk']) for r in rows); print(len(rows), 'rows', dict(c))
ck = collections.Counter(r['kind'] for r in rows); print(dict(ck))
ca = collections.Counter(r['area'] for r in rows); print(dict(ca))
