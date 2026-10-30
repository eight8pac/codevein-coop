# Code Vein seamless co-op (work in progress)

Mods that keep a Code Vein (2019) co-op group together: automatic re-hosting and re-joining after the deaths and boss kills
that end a vanilla session, co-op in areas whose boss is dead, and native experiments for resting at a Mistle in co-op and
keeping a dead guest in the session to spectate. **Not a release**: tested by hand on two PCs only, one guest (vanilla cap).

Findings, teardown table and QA live in the Co-op Anything write-up:
<https://github.com/cranebeaker/coop-anything/tree/main/games/code-vein>

Built for **Steam, version 1.53.93354** (exe SHA-256 `8fa550fe00a8c28c8947a9511128c21924860be0bb4ebf5a09b8a6cf50e0e172`).
CoopNative's addresses are fixed for that build; it checks 16 bytes at every target and skips any hook that does not match.

## Parts

| Path | What | Needed on |
|---|---|---|
| `mods/CoopSeamless` | UE4SS Lua mod: re-host / re-join reconciler, co-op in beaten areas. Switches in `config.txt` | host and guests |
| `mods/CoopProbe` | UE4SS Lua mod: state log every 0.2 s; tells CoopNative when a spectate window is open; spectate camera | everyone running CoopNative |
| `native/coopnative.c` | C DLL (MinHook detours), loaded by Ultimate ASI Loader. Experiments, all **off** unless enabled | host and guests (for tests) |
| `tools/` | Read-only analysis: pak v4 reader, Kismet call/arg finders, exe scanners, headless Ghidra scripts | developers |

## Install (game closed)

Everything goes into `<game dir>\CodeVein\Binaries\Win64`.

