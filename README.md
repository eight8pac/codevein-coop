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
   keep_outro=1     both PCs, research: a boss kill no longer sends the guest home (the host's outro then waits, see Status)
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
- `rest_in_coop`: the host rests at a Mistle with a guest connected; the guest stays. Enemies do not reset yet, and the partner
  NPC respawns per rest.
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
  re-spawn) and the guest is spawned next to him with `RequestPlayerSpawn`. The guest sees the world unload around him for a few
  seconds (fade to do). Home Base is a separate map: teleporting there this way drops the host into a pit.
- Falls (`keep_dying`): a fall now leads straight to spectating (no revive window): the host plays the dissolve and removes the body.

In progress: the post-boss outro with a guest connected (`keep_outro`: the boss intro and the outro start fine, but the host then
waits on a loading screen until the guest leaves; the outro's deferred-teleport driver is done, so the wait is in the large-poly
model loading before the memory; the boss blood code only comes after that memory), enemy reset on a co-op rest (works once per
session), resting together crashes, vestige restoration (menu entries enabled; the restoration screen still refuses), the guest's
Mistle menu while the host rests (crash), 3+ players, a teleport vote.

Diagnostics: CoopNative logs a freeze watchdog report when the game thread stops for 8 s, and `tools/threadstacks.c` is a
read-only sampler of a running process's thread stacks (for hangs that are not freezes).
Guest progression and shared boss rewards: see issue #1 (CoopProgress).

## Contributing

Pull requests welcome. Session, rejoin and spectate code is actively changing here; please coordinate in an issue first.
Anything that writes to a player's save must be off by default and back the save up first. Never commit game files, saves,
logs or anything that identifies your machine.

## License

MIT (see `LICENSE`). MinHook (`native/third_party/minhook`) is BSD 2-Clause.
