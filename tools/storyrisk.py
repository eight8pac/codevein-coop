"""Story audit, pass 3 (read-only): flag co-op-sensitive statements in the decompiled story assets (local/story/code).
Writes <story dir>/risk.json {asset: {category: [lines]}} and prints a per-category summary.
Usage: python -I storyrisk.py <story dir>"""
import sys, os, re, json, collections
story = sys.argv[1]
CATS = {
 'host_only': r'GetGameMode\(|\.IsServer\(|HasAuthority\(|GetHostActor\(|GetHostPlayerActor\(|IsMyPlayerControlled\(|IsOnlineMultiplay\(|GetAuthGameMode|OnSpawnPlayerDelegate',
 'pick_player': r'GetAllActorsOfClass\([^,]*, (BP_Player_C|AppPlayerCharacter|BP_PlayerBase_C|Character|AppCharacter)\b|プレイヤーのActorを取得\(',
 'partner': r'ChangeBuddy\(|\.(SetBuddy|ResetBuddy|BuddySpawn|BuddyInstanceDestroy|RemoveBuddyVolatileSave|RegisterBuddyByte|RegisterBuddyName|ReleaseBuddy|IsAlreadyBuddyByte|IsAlreadyBuddy|GetBuddy|IsBuddyAlive)\(|同行NPCか？\(',
 'memory': r'\.(PlayMemoryResidue|WaitForMemoryResidueFinished|FinishCurrentMuseum|SkipCurrentMuseum|SetRelatedFlowDiagram|SetScenarioFlowDiagram|IsPlayerPlayable)\(|FinishMuseum\(|記憶の残滓を開放して親密度上昇\(|全記憶収集済みか？\(',
 'move_player': r'\.(WaitForDeferredTeleportFinished|SaveRestorePositionByTag|SaveRestorePositionByNum|SaveRespawnPositionByTag|MoveToRestorePosition|GoBackHideout|MigrateToPast|RequestPlayerSpawn|RequestPlayerSpawnToLastCheckPoint|SpawnActorForTargetSubLevel|K2_TeleportTo|UpdateLastCheckPointPosition|RequestFlowTransition)\(|キャラクターを指定位置に移動\(|VanishField\(',
 'levels': r'\.(LoadStreamLevel|UnloadStreamLevel)\(|LoadSubLevels\(|UnloadSubLevels\(',
 'fade': r'\.(LocalFadeOut|LocalFadeOutEx|LocalFadeIn|LocalFadeInEx|RequestSolidFade|RequestLoadingFade|RequestUnfade|ShowEffectFade|HideEffectFade|WaitForFadeFinished)\(',
 'input_lock': r'\.(SetTemporaryInputMask|ClearTemporaryInputMask|ClearAllTemporaryInputMask|SetAnalogStickMask|ClearAnalogStickMask|SetRestrictedActionInBaseInfo|ClearRestrictedActionInBaseInfo|SetRestrictedActionInBaseInfoHost|ClearRestrictedActionInBaseInfoHost|SetRestrictedHUDActionInBaseInfo|SetRestrictedItemActionInBaseInfo|SetGamePaused|SetPhotoModeProhibition|DisableLockon)\(',
 'progress': r'\.(SetProgressFlag|SetGameTempProgress|SetGameProgress|SetGameProgressInt|SetLockProgress|ForceResetScenarioFlags|CountupFlagSymbols|ResetProgressFlags|DoOverrideProgressFlags|SetEvent|ResetEvent|SetChunkZeroPartCleared|SetClosenessWithByte)\(',
 'reward': r'\.(TakeArticle|ItemRemove|AcquireBloodCode|AcquireKetsugi|UpdateAllBloodCodeStatus|SetMaxIchor|SetIchor|SolveLostExp|ItemAdd|AddItem|AcquireItem)\(|BCを直接入手する\(|錬血を直接入手する\(|所持している血英に応じたBCを習得\(',
 'choice': r'\.(CreateBranchWindow|OpenGeneralYesNoDialog|OpenUI|JumpToChildMenu|OpenTopMenuWithComponent|RingListChoice)\(',
 'npc_world': r'\.(SetProgressVisibility|CharacterStopAndInvisible|ShowHiddenCharacters|SafeDestroyActor|HideAllScenarioCharacters|SetCheckPointVisibility|OpenCheckPoint|K2_DestroyActor|BeginDeferredActorSpawnFromClass|SetActorHiddenInGame)\(|Multicast_StopAndInvisible\(',
 'death': r'\.(TryExecuteDeath|IsDeath|ClearAllCondition)\(',
 'session': r'\.(CloseOnlineSession|OpenOnlineSession)\(|ExecuteFlowDiagram_Multicast',
 'hideout_ui': r'\.(BootUpAvatarCustomize|BootUpHotSpring|ShowStore|BootUpScenario)\(',
 'cutscene': r'\.(PlayLargePoly|PlaySpecialPoly|DirectPlayLevelSequence|PlayUpInternalScenario)\(',
 'sync': r'\.WaitForOnlineMultiplaySynced\(',
}
RX = {k: re.compile(v) for k, v in CATS.items()}
def scope(p):
    return p.startswith(('Cinematics/', 'Maps/', 'Characters/Blueprints/Field', 'SubQuest')) or 'Scenario' in p or 'MemoryDen' in p or '/SubQuest' in p
res = {}
root = os.path.join(story, 'code')
for d, _, fs in os.walk(root):
    for f in fs:
        path = os.path.relpath(os.path.join(d, f), root).replace('\\', '/')
        if not scope(path): continue
        hits = collections.defaultdict(list); fn = '?'
        for line in open(os.path.join(d, f), encoding='utf-8'):
            if line.startswith('== function '): fn = line[12:].strip(); continue
            for k, rx in RX.items():
                if rx.search(line):
                    s = fn + ': ' + re.sub(r'^\s*\d+\s+', '', line.rstrip())
                    if s not in hits[k]: hits[k].append(s)
        if hits: res[path] = dict(hits)
json.dump(res, open(os.path.join(story, 'risk.json'), 'w', encoding='utf-8'), ensure_ascii=False)
cnt = collections.Counter(k for v in res.values() for k in v)
print(len(res), 'story assets with flagged lines')
for k in CATS: print('%-12s %4d assets' % (k, cnt[k]))