1. **UE4SS v3.0.1-1181** (the `experimental-latest` build, <https://github.com/UE4SS-RE/RE-UE4SS/releases>). In `UE4SS-settings.ini` set **`HookLoadMap = 0`**
   (`1` crashes at the first map travel on this game).
2. Copy `mods/CoopSeamless` and `mods/CoopProbe` to `ue4ss\Mods\` and enable both in `ue4ss\Mods\mods.txt`
   (`CoopSeamless : 1`, `CoopProbe : 1`) and in `mods.json` if your UE4SS has one.
3. Optional, native experiments: put **Ultimate ASI Loader** (<https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases>,
   x64) in `Win64` as `winmm.dll`, build `CoopNative.asi` (below) and put it in `Win64\plugins\`. To switch experiments on,
   create `plugins\CoopNative.ini` with any of:
   ```
   veto_endcoop=1   keep the session when a player dies for good in a boss fight while another lives (both PCs)
   spectate_cam=1   while held that way, the dead player's camera follows a living player (CoopProbe)
   keep_dying=1     group respawn (both PCs): a guest whose revive window runs out stays in the host's world, his body is
                    removed, he spectates, and the host's next Mistle rest respawns him next to the host (appear effect)
   rest_in_coop=1   allow resting at a Mistle with a guest connected (host; on a guest only together with guest_rest)
   guest_rest=1     guest only: E at a Mistle opens his own Mistle menu instead of the vanilla rest (which asserts on a guest);
                    switch partner is disabled there; level-up in progress (see Status)
   levelup_relay=1  host: apply a guest's level-up (sent as Server_AddExp(0) per level) to the host's copy of him
   vestige_menu=1   host only, research: the Mistle menu sees "no signal" so its memory/vestige entries are enabled
   vestige_keep=1   host only, untested: the vestige restoration screen sees "no session", so a memory keeps the session
   group_teleport=1 host only: after the host's Mistle teleport the guest is spawned next to him (also into another stage)
   teleport_skip_fields=<id>,<id>  host: teleport destinations (FieldID, logged on every teleport) that keep vanilla
                    behaviour; Home Base is a separate map and needs to be listed here (its ID is not known yet)
   keep_outro=1     both PCs: a boss kill no longer sends the guest home; the outro's four "partner ready" checks are
                    answered for the host, and the memory's character-setup lock is reset so the host's memory starts
   guest_outro=1    guest: when the boss dies, his game starts the boss area's post-boss cutscene too (he watches it with
                    the host)
   scenario_trace_names=A,B  log only: trace single cutscene waits by name
   scenario_trace=1 log only: trace the cutscene/deferred-teleport UFunctions (this broke a boss intro; off by default)
   trace_death=1    log only: native trace of death/fade/spawn UFunctions (diagnostics)
   group_rest=1     host only, untested: heal every living player when the host rests (CoopProbe)
   ```
   CoopNative writes `plugins\CoopNative.log` on every launch.
4. Everyone in the group uses the **same matchmaking password**; the automatic search joins the first matching signal.

Uninstall: remove the two mod folders, `winmm.dll` and `plugins\`.

## Build CoopNative

Needs [Zig](https://ziglang.org/download/) (0.17 used; its clang cross-compiles for Windows without Visual Studio):
`ZIG=/path/to/zig sh native/build.sh` → `native/build/CoopNative.asi`.

## Status

Works (two PCs): rejoin after guest field death, host death, boss-room death + wipe, boss kill; co-op in beaten areas.

Works (two PCs, experiments):
- `rest_in_coop`: the host rests at a Mistle with a guest connected; the guest stays and the enemies respawn when the host gets
  up (two `IsOnlineMultiplay` checks in the reset are answered "not multiplayer"). The guest's own rest opens his Mistle menu
  only (no reset yet; it already sends the host a request, `Server_AddExp(-2601)`).
- `veto_endcoop` + `spectate_cam`: a guest who dies for good in a boss fight stays in the host's world and watches the host fight.
  A wipe still ends the session normally. Two veto points are needed: `EndCooperativeMode` and the small function that actually
  switches co-op off (`0x14081BDA0`), which a Blueprint-driven death path calls directly. The black screen was the death overlay
  `WDT_DeathParts`, hidden while spectating. The low-health screen filter and heartbeat still play.

- Boss kill while a guest is held: the held guest replays the vetoed leave, the host's outro plays, the guest is sent home and
  rejoins (works).
- `keep_dying` group respawn (works): the final death is vetoed on both PCs (`TryExecuteDeath` 0x140508540 for falls decided on the
  host, the component death processing 0x14056AC60 for an expired revive window decided on the guest), the true-dead body is removed
  at once (the partner cannot revive it, the dissolve does not matter), the guest spectates, and the host's next rest spawns him next
  to the host with `CharacterHelper:RequestPlayerSpawn` and the appear sequence.
- `guest_rest`: his own Mistle menu opens on E; heal sticks; switch partner disabled; **level-up works on both PCs**. How: the
  guest owns his haze, the host owns the level its copy of him shows (max HP comes from there). On the guest the menu's
  level-up is replaced by a direct call of the HumanContextIF level-up (0x1405A2E20) on his own component, with the
  authority-like check 0x140456A00 forced true for his pawn during the call (the level getter otherwise derives the old level
  from his player data). He then sends `Server_AddExp(0)` once per level; the host sets the level of its copy with the setter
  (base+0x88) under the same force and recomputes the stats, so his max HP updates. Gifts work (vanilla), once he switches to
  the blood code the gift belongs to.
- `group_teleport` (works, also into a completely different stage): a Mistle teleport is not a move but
  `CheckPointUIComponent:RequestPlayerSpawnToCheckPoint`, a fresh spawn at the target (the world is one map with streamed stages).
  It ends co-op twice: `SwitchToEndCoop` from 0x146678D02 (with an "ending co-op / distress signal" message shown by
  0x14083A630 just before) and, on entering a stage where multiplayer is off, from 0x146D627CF plus a second step 0x1409F1BA0
  ("multiplayer is not possible in this area"). With those vetoed or skipped, the host arrives (CoopNative sees the characters
  re-spawn) and the guest is spawned next to him with `RequestPlayerSpawn`. The guest gets the game's own teleport fade: the host
  sends `PlayerController:ClientMessage("CoopTeleportFade")` (a client RPC, used as a host -> guest channel) at the start, the
  guest's CoopNative calls `RequestTeleportFade(ctx, ctx, 48, 0)` like the vanilla teleport and unfades once he is next to the
  host. Home Base (FieldID 0) is a separate map and keeps the vanilla behaviour (`teleport_skip_fields=0`).
- Falls (`keep_dying`): a fall leads straight to spectating (no revive window, no partner revive in the pit); the guest comes
  back next to the host at the host's next rest.

Post-boss outro and memory with the guest connected (`keep_outro`, `guest_outro`, two-PC tests 2026-10-30):
- The outro (large-poly cutscene) waited for "partner ready" flags the guest never sets: four `IsOnlineMultiplay` calls in the
  scenario manager (+0x20C..+0x212 checks, return addresses 0x14705DE3F, 0x1470613D3, 0x147050AB8, 0x14705DD11; found with
  `tools/scanflags.py`) are answered "not multiplayer" for the host. The guest watches the outro because his game starts the boss
  area's FinishEvent itself (`MulticastExecuteFlowDiagramWithCallback(3)`, the same path the intro uses). Skipping works.
- The memory is run by `MuseumUtilityManager` / `MuseumUtilityActor` (its start logic is Denuvo-VM code). It hung on a global
  counter `NumInCharacterSetupBeforeAppBeginPlay` ([0x14413C404], with a "blocked until frame" value at [0x14413C410]): characters
  wait for AppBeginPlay until it is 0, and in co-op it never reached 0, so the host's memory character never started (tick not
  registered, appear unfinished, loading screen). CoopNative resets it once 2 s into the memory (and skips the engine check on
  the later underflow); the host then plays the memory normally.
- Not yet: the guest runs his own copy of the memory and its scenes (out of sync, his own story flags: boss/fog wall stay on his
  side); next is one source (block his own memory, mirror the host's scenes, his pawn walking along or the spectate camera), story
  progress for the guest (CoopProgress), then vestige restoration.

Fixed 2026-10-30: the guest's game crashed at a Mistle (inside UE4SS) because a Lua loop asked every `HumanContextComponent`
for its owner, including half-destroyed ones of replaced characters; his own component now comes from his character directly.
Lua session polls pause during a map travel (a poll during a join crashed the game). Pure log hooks are opt-in
(`diag_hooks=1`); startup hooks are enabled in one batch (about 0.2 s instead of 7 s).

In progress: vestige restoration (the entry checks in the restoration code are answered "not multiplayer"; to test), the
guest's rest resetting enemies, the memory for the guest (plan: he leaves for the memory, plays it solo with control in his own
world, and rejoins), Home Base mode for the guest (`CharacterHelper.SetRestrictedActionInBaseInfo`), 3+ players, a teleport vote.

Diagnostics: CoopNative logs a freeze watchdog report when the game thread stops for 8 s; `tools/threadstacks.c` samples a running
process's thread stacks (hangs that are not freezes), `tools/memread.c` / `tools/memwrite.c` read and write a running test copy's
memory, `tools/minidump.py` reads crash dumps, `tools/findwrites64.py` finds code that writes a global, `tools/scanflags.py` finds
`IsOnlineMultiplay` checks followed by flag compares. A `bosshp1` CoopProbe command sets a running boss fight to 1 health (tests).
Guest progression and shared boss rewards: see issue #1 (CoopProgress).

## Contributing

Pull requests welcome. Session, rejoin and spectate code is actively changing here; please coordinate in an issue first.
Anything that writes to a player's save must be off by default and back the save up first. Never commit game files, saves,
logs or anything that identifies your machine.

## License

MIT (see `LICENSE`). MinHook (`native/third_party/minhook`) is BSD 2-Clause.
