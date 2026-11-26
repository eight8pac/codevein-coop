# Code Vein seamless co-op (work in progress)

Mods that turn Code Vein (2019) co-op into one continuous session. The guest stays with the host through the deaths and boss
kills that end a vanilla session: a dead guest spectates and comes back at the host's rest, the group teleports together, both
play the boss, its outro and the memory, and the guest's story progress, world state and blood codes follow the host's. Co-op also
works in areas whose boss is dead. Automatic re-hosting and re-joining remain as a fallback when a session does break.
**Not a release**: tested by hand on two PCs (and on one PC, see below), one guest (vanilla cap). Cutscenes are still rough. Home
Base works together, and leaving and returning together work most of the time (see Home Base below). Mistle teleports are voted on
by everyone (Elden Ring style) and keep the loading screen up until the destination is really loaded; walking between stages streams
the next one in for everyone (see Co-op fog and Teleport vote below). Resting resets the enemies as in single player, ground items
are per player (each player sees what his own save has not picked up), the map shows the host's icons, and vestige memories are
being made to play together (see Rest reset, Items per player and Vestige memories below). The loading crash "BitArrayIndex" is
fixed (load guard). A first packaged prototype (v0.258, 2026-11-25) was played from a New Game to the first boss with a friend; the
report and its fixes are under Playthrough fixes below. Players set the mod up in one file, `seamless_coop_settings.ini` (see Player
settings below).

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
   vestige_menu=1   both PCs: the Mistle menu sees "no signal" so its memory/vestige entries are enabled
   vestige_keep=1   both PCs: the companions' "Restore vestiges" is allowed in co-op and the restoration screen sees
                    "no session", so a memory keeps the session
   vestige_relay=1  both PCs: a restoration memory plays together (see Vestige memories)
   memory_vote=1    both PCs: everyone is asked before a restoration memory starts (the teleport vote's dialog)
   guest_vestige=1  guest: his own "Restore vestiges" is allowed in co-op (off: the game's own notice; his memory does not
                    play together yet)
   warp_coop=1      host: the purple Mistles (BP_WarpPortal) work with guests; the group teleport starts at the dialog's Yes
   guest_rest_full=0  switches off the full guest rest (Ichor, Regen, status effects, items; see Playthrough fixes)
   weapon_reshow=0  switches off showing the other player's weapon again after a cutscene
   guest_doors=1    both PCs: a guest can open doors (his press runs on the host's game for his character; untested)
   guest_mistles=1  both PCs: a guest can activate a Mistle; the host opens it in its world (untested)
   trig_census=1    log only: the interactable triggers near you in co-op and their button state
   test_commands=1  test copies: CoopProbe reads plugins\CoopProbe.cmd and the CoopCmd relay (off in a release kit)
   diag_trace=1     log only: callers of LIBDeferredTeleportManager:BeginDeferredTeleport
   rest_reload=1    host: a rest at a Mistle resets the enemies as in single player (every guest within 40 m)
   item_own=1       both PCs: ground items per player (the guest spawns his own copies; the host sends its story-gated items)
   map_mirror=1     both PCs: the guest's map shows the icons shown on the host's map
   vote_home_base=1 host: the teleport vote also covers Home Base
   depths_block=1   host: teleports into the Depths are refused (a crash once; to be retested)
   auto_continue=1  test copies: the title logos are closed and Continue is called directly (no simulated input)
   load_guard=0     switches the load guard off (it is on by default: see Load crash)
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
4. Everyone in the group uses the **same matchmaking password** (the game's option, or `cooperative_password` in the settings
   file below); the automatic search joins the first matching signal.
   Proposal, all off in `mods/CoopSeamless/config.txt`: `sessiondiag=1` (log the search/join signatures and the info
   string of each signal found; on two PCs it was the lobby ID), `remember=1` (role and
   host kept in `state.txt` across a crash or restart; a `state.txt` written by another player, e.g. inside a kit zipped from
   the host's folder, is ignored), `versioncheck=1` (the host sends his kit number from `plugins\CoopKitVersion.txt` and a
   fingerprint of the three Lua mods, the guest logs what differs). Solo offline test (2026-11-04): the signatures are
   logged; `remember` restores host mode from a `state.txt` with our own name and ignores one written by another player.
   Guests still join through the distress signal; no Steam invite is used.

5. **Player settings** (optional): copy `seamless_coop_settings.ini.example` into `Win64` as `seamless_coop_settings.ini`. It is
   the one file players edit: password, automatic host and join, votes, rewards and difficulty, each line explained in the
   file. At every start CoopNative writes its on/off choices into `plugins\CoopNative.ini` and the two `config.txt` files
   before anything reads them (only the lines a setting owns; each change is logged); the password and the difficulty are read
   by CoopSeamless and CoopProbe from the file itself. An unedited file changes nothing.

Uninstall: remove the two mod folders, `winmm.dll`, `plugins\` and `seamless_coop_settings.ini`.

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
  replication; a recording with our visibility mirror off showed both PCs matching at join and after a boss. Side-quest NPCs are the
  exception: they decide their visibility on each PC, so the guest saw other stages of a quest as extra, unusable NPCs (Home Base
  first, later also in stages). The mirror covers side-quest NPCs in Home Base, and with `subquest_mirror=1` everywhere.
- Online, the host holds every character in setup until each guest has reported it (`0x145DA0600`). Home Base NPCs never got that
  report, which also held the host's arrival, so story NPCs take the solo setup during the trip.
- UE4SS's hook dispatcher walks `FFrame::OutParms` of the calling Blueprint frame, and from some NPC scripts that list has a bad
  link: endless loop or access violation. So nothing Blueprints call on a conversation may be hooked from Lua.
- Works (two PCs, 2026-11-07 to 11-09): the guest's weapon, veil and face mask are hidden there; both players sit (the guest's seats are
  switched on for him: the host-only button check is hooked at run time), see each other sit, stand up and turn the head; a seat that
  is taken is closed for the other player until its sitter is up; the jukeboxes are synced both ways and their menu stays on the
  right screen; the piano plays both ways (CoopNative hooks the sound call, the other PC plays the notes after a short buffer, and
  both hands follow: the game flips `IsPianoPlay` / `IsPianoPlay2` per press); the story bulletin board is switched on for the guest.
- Leaving Home Base together works: the host brings the levels of the stage up itself (the game asks for none while a guest is
  connected), both stay behind a black screen until every stage level is shown and `K2_FindFloor` finds a floor under each character,
  the guest only after he has said so (the host's release is replicated and cannot wait for his PC). Returning has its own black
  screen until all Home Base levels are shown and a floor is found. A character that really falls (falling mode, faster than 15 m/s)
  15 m below its hold within 20 s of the release is put back (fall rescue; ladders use the same movement mode as the hold, so mode
  alone triggered it on a ladder). Levels being shown is not the same as collision being there: this caused several falls.
  The holds start 1.2 s after the fade begins, and the guest's screen stays covered until the host tells him it let go
  (`ClientMessage("CoopHBFree")`): his own release came a moment earlier and showed him floating (2026-11-12, untested).
- Co-op fog: each area boundary has a `BP_BarrierWall` (`ForMultiplay` walls named `*_Multi`, mist and collision only) that
  switches on when a player comes within roughly 70 to 90 m; the field table (`FieldMeta_Full`) gives every story field `Reached_*`
  as its multiplayer flag and `Boss_*` as the flag that prohibits hosting. `fog_open` switches the walls off on both PCs and
  `fog_free` skips the area-entry end of co-op, so both players can walk into the next stage (works). That stage does not stream
  in for the guest (he sees nothing behind the tunnel), and on 2026-11-10 not for the host either.
  Why (2026-11-12): `WorldSettings.bUseClientSideLevelStreamingVolumes` is false, so in Unreal only the server evaluates level
  streaming volumes, for every player's view, and tells each client what to load (`ClientUpdateLevelStreamingStatus`); a guest's
  own volumes do nothing. In co-op the volumes beyond the walls are switched off. An `AAppLevelStreamingVolume` is disabled
  (bit 1 at +0x3C8) when `(+0x3E0 bAutoEnableFromFirstSpawnToQuitGame && !+0x3F8 enabled) || +0x3F9 force-disable ||
  IsAllForceDisabled()` (`SetForceDisableAll`, impl 0x14068AE50; called with true from 0x146FD1333, with false at world start and
  from MainGame's level script). `fog_stream` (host only, untested) has CoopNative switch the volumes under every player back on
  (`lsvon`) and logs the raw flags and every `SetForceDisableAll` call, so the engine streams for both players and tells the guest.
  Forcing `LevelStreaming` flags directly (tried 2026-11-10) hung rests and teleports and never reached the guest: direct flag
  writes skip the server's notification of the clients.
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
  The force needs his pawn first on `CoopNative.protect`; with `keep_dying=0` that list was empty outside boss fights and the
  level-up silently failed (2026-11-06 to 11-11). His pawn now goes first while his Mistle menu is open, and he tells the host
  (guest -> host message kind 15), whose list then holds his pawn too, so the host's copy levels up at once (works, 2026-11-12).
- `group_teleport` (works, also into a completely different stage): a Mistle teleport is not a move but
  `CheckPointUIComponent:RequestPlayerSpawnToCheckPoint`, a fresh spawn at the target (the world is one map with streamed stages).
  It ends co-op twice: `SwitchToEndCoop` from 0x146678D02 (with an "ending co-op / distress signal" message shown by
  0x14083A630 just before) and, on entering a stage where multiplayer is off, from 0x146D627CF plus a second step 0x1409F1BA0
  ("multiplayer is not possible in this area"). With those vetoed or skipped, the host arrives (CoopNative sees the characters
  re-spawn) and the guest is spawned next to him with `RequestPlayerSpawn`. The guest gets the game's own teleport fade: the host
  sends `PlayerController:ClientMessage("CoopTeleportFade")` (a client RPC, used as a host -> guest channel) at the start, the
  guest's CoopNative calls `RequestTeleportFade(ctx, ctx, 48, 0)` like the vanilla teleport and unfades once he is next to the
  host. Home Base (FieldID 0) is part of the same map; `teleport_skip_fields=0` would keep the vanilla behaviour for it.
  With `tp_loading` the guest gets black, then the game's join loading screen (`UIHelper::RequestLoadingFade`, usage 64
  LongLoading, the screen he sees when answering a distress call), then black again and the normal fade-in once he is next to
  the host (works, 2026-11-12). The host decides and tells him (`ClientMessage("CoopFadeMode:64")`). With `tp_anim` he plays the
  host's Mistle-teleport montages too (`AM_TStdUnisex_TCmn_TriggerAc_Checkpoint_Start` / `_End`) instead of the appear effect
  (untested). A variant that sent the guest through a new join after each teleport ("soft follow", `ClientTravel` to the host)
  was tried and dropped: he stayed on a black screen; the guest now always stays in the session.
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

Walking from one area to the next together (the "airlock", switches `airlock=1`, `airlock_overlap=1`, `wall_settle=1`,
`gwall_mirror=1`, `airlock_resettle=1`): in co-op the game skips its own area streaming entirely. CoopNative answers "not
multiplayer" to exactly that caller (`fieldstream 1`) while every player stands in the tunnel zone that reaches into the next area,
so the game loads and unloads areas and opens its own loading walls as in single player, and closes it again once everyone is in one
area and the streaming has settled. Each PC switches the co-op walls only after its own level streaming has settled, the host's
own loading walls are mirrored to the guests, and chest loot is shared only on a real opening (`Server_SetChestState(Opening)`).
Mistle group teleports hold the guest's old character in the air until his new one arrives (`tp_hold=1`), and a jammed setup lock
after the arrival is reset (`lock_reset_tp=1`). Tested on 11-13 and 11-17: area 2 to area 1 and back several times, area 1 to area 3.
Since 11-18 the guest sees the fog in front of him (`fog_visual=1`) and it fades out slowly as in single player (`fog_fade=1`).
Open: a player left behind when the other runs ahead (parked), and the engine assert "BitArrayIndex < NumBitArrayIndex" (see Open below).

Teleport vote and teleport gate (11-18, `teleport_vote=1`, `tp_gate=1`):
- Whoever picks a Mistle in the menu proposes the teleport; CoopNative holds it (`RequestPlayerSpawnToCheckPoint`'s implementation
  returns early) and everyone else gets the game's own yes/no dialog (`UIHelper:OpenGeneralYesNoDialog`, `WDT_YesNoDialog_C`) with
  "<name> wants to travel to <Mistle> (<area>)." from the game's checkpoint list. The choice is read natively at
  `DialogBase:DecideSimpleOption` (UE4SS hooks on menu functions crash the game). All accept: the host teleports and the group
  follows; a decline or 30 s without an answer cancels it, with a popup naming who declined. The guest's Teleport entry is enabled.
- Cause of "landing in nothing" after returning to an area: in co-op the game switches its level-streaming volumes off; the airlock
  closed them for every teleport, so levels that were still loaded but hidden were never shown again. Now the game's loading screen is
  kept (its unfades are held back) from the teleport start, the guests' held characters are moved (hidden) to the host, the zone
  streaming runs, and the loading screen lifts only when every level of every streaming volume under the host is loaded and shown and
  nothing streams any more. The guest's own loading screen waits for the levels under his new character in the same way. No timers
  decide this; a 110 s cap is only a last resort.
- Also: the guests are hidden while held at the teleport start, the health bonus is refilled after a teleport, a fast arrival into an
  area that is still unloading is caught, and the "distress signal canceled ... disperse" notice (`MultiplayText_0580`, shown through
  0x1409D10B0) is skipped during a group teleport.

Items (11-18): chest loot is shared when the host opens a chest, without the earlier stall; enemy drops reach the guest (the game's
own `DropItemComponent` RPCs). The guest's own `Server_SetChestState` is dropped by his engine ("No owning connection"); CoopNative
now catches that log line (FMsg::Logf_Internal through a stub that only looks at the format pointer) and the guest relays the chest
to the host (`guest_chest=1`, untested). Ground items (`AFieldTriggerItemBase`) keep a per-player hold state and visibility; the
guest did not see the host's ones (solved later, see Items per player; `item_census=1` logs both sides).

Load crash (fixed 11-19, load guard, on by default): the engine assert "BitArrayIndex < NumBitArrayIndex" (Actor.cpp:88), on host
and guest, while an area loads. Every actor has a lazily built component index table cached at `AActor+0x2B0` (one byte per trait,
160 traits, at most 63 traits shared by two or more components); in every crash an enemy's table reached 64 while it was still
being deserialized (`FAsyncPackage::EventDrivenSerializeExport`). The cause was our own game-thread probes: they touched enemies
that were still being loaded. Every `FindAllOf` / `FindFirstOf` in the mods now leaves out objects the engine still builds or
removes (`RF_NeedInitialization`, `RF_NeedLoad`, `RF_NeedPostLoad`, `RF_NeedPostLoadSubobjects`, `RF_BeginDestroyed`,
`RF_FinishDestroyed` and the internal loading / unreachable / pending-kill flags); `load_guard=0` in `CoopNative.ini` switches it off.
The fall-death scream (`UDeathComponent.FallDeathVoice`) is played only on the falling player's PC; `fall_voice=1` plays it on the
other PCs too.

Rest reset (11-21 to 11-22, `rest_reload=1`, host): alone, every rest reloads the area's `_Enemy` levels from disk, which is the
complete reset (positions, aggro, the killed ones back). Online the zone streaming asks `IsOnlineMultiplay` (caller `0x146D36F21`)
and skips it. At the rest (session event `0x16` from the Mistle's input) CoopNative answers "single player" to that one check until
CoopProbe has seen the enemy levels unload and come back. The host allows it only when every guest is within 40 m and his game has
finished the last reload (it reports done/busy), so two rests in a row work too. The earlier enemy-kill overrides are retired
(`rest_reset_overrides=1` brings them back).

Map icons (11-22 to 11-24, `map_mirror=1`): an icon is `AFieldTriggerBase.bShouldBeVisible`; icons follow the unlocked map areas
(`RadarScene.RepAreaOpenedData`, replicated from the host) and the object's own state; there is no per-object "discovered" save
flag. The host sends the keys of the icons shown on its map (`ClientMessage("CoopMapIcons:...")`) and the guest's game switches them
on; his item copies (below) carry the icons of their level items. The guest's own map from his save is parked.
The teleport vote also covers Home Base (`vote_home_base=1`); Depths destinations are refused while `depths_block=1`.

Items per player (11-23 to 11-24, `item_own=1`): the level items belong to the host's game; on a guest they stay hidden and inactive
and their button check asks "is this the server". Enemy drops always worked, because each game spawns its own drop. So each guest's
game spawns its own drop-style copy of every level item his save has not picked up (`GameplayStatics:BeginDeferredActorSpawnFromClass`,
`SetDropItem(true)`, `FinishSpawningActor`), keeps the level item hidden, and when his copy is taken marks the level item as picked up
in his own save (`HoldState` flag + its save event). A player sees what his own save still has, and picking an item up does not take
it from the other player. Items the host's story still keeps hidden (a vestige that appears after a boss) are sent by the host
(`ClientMessage("CoopItemGate:...")`) and not copied until the host shows them.

Quick start for tests (11-23, `auto_continue=1`): the title logos are closed (`BP_TitleCreditUIComponent:Close`), Online is chosen
(`TitleMenuUIComponent:SetSelectedAppNetworkMode(0)` + `RequestAppNetworkModeDecision`) and Continue is called
(`RequestContinue`); no simulated input. `boot_trace=1` logs the first calls of the exec functions listed in
`plugins\CoopNative.tracelist` (object, calling script function, locals) to find such paths.

Vestige memories (11-24, in progress, `vestige_menu`, `vestige_keep`, `vestige_relay`, `memory_vote`, both PCs):
- "Restore vestiges" is an option of the companions' talk menus (`BP_Scenario_Base01_<Io|leda|cyllene|thebe|themisto|relics>_Menu`);
  each asks `IsOnlineMultiplay` once and shows "This feature is unavailable when playing in multiplayer mode". CoopNative answers
  false for those classes, matched by class name index (sent once at start; looking the classes up by path every few seconds crashed
  a guest at his join while the classes of his old world were removed). The restoration screen sees no session.
- A restoration's memory is no `PlayMemoryResidue`: the screen sends the restorer through a deferred teleport
  (`DeferredTeleportDriver`) into the memory area (`/Game/Cinematics/MemoryDen/...`) with a new character, and through another one
  back. The other PC loads the memory level through the streaming mirror, but his character stayed behind and fell at the start and
  at the end (first test).
- The host's game now treats its restoration teleport like the post-boss memory: the memory state for the guests (they follow on
  skips, finished scenes and when the game moves the host more than 15 m at once; a guest who dies there respawns next to the host),
  and on the way in and out the guests are held in the air and brought next to the host's new character.
- The vote (`memory_vote=1`, 11-25) comes before anything starts: in co-op "Restore vestiges" first keeps the game's own answer (its
  notice; the menu stays open) and everyone gets the teleport vote's dialog; once everyone agreed (valid for 2 minutes) choosing it
  again opens the screen. Two earlier ways failed: the restoration teleport's own pause token (`DeferredTeleportDriver:BPKeep`)
  did not hold it, and holding the confirm's decision froze the game (never swallow a dialog decision). The memory state is armed at
  the restoration's own session check, before its teleport, so the guests' loading screen comes with the host's. Tested 11-25 on two
  PCs: the host's restoration memory together, the vote both ways.
- A guest's own restoration is a museum on his PC only (`MuseumUtilityManager`: `SetPlaceToGoBack`, `FinishCurrentMuseum`,
  `SkipCurrentMuseum`) and hangs on his loading screen; until the host plays it as well, `guest_vestige` (off) keeps the game's own
  notice for a guest.

Purple Mistles (`warp_coop=1`, 11-25, tested on two PCs): `BP_WarpPortal` asks three co-op checks (`IsOnlineMultiplay`,
`MultiPlayersCheck` twice) at its prompt, its press, the "move to the corresponding point" dialog's Yes and the step after it; they
answer "not multiplayer" for the host there, and the group teleport starts at the dialog's Yes. If the host has not moved 8 s later,
the guests get `CoopTeleportCancel` and their screens come back. The Depths worked with `depths_block` off (11-25).

Prototype v0.258 (11-25): one zip with UE4SS, the ASI loader, CoopNative and the three Lua mods, and one `CoopNative.ini` for both
players: host-only and guest-only switches turn themselves off by the role in the session (CoopProbe writes `CoopNative.role`).
Test switches and the command file are left out (`test_commands`).

Playthrough fixes (11-25; the first New Game run with a friend, to the first boss):
- The prologue's injured walk was gone: CoopProbe's special-mode reset (meant for the memory mode a guest's character keeps after a
  memory) also cleared the game's own modes on a solo character. It now clears only the memory mode, and only in a session.
- A guest's rest restored health only. It now also sets Ichor to its maximum, gives the Regen charges back, clears status effects and
  tops items up from storage (`CharacterHelper` `SetIchor`, `ResetRegenerationUsageCount`, `ClearAllCondition`,
  `ItemComponent:ReplenishItemsFromStorage`), and keeps health and Ichor full while his Mistle menu is open, so a level-up there
  ends at full health.
- The other player's weapon stayed invisible after cutscenes: 2 s after the last level sequence stopped, every other player's
  character gets the game's weapon-visibility call again (`CharacterHelper:OnAnimNotifyStateChangeVisibilityOfWeapon`).
- A guest who said yes to Louis's follower offer was left on a black screen: two shared talk/menu checks were answered "not
  multiplayer" by the vestige override at any time. They are answered only while a restoration runs now; other talks get the game's
  own co-op answer.
- Doors and Mistles for a guest (`guest_doors`, `guest_mistles`, 11-26, untested): his greyed prompt at a closed door or a Mistle
  that is not open is switched on (their button checks are hooked at run time per class and answer yes for the triggers near
  him). A door press is noted by a hook on the door's own input and sent to the host, whose game runs the door's input for the
  guest's character (`ProcessInputButtonEvent`), so the door's own checks, animation and save run there; if only the guest's game
  opened it, the host opens it 2 s later (`OpenImmediate`). A press at a Mistle that is not open does not run on the guest's PC
  (its activation has host-only parts, like the rest); the host opens it in its world (`OpenImmediate`, `Multicast_InitState` for
  every PC, its save event). Doors and Mistles opened in co-op are saved in the guest's own world by the progress mirror.
- Open: the vestige after the first boss waits on the guest's PC for the host's side (`WaitForOnlineMultiplaySynced`), and the
  host could use it only after the guest left.

Player settings (11-25, first version): `seamless_coop_settings.ini` in `Win64`, sections `[Session]` (`cooperative_password`, set as
the game's own matchmaking password through `ConfigurationManager`; `auto_host` / `auto_join` = auto, always or off;
`remember_session`), `[Votes]` (`teleport_vote`, `memory_vote`), `[Rewards]` (`shared_boss_rewards`, `guest_story_progress`) and
`[Difficulty]` (enemy and boss health and damage, percent added per extra player; host only: health through
`CharacterHelper:SetDefaultMaxHealth` with the share of health kept, damage through the enemy's `AttackScale`, the game's values
back when the guests leave). The file reader is tested offline on copies of the kit files; the password and the difficulty are
not tested in the game yet. A player cap above 2 is not in it: the cap sits in the obfuscated session code.

Testing on one PC: a second Steam client runs in a Sandboxie-Plus box, logged in with a second Steam account that owns or borrows
the game, and starts a second, hard-linked test copy as the guest (`tools/start-guest-box.ps1`). Each copy has its own Steam account
and license; no Steam emulator, no `-nosteam`, no patched executable. The box keeps both the Steam client's and the game's
single-instance checks apart. The guest copy needs its own ports (`-port=7787 -QueryPort=27025`): the game also starts a Steam game
server, and with the host copy running the guest's Steam start failed and fell back to offline mode. Start it with its own folder as
the working directory, or Steam restarts the game from the library install.

Diagnostics: CoopNative logs a freeze watchdog report when the game thread stops for 8 s; `tools/threadstacks.c` samples a running
process's thread stacks (hangs that are not freezes), `tools/memread.c` / `tools/memwrite.c` read and write a running test copy's
memory, `tools/minidump.py` reads crash dumps, `tools/findwrites64.py` finds code that writes a global, `tools/scanflags.py` finds
`IsOnlineMultiplay` checks followed by flag compares, `tools/natreg.py` finds a native function's exec thunk from its registration
entry, `tools/scanoff.py` finds code that writes a member offset, `tools/vtfind.py` finds the vtables holding a function,
`tools/findlea.py` finds the code that uses a string or a global (RIP-relative LEA/MOV), `tools/minidump.py --deep` reads a crash
dump's whole stack (UE4's assert puts the failing site about 14 KB deep), `tools/mergelogs.py` merges host and guest logs into one
timeline on the host's clock, `tools/npccompare.py` compares the NPC census of both PCs. With `live_logs=1` the guest's CoopNative
mirrors his logs to the LAN share every 5 s while he plays, and the host sends its clock to the guests every 30 s.
CoopProbe commands: `bosshp1` sets a running boss fight to 1 health (tests), `lsvinfo` logs the streaming settings and volume
states, `montagewatch` logs the montages our character plays, `loadtest` shows and lifts the join loading screen, `wallsnear`
lists every barrier and fog wall within 80 m, `bring` moves the guests next to the host, `rec` takes an NPC census, and
`guest <command>` runs a command on every guest's PC (`guest native <command>` for CoopNative). The command file takes one
command per line. Test commands (results logged with "test:"): `t_status` (our character, players, enemies, the nearest Mistle),
`t_kill <n>` (host: the n nearest enemies die through the game's death path), `t_tp <fid> <pid>` (host: Mistle teleport, the vote
runs), `t_census` (map census), `t_call <class> <function>` (a function without arguments on the first object of a class),
`t_give <asset> [n]` (gives our character an item through `CharacterHelper:GetItemOrWeaponOrJinkaku`; test saves only),
`tp` (our character to `test_mark=X,Y,Z` from `CoopNative.ini`), `uidump` (every widget and the game widget classes' functions).
Guest progression and shared boss rewards: see issue #1 (CoopProgress).

## Contributing

Pull requests welcome. Session, rejoin and spectate code is actively changing here; please coordinate in an issue first.
Anything that writes to a player's save must be off by default and back the save up first. Never commit game files, saves,
logs or anything that identifies your machine.

## License

MIT (see `LICENSE`). MinHook (`native/third_party/minhook`) is BSD 2-Clause.
