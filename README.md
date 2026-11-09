# Code Vein seamless co-op (work in progress)

Mods that turn Code Vein (2019) co-op into one continuous session. The guest stays with the host through the deaths and boss
kills that end a vanilla session: a dead guest spectates and comes back at the host's rest, the group teleports together, both
play the boss, its outro and the memory, and the guest's story progress, world state and blood codes follow the host's. Co-op also
works in areas whose boss is dead. Automatic re-hosting and re-joining remain as a fallback when a session does break.
**Not a release**: tested by hand on two PCs only, one guest (vanilla cap). Cutscenes are still rough, and opening chests and ground
items for the guest are in progress (see Status). Home Base works together, and leaving and returning together work most of the time (see Home Base below).

Findings, teardown table and QA live in the Co-op Anything write-up:
<https://github.com/cranebeaker/coop-anything/tree/main/games/code-vein>

Built for **Steam, version 1.53.93354** (exe SHA-256 `8fa550fe00a8c28c8947a9511128c21924860be0bb4ebf5a09b8a6cf50e0e172`).
CoopNative's addresses are fixed for that build; it checks 16 bytes at every target and skips any hook that does not match.

## Parts

| Path | What | Needed on |
|---|---|---|
| `mods/CoopSeamless` | UE4SS Lua mod: session handling, re-host / re-join as a fallback, co-op in beaten areas. Switches in `config.txt` | host and guests |
| `mods/CoopProbe` | UE4SS Lua mod: the co-op logic on top of CoopNative: group teleport, spectating, memory and cutscene relay, world and blood code sync, state log | everyone running CoopNative |
| `native/coopnative.c` | C DLL (MinHook detours), loaded by Ultimate ASI Loader: keeps the session alive, game-thread work, traces. Most parts are switches in `CoopNative.ini` | host and guests (for tests) |
| `mods/CoopProgress` | UE4SS Lua mod: logs boss rewards, progress flags and the story position; gives the guest the host's boss items and story progress, the host can publish its position (all **off** unless enabled in `config.txt`, save backed up first) | guests; host for publishing (logging: anyone) |
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
                    behaviour; Home Base (FieldID 0) streams like a stage and goes together with the group when not listed here
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
   Proposal, all off in `mods/CoopSeamless/config.txt`: `sessiondiag=1` (log the search/join signatures and the info
   string of each signal found; on two PCs it was the lobby ID), `remember=1` (role and
   host kept in `state.txt` across a crash or restart; a `state.txt` written by another player, e.g. inside a kit zipped from
   the host's folder, is ignored), `versioncheck=1` (the host sends his kit number from `plugins\CoopKitVersion.txt` and a
   fingerprint of the three Lua mods, the guest logs what differs). Solo offline test (2026-11-04): the signatures are
   logged; `remember` restores host mode from a `state.txt` with our own name and ignores one written by another player.
   Guests still join through the distress signal; no Steam invite is used.

Uninstall: remove the two mod folders, `winmm.dll` and `plugins\`.

## Build CoopNative

Needs [Zig](https://ziglang.org/download/) (0.17 used; its clang cross-compiles for Windows without Visual Studio):
`ZIG=/path/to/zig sh native/build.sh` → `native/build/CoopNative.asi`.

## Status

Works (two PCs): rejoin after guest field death, host death, boss-room death + wipe, boss kill; co-op in beaten areas.

Home Base together (two PCs, session kept):
- Both arrive, the NPCs match on both screens, and host and guest can talk to NPCs and shopkeepers; a guest got a blood code from
  an NPC on his own side. Tested with identical saves.
- How NPCs work: each area's `ScenarioProgressLoader` picks a layout from the story flags on each PC (only Home Base rolls at random;
  the pick is fixed here so both PCs load the same one). In a normal area the host's result reaches the guest by the game's own
  replication; a recording with our visibility mirror off showed both PCs matching at join and after a boss. The mirror now only
  covers side-quest NPCs in Home Base, whose replicated value does not reach the guest there (reason unknown).
- Online, the host holds every character in setup until each guest has reported it (`0x145DA0600`). Home Base NPCs never got that
  report, which also held the host's arrival, so story NPCs take the solo setup during the trip.
- UE4SS's hook dispatcher walks `FFrame::OutParms` of the calling Blueprint frame, and from some NPC scripts that list has a bad
  link: endless loop or access violation. So nothing Blueprints call on a conversation may be hooked from Lua.
- Works (two PCs, 2026-11-07 to 11-09): the guest's weapon, veil and face mask are hidden there; both players sit (the guest's seats are
  switched on for him: the host-only button check is hooked at run time), see each other sit, stand up and turn the head; a seat that
  is taken is closed for the other player until its sitter is up; the jukeboxes are synced both ways and their menu stays on the
  right screen; the piano plays both ways (CoopNative hooks the sound call, the other PC plays the notes after a short buffer, and
  both hands follow: the game flips `IsPianoPlay` / `IsPianoPlay2` per press); the story bulletin board is switched on for the guest
  (untested when this was written).
- Leaving Home Base together works: the host brings the levels of the stage up itself (the game asks for none while a guest is
  connected), both stay behind a black screen until every stage level is shown and `K2_FindFloor` finds a floor under each character,
  the guest only after he has said so (the host's release is replicated and cannot wait for his PC). Returning has its own black
  screen until all Home Base levels are shown and a floor is found. A character that falls 15 m below its hold is put back (fall
  rescue). Levels being shown is not the same as collision being there: this caused several falls.
- Co-op fog (surveyed, not opened yet): each area boundary has a `BP_BarrierWall` (`ForMultiplay` walls named `*_Multi`, mist and
  collision only) that switches on when a player comes within roughly 70 to 90 m; the field table (`FieldMeta_Full`) gives every
  story field `Reached_*` as its multiplayer flag and `Boss_*` as the flag that prohibits hosting.
- Not done: the guest's seat camera (the camera never follows his mouse), the appearance editor for the guest (he gets a missing
  character and a permanent loading screen), and syncing a changed appearance.

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
  host. Home Base (FieldID 0) is part of the same map; `teleport_skip_fields=0` would keep the vanilla behaviour for it.
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

Added 2026-10-31 (ideas from studying other seamless co-op mods): a game-thread pump on `UGameEngine::Tick` (0x14EBE3C20)
instead of a polled function; a line-based command queue (`CoopNative.cmd`); a scene relay (`RequestEvent` / `RequestSkipEvent`
are logged on both PCs, the host sends skips and the memory start/end to the guest with `ClientMessage`, so the guest's copy of the
outro and memory scenes stays in step with the host's skips); automatic log collection on each PC (`plugins\CoopLogs\`, a zip of
the previous run's logs and any new crash report, made at the next start; nothing is uploaded).

Memory with a guest, current state (two-PC tests 2026-11-02): the guest walks in the host's memory. His memory character stayed
before AppBeginPlay on his own PC (same counter problem as the host's); a reset on his side starts it, and characters that do not
run on his PC get their tick switched back on. The host's skips are relayed to him, pull him next to the host inside the memory,
and his own skips are ignored in co-op. After the memory he is brought to the host only when the host's final cutscene is over
(spawning him at the cutscene spot killed him). Remaining: a few janky seconds at the memory start, his game picks its own
post-boss ending branch (story progress, see CoopProgress), and the lock-counter resets could underflow (counters are now kept
from going below 0; a crash with "BitArrayIndex" in Actor.cpp was the symptom).

Story and world sync with a guest (two-PC tests 2026-11-03): CoopProgress (by Rikka230) moves the guest's story position to the
host's; on top of that the host sends every story flag that turns true and, when a guest joins, its whole flag state (BoolMap
and ValMap; item and weapon pickups stay per player), all through the game's own co-op symbol sync. The guest sets the boss's
success flag at the kill, so his post-memory ending matches the host's. The host mirrors the story visibility of scenario and
side-quest NPCs and the state of mist walls by name (`ClientMessage`), the guest's boss door is removed after the kill, and new
blood codes the host gets are unlocked for the guest (`AcquireBloodCode`, with the game's message). A lock-counter underflow
that crashed the engine ("BitArrayIndex", Actor.cpp) is prevented where the failing check sits. Still open: the guest's
`CheckGameProgress` answers differently from his synced flags (being traced), cutscene polish, chests/items, NPC interaction.

LAN helpers (`tools/lan`): an optional Windows share on the host (`setup-coopdrop.ps1`, one local user, private networks only) that
receives the guest's log zips (made automatically when his game ends, also after a crash) and offers new guest kits;
`Start Code Vein Co-op.cmd` installs a newer kit from that share before starting the game through Steam.

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
