// CoopNative: native (C) hooks for the Code Vein co-op project, loaded by Ultimate ASI Loader (winmm.dll proxy).
// Probe stage: inline MinHook detours. GetRescueSignalState (exec thunk) logs state changes; the session state-machine
// handler logs every internal event with a backtrace and can veto event 0x1F (only when explicitly enabled, see below).
// A command file lets Lua ask for memory reads (vtable lookups) that UE4SS Lua cannot do itself.
// The exe has no ASLR (DYNAMIC_BASE off), so UFunction exec thunk addresses from the UE4SS object dump are fixed.
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdint.h>
#include <share.h>
#include <string.h>
#include "MinHook.h"

#define ADDR_EXEC_GET_RESCUE_SIGNAL_STATE 0x140A04EC0ULL

static FILE *g_log;
static CRITICAL_SECTION g_log_lock;

static void logf_(const char *fmt, ...) {
    SYSTEMTIME t; GetLocalTime(&t);
    EnterCriticalSection(&g_log_lock);
    if (g_log) {
        fprintf(g_log, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
        fputc('\n', g_log); fflush(g_log);
    }
    LeaveCriticalSection(&g_log_lock);
}

// UE 4.18 exec thunk: static void execX(UObject* Context, FFrame& Stack, void* const Result)
typedef void (*exec_fn)(void *context, void *stack, void *result);
static exec_fn g_orig_get_state;
static volatile LONG g_calls;
static volatile LONG g_last_state = -1;

// Replay of a vetoed end (session 7): a guest held by the veto never retries leaving, so after a boss kill the host's outro waits
// for him forever. CoopProbe sends "replay" when the boss rewards arrive and its own character is dead; the vetoed call is then
// made for real here, on the game thread (Lua polls GetRescueSignalState from it), and only on the same session manager object.
typedef void (*endcoop_fn)(void *sm);
static void *volatile g_vetoed_sm;
static volatile LONG g_vetoed_kind, g_replay_pending;   // kind 1 = SwitchToEndCoop, 2 = EndCooperativeMode
static endcoop_fn g_orig_end_coop, g_orig_switch_end_coop;

// R4 stage 1 (vestige_menu=1): the Mistle menu WDT_CheckpointMenu_C disables its memory/restoration pieces whenever
// GetRescueSignalState(self) is not Idle. Answer Idle (0) only when the calling Blueprint frame's object (FFrame + 0x18) is of the
// menu's class (UObject + 0x10), whose address CoopProbe sends once ("menuclass <hex>"). A Lua hook on this function froze the game
// when the distress signal was sent (2026-10-27), hence native.
static volatile LONG g_vestige_enabled, g_vestige_overrides;
static volatile uintptr_t g_menu_class;
static int readable(uintptr_t a, size_t len);
static int from_menu(void *stack) {
    uintptr_t cls = g_menu_class;
    if (!cls || !stack || !readable((uintptr_t)stack + 0x18, 8)) return 0;
    uintptr_t obj = *(uintptr_t *)((uintptr_t)stack + 0x18);
    return obj && readable(obj + 0x10, 8) && *(uintptr_t *)(obj + 0x10) == cls;
}

// Guest level-up (R6, session 8). CheckPointUIComponent:LevelUpPlayer (thunk 0x140A842C0) -> 0x14099C350(context, UpLevel) fetches
// "the player character" with 0x141DF4530(context, 0) and sends it the level-up message (0x2c). On a guest that lands on his network
// copy: the haze goes, the level does not. So the host does it on the guest's character: the guest's game sends Server_AddExp(0) once
// per level (harmless), the host's CoopNative counts those from a component that is not its own and runs 0x14099C350 with the player
// lookup redirected to the guest's pawn (first address in CoopNative.protect) for the duration of the call, on the game thread.
#define ADDR_GET_PLAYER_CHAR 0x141DF4530ULL
#define ADDR_LEVEL_UP 0x14099C350ULL
#define ADDR_EXEC_SERVER_ADDEXP 0x140ADA400ULL
#define ADDR_EXEC_OTHER_PLAYER_NUM 0x140A04E10ULL   // AppOnlineWrapper::GetOnlineOtherPlayerNum exec thunk
#define ADDR_EXEC_IS_CREATE_SESSION 0x140A053D0ULL  // AppSessionManager::IsCreateSession exec thunk
#define ADDR_EXEC_SPAWN_TO_CHECKPOINT 0x140A846B0ULL  // CheckPointUIComponent::RequestPlayerSpawnToCheckPoint exec thunk
#define ADDR_EXEC_FINISH_BOSS 0x140A44990ULL
#define ADDR_EXEC_FLOW_DIAGRAM 0x140A448E0ULL   // BossAreaBase::MulticastExecuteFlowDiagramWithCallback(EBossAreaFlowDiagramType) thunk   // BossAreaBase::MulticastFinishBossBattle(bool bWithDisconnect) exec thunk
typedef void *(*getplayerchar_fn)(void *ctx, int index);
typedef uint8_t (*levelup_fn)(void *ctx, int uplevel);
static getplayerchar_fn g_orig_get_player_char;
static levelup_fn g_orig_level_up;
static volatile uintptr_t g_override_player;
static volatile DWORD g_override_tid;
static volatile uintptr_t g_levelup_ctx, g_levelup_pawn;
static volatile LONG g_levelup_n, g_levelup_pending, g_guest_levelups;
static volatile LONG g_levelup_relay;   // set from the ini in read_settings
static volatile LONG g_vestige_keep;    // vestige_keep=1: the restoration screen sees no session (R4 stage 2, session 9)
static volatile uintptr_t g_restore_class;  // BP_BCRestorationUIComponent_C class, sent by CoopProbe ("restclass <hex>")
static volatile LONG g_keep_outro;        // keep_outro=1: keep the guest through a boss kill (outro/memory work, sessions 8-10)
static volatile LONG g_guest_outro;       // guest_outro=1 (guest): play the outro along, block his own copy of the memory
static volatile LONG g_guest_mem_block;   // guest_memory_block=1: block the guest's own memory copy (step a); off = both run it (step 2)
static volatile LONG g_partner_override = 1;
static volatile LONG g_scene_wait = 1;   // scene_start_wait=0: scenes in the memory window start without waiting for the other player
static volatile ULONGLONG g_memory_start_at;   // PlayMemoryResidue seen (both PCs): option A answers the partner checks for 15 min
static volatile LONG g_memstart_tp = 1;   // memory_start_teleport=0: no group teleport of the guest at the memory start (step 2)   // outro_partner_override=0: the four "partner ready" answers off (session 10)
// Player 0 on the host (session 10): the museum (memory) asks GetPlayerController(ctx, 0) whether "the player" is ready and stayed
// "not ready" on the host while a guest was connected. If the host's controller list put the guest first, index 0 would be the
// guest. The host's own controller and pawn come from CoopNative.tpinfo ("host <pc>", then "host <pawn>"); every index-0 answer
// that is not the host's is logged (always) and replaced by the host's own (only with keep_outro).
static volatile uintptr_t g_host_pc, g_host_pawn;
static volatile ULONGLONG g_outro_at_early;   // mirror of g_outro_at (set later in the file) for the player-0 override window
static int g_outro_window(void) { ULONGLONG t = g_outro_at_early; return t && GetTickCount64() - t < 600000; }
static volatile LONG g_pc0_swaps, g_pawn0_swaps;
static volatile ULONGLONG g_last_pc0_log, g_last_pawn0_log;
#define ADDR_GET_PLAYER_CONTROLLER 0x141DF42C0ULL
typedef void *(*getpc_fn)(void *ctx, int index);
static getpc_fn g_orig_get_player_controller;
static void *detour_get_player_controller(void *ctx, int index) {
    void *r = g_orig_get_player_controller(ctx, index);
    uintptr_t host = g_host_pc;
    if (index == 0 && host && r && (uintptr_t)r != host) {
        LONG n = InterlockedIncrement(&g_pc0_swaps);
        ULONGLONG now = GetTickCount64();
        if (now - g_last_pc0_log > 2000) {
            g_last_pc0_log = now;
            logf_("player 0: GetPlayerController(0) = 0x%llX, not the host's 0x%llX (%ld times)", (unsigned long long)(uintptr_t)r,
                  (unsigned long long)host, n);
        }
    }
    return r;
}
static void *detour_get_player_char(void *ctx, int index) {
    if (g_override_player && index == 0 && GetCurrentThreadId() == g_override_tid) return (void *)g_override_player;
    void *r = g_orig_get_player_char(ctx, index);
    // 10-30 09:42: replacing the character by the host pawn from tpinfo returned a destroyed pawn (tpinfo lags behind the
    // cutscene's respawns) and crashed the host; the controller check showed index 0 is the host anyway -> no character check
    uintptr_t host = 0;
    if (index == 0 && host && r && (uintptr_t)r != host && readable(host, 8)) {
        LONG n = InterlockedIncrement(&g_pawn0_swaps);
        ULONGLONG now = GetTickCount64();
        if (now - g_last_pawn0_log > 2000) {
            g_last_pawn0_log = now;
            logf_("player 0: GetPlayerCharacter(0) = 0x%llX, not the host's 0x%llX (%ld times)%s", (unsigned long long)(uintptr_t)r,
                  (unsigned long long)host, n, g_keep_outro ? " -> host's returned (keep_outro)" : "");
        }
    }
    return r;
}
// The level-up check 0x140593A20(iface, N) also needs haze >= cost, and on the host the guest's copy has haze 0 (his haze lives on
// his PC; Server_AddExp on the host does not change the copy). During our relayed level-up (override active on this thread) the
// check is answered "yes"; his menu has already spent the haze on his side.
#define ADDR_LEVEL_CHECK 0x140593A20ULL
typedef uint8_t (*lvlcheck_fn)(void *iface, int n);
static lvlcheck_fn g_orig_level_check;
static uint8_t detour_level_check(void *iface, int n) {
    if (g_override_player && GetCurrentThreadId() == g_override_tid) {
        uint8_t real = g_orig_level_check(iface, n);
        if (!real) logf_("level check for the relayed level-up: real answer 0 (haze), answering 1");
        return 1;
    }
    return g_orig_level_check(iface, n);
}
typedef void *(*getiface_fn)(void *obj, void *cls);   // (also declared with the lvlinfo code below)
static volatile uintptr_t g_lvlinfo_comp[4];
static volatile LONG g_lvlinfo_pending;
// The level getter (base+0x90 = 0x1461074C0) returns the stored level only when 0x140456A00(owner) is true (authority-like);
// otherwise it derives the level from the player data. The setter (0x14634EB80) stores the new level and writes GetLevel() into
// the player data, so on the guest it wrote the old, derived level back (update 45). During our direct level-up on this thread
// answer true for the guest's own pawn, so the new level reaches his player data.
#define ADDR_IN_CHARGE 0x140456A00ULL
typedef uint8_t (*incharge_fn)(void *owner);
static incharge_fn g_orig_in_charge;
static volatile uintptr_t g_force_in_charge;
static volatile DWORD g_force_tid;
static uint8_t detour_in_charge(void *owner) {
    if (g_force_in_charge && (uintptr_t)owner == g_force_in_charge && GetCurrentThreadId() == g_force_tid) return 1;
    return g_orig_in_charge(owner);
}
static void run_levelup(void) {
    uintptr_t ctx = g_levelup_ctx, pawn = g_levelup_pawn;
    LONG n = InterlockedExchange(&g_levelup_n, 0);   // reset: the relay adds one per Server_AddExp(0)
    if (!ctx || n <= 0) return;
    if (pawn) {
        // relay from a guest: ctx is his HumanContextComponent in our world. The message path (0x14099C350) never reached the real
        // level-up (update 44/45), so call HumanContextIF 0x1405A2E20 directly; the check is bypassed (thread override) because his
        // copy has no haze here.
        void *ifcls = ((void *(*)(void))0x140AD6680ULL)();
        uintptr_t iface = (uintptr_t)((getiface_fn)0x140EBF6A0ULL)((void *)ctx, ifcls);
        if (iface && readable(iface, 8)) {
            // update 47 levelled him up on his side (his status showed the new stats) but his max HP bar stayed: the host's copy
            // still had the old level. Set it here with the setter (base+0x88) while 0x140456A00 is forced true for his pawn (so
            // the setter's GetLevel uses the new value), then recompute his stats (base+0xB8 -> base+0xA0) like the level-up does;
            // no haze is spent here, he paid on his side.
            uintptr_t base = iface - 0x368, bvt = *(uintptr_t *)base;
            g_force_tid = GetCurrentThreadId(); g_force_in_charge = pawn;
            int lvl = ((int (*)(void *))*(uintptr_t *)(bvt + 0x90))((void *)base);
            ((void (*)(void *, int))*(uintptr_t *)(bvt + 0x88))((void *)base, lvl + (int)n);
            uint64_t st = ((uint64_t (*)(void *))*(uintptr_t *)(bvt + 0xB8))((void *)base);
            ((void (*)(void *, uint64_t))*(uintptr_t *)(bvt + 0xA0))((void *)base, st);
            int after = ((int (*)(void *))*(uintptr_t *)(bvt + 0x90))((void *)base);
            g_force_in_charge = 0;
            logf_("levelup (host, set): guest component 0x%llX level %d -> %d (stored, read while forced: %d)", (unsigned long long)ctx, lvl,
                  lvl + (int)n, after);
            g_lvlinfo_comp[0] = ctx; InterlockedExchange(&g_lvlinfo_pending, 1);
            return;
        }
    }
    if (pawn) { g_override_tid = GetCurrentThreadId(); g_override_player = pawn; }
    uint8_t r = ((levelup_fn)ADDR_LEVEL_UP)((void *)ctx, (int)n);
    g_override_player = 0;
    logf_("levelup: +%ld level(s) for %s0x%llX -> %u", n, pawn ? "pawn " : "the local player via ", (unsigned long long)(pawn ? pawn : ctx), r);
}
// Resync after the guest's Mistle menu: the join-time sender is stub 0x140465CA0 -> 0x145DC5E40(character) ("SyncAll": the
// character's ServerInitialDataSync via 0x1404634D0, which sends only while +0xB82 (bIsInitialSynced) is clear, then every component).
// CoopProbe clears the flags and sends "syncall <pawn>"; the call is made here on the game thread.
#define ADDR_SYNC_ALL 0x140465CA0ULL
static volatile uintptr_t g_syncall_pawn;
static volatile LONG g_syncall_pending;
static volatile LONG g_seatcam_pending;
static volatile uintptr_t g_seatcam_pc, g_seatcam_pawn;
static volatile LONG g_vols_pending;
static void run_volcheck(void);
static void run_syncall(void) {
    uintptr_t pawn = g_syncall_pawn;
    if (!pawn) return;
    ((void (*)(void *))ADDR_SYNC_ALL)((void *)pawn);
    logf_("syncall: initial data sync sent again for 0x%llX", (unsigned long long)pawn);
}
// Level-up check (session 8 research): the HumanContextIF level-up 0x1405A2E20(iface, N) refuses when its check 0x140593A20 fails:
// base = iface - 0x368; level = base->vt[0x90](), max = base->vt[0x98](); level + N <= max; cost = iface->vt[0x138](level + N)
// (float, != 0); exp = iface->vt[0x118]() >= cost. "lvlinfo <component> [component ...]" logs those values for each
// HumanContextComponent, on the game thread. The interface pointer comes from 0x140EBF6A0(component, HumanContextIF class 0x140AD6680()).
static volatile uintptr_t g_lvlinfo_comp[4];
static volatile LONG g_lvlinfo_pending;
typedef void *(*getiface_fn)(void *obj, void *cls);
typedef int (*int0_fn)(void *self);
typedef float (*fint_fn)(void *self, int x);
static void run_lvlinfo(void) {
    void *ifcls = ((void *(*)(void))0x140AD6680ULL)();
    for (int k = 0; k < 4; k++) {
        uintptr_t comp = g_lvlinfo_comp[k];
        if (!comp) continue;
        g_lvlinfo_comp[k] = 0;
        uintptr_t iface = (uintptr_t)((getiface_fn)0x140EBF6A0ULL)((void *)comp, ifcls);
        if (!iface || !readable(iface, 8)) { logf_("lvlinfo 0x%llX: no HumanContextIF", (unsigned long long)comp); continue; }
        uintptr_t base = iface - 0x368;
        uintptr_t ivt = *(uintptr_t *)iface, bvt = *(uintptr_t *)base;
        int level = ((int0_fn)*(uintptr_t *)(bvt + 0x90))((void *)base);
        int maxl = ((int0_fn)*(uintptr_t *)(bvt + 0x98))((void *)base);
        float cost = ((fint_fn)*(uintptr_t *)(ivt + 0x138))((void *)iface, level + 1);
        int exp = ((int0_fn)*(uintptr_t *)(ivt + 0x118))((void *)iface);
        logf_("lvlinfo 0x%llX (iface 0x%llX, base 0x%llX = comp+0x%llX): level %d, max %d, cost(level+1) %.0f, haze %d", (unsigned long long)comp,
              (unsigned long long)iface, (unsigned long long)base, (unsigned long long)(base - comp), level, maxl, cost, exp);
    }
}
static int read_small_file(const char *name, char *buf, size_t size);
static uintptr_t first_protected(void) {
    char buf[128];
    if (!read_small_file("CoopNative.protect", buf, sizeof buf)) return 0;
    return (uintptr_t)strtoull(buf, NULL, 16);
}

// End the death fade after a group respawn (session 8). The native trace showed a death's input lock belongs to the guest's own
// BP_FadeUIComponent: it calls RequestDeathFade + SetTemporaryInputMask at the death and releases the lock only after its own
// RequestUnfade. The exec thunk 0x140AC76F0 (body 0x1483E02A0) ends in a virtual call on the context: (*(iface) + 0x38)(iface, Caller,
// Usage, DownCount, Time), and the context in the trace was always the component + 0x120 (its FadeUIComponentIF part). Calling it on
// the interface's default object from Lua crashed the game. CoopProbe sends "unfade <component hex>" once the guest has his new pawn;
// the call is made here on the game thread with Caller = the component, Usage = DeathPC (102), DownCount = true, Time = 0.3 s.
typedef void (*unfade_fn)(void *iface, void *caller, uint8_t usage, uint8_t down_count, float time);
static volatile uintptr_t g_unfade_obj, g_unfade_caller;   // caller 0 = the component itself
static volatile LONG g_unfade_pending, g_unfade_usage = 102;
// UIHelper::RequestUnfade's native implementation (thunk 0x140B6F290): (WorldContext, Caller, Usage, DownCount, Time); it finds the
// fade component from the world context itself. memunfade calls it with the memory's scenario actor as context and caller.
#define ADDR_UI_REQUEST_UNFADE 0x1409CC650ULL
typedef void (*uiunfade_fn)(void *ctx, void *caller, uint8_t usage, uint8_t down_count, float time);
static volatile LONG g_memunfade_pending, g_memunfade_usage = 106;
// Item 8 (2026-10-30): on a group teleport the guest saw his world unload around him ("going through nothingness"). CoopProbe on the
// guest sends "tpfade <pawn> 1" when the host's character is replaced (teleport) and "tpfade <pawn> 0" once his own new character
// stands next to the host (or after 25 s); the game thread then runs the game's own teleport fade (usage 48, as the vanilla
// teleport 0x1466A7EF3 calls it) / the unfade for it, with his pawn as world context.
#define ADDR_UI_REQUEST_TELEPORT_FADE 0x1409CC360ULL
typedef void (*uitpfade_fn)(void *ctx, void *caller, uint8_t usage, uint8_t flag);
static volatile LONG g_tpfade_pending = -1;
static volatile uintptr_t g_tpfade_ctx;
// Leaving Home Base (owner 11-07: a loading screen until the world is there, then fade out): the game lifts its teleport fade at arrival, with the stage not loaded yet. Between
// "fadehold 1 0" and "fadehold 0 <pawn>" all unfades are kept back and made afterwards, on the game thread. At most 60 s.
static volatile LONG g_fade_hold, g_fade_held_n, g_fade_release_pending;
static volatile ULONGLONG g_fade_hold_at;
static volatile uintptr_t g_fade_ctx, g_fade_release_ctx;
static uint8_t g_fade_held[8], g_fade_held_flag[8];
static volatile uintptr_t g_memory_actor;
static volatile ULONGLONG g_memory_at;   // PlayMemoryResidue seen (v4 keeps the appear lock open for 3 minutes after it)   // ctx of the last WaitForMemoryResidueFinished (the scenario actor), for memunfade
static int readable(uintptr_t a, size_t len);
static void run_unfade(void) {
    uintptr_t obj = g_unfade_obj, iface = obj + 0x120;
    if (!obj || !readable(iface, 8)) { logf_("unfade: component 0x%llX not readable", (unsigned long long)obj); return; }
    uintptr_t vt = *(uintptr_t *)iface;
    if (!readable(vt + 0x38, 8)) { logf_("unfade: vtable 0x%llX not readable", (unsigned long long)vt); return; }
    uintptr_t fn = *(uintptr_t *)(vt + 0x38);
    uintptr_t caller = g_unfade_caller ? g_unfade_caller : obj;
    uint8_t usage = (uint8_t)g_unfade_usage;
    logf_("unfade: RequestUnfade(caller 0x%llX, usage %u) on component 0x%llX (iface vtable 0x%llX, fn 0x%llX)",
          (unsigned long long)caller, usage, (unsigned long long)obj, (unsigned long long)vt, (unsigned long long)fn);
    ((unfade_fn)fn)((void *)iface, (void *)caller, usage, 1, 0.3f);
}

// Appear lock (session 10, the memory's root cause): a global refcount. Acquire 0x1404448B0(obj) (body 0x145D7A4F0): obj+0xB85 = 1,
// [0x14413C404]++ and [0x14413C408]++, [0x14413C410] = -1 ("loading blocked until frame forever"). Release 0x140448D40(obj)
// (body 0x145D85C60; engine check if obj+0xB85 == 0): obj+0xB85 = 0, counters--, and when [0x14413C404] reaches 0 the block ends at
// the current frame. While it is blocked, 0x140456550 says "loading" and no character finishes its appear (the memory's loading
// fade waits for the host's memory character to appear). In co-op an object kept the lock until the guest left. Every acquire and
// release is logged; with keep_outro, within 10 min after a boss kill, holders older than 5 s are released while the loading check
// stays busy (on the game thread, only if obj+0xB85 == 1).
typedef void (*lock_fn)(void *obj);
static lock_fn g_orig_lock_acquire, g_orig_lock_release;
#define LOCK_MAX 32
static volatile uintptr_t g_lock_obj[LOCK_MAX];
static volatile ULONGLONG g_lock_at[LOCK_MAX];
static volatile LONG g_lock_logs;
static void lock_note(uintptr_t obj, int add) {
    for (int i = 0; i < LOCK_MAX; i++) if (g_lock_obj[i] == obj) { if (!add) g_lock_obj[i] = 0; else g_lock_at[i] = GetTickCount64(); return; }
    if (!add) return;
    for (int i = 0; i < LOCK_MAX; i++) if (!g_lock_obj[i]) { g_lock_obj[i] = obj; g_lock_at[i] = GetTickCount64(); return; }
}
static void detour_lock_acquire(void *obj) {
    uintptr_t ret = (uintptr_t)__builtin_return_address(0);
    g_orig_lock_acquire(obj);
    lock_note((uintptr_t)obj, 1);
    if (InterlockedIncrement(&g_lock_logs) <= 400)
        logf_("appear lock ACQUIRE by 0x%llX (count now %d) from 0x%llX", (unsigned long long)(uintptr_t)obj, *(volatile int *)0x14413C404ULL,
              (unsigned long long)ret);
}
static void detour_lock_release(void *obj) {
    uintptr_t ret = (uintptr_t)__builtin_return_address(0);
    g_orig_lock_release(obj);
    lock_note((uintptr_t)obj, 0);
    if (InterlockedIncrement(&g_lock_logs) <= 400)
        logf_("appear lock release by 0x%llX (count now %d) from 0x%llX", (unsigned long long)(uintptr_t)obj, *(volatile int *)0x14413C404ULL,
              (unsigned long long)ret);
}
// Second lock kind (+0xB83, same counter [0x14413C404]): taken when a character's appear sequence starts (inline, 0x145D7BE97)
// and given back when it ends (0x145D78720) or by 0x140447ED0(obj, alsoB85) (body 0x145D831E0; it also drops +0xB84 via
// 0x140448000). The guest's character on the host starts its appear but never ends it there (his game drives it), so the lock
// stayed until he left. While the loading check stays busy, the guest's objects from tpinfo are checked and released this way.
typedef void (*lockrel2_fn)(void *obj, char also_b85);
static void release_guest_appear_locks(void) {
    char buf[600];
    if (!read_small_file("CoopNative.tpinfo", buf, sizeof buf)) return;
    for (char *p = strtok(buf, "\r\n"); p; p = strtok(NULL, "\r\n")) {
        // only characters have these fields: "gpawn" = the guest's pawn, "hpawn" = the host's (CoopProbe)
        unsigned long long a; int guest = sscanf(p, "gpawn %llx", &a) == 1, host = !guest && sscanf(p, "hpawn %llx", &a) == 1;
        if ((!guest && !host) || !readable((uintptr_t)a + 0xB80, 8)) continue;
        uint8_t b83 = *(uint8_t *)((uintptr_t)a + 0xB83), b84 = *(uint8_t *)((uintptr_t)a + 0xB84), b85 = *(uint8_t *)((uintptr_t)a + 0xB85);
        static ULONGLONG last_flag_log;
        if (GetTickCount64() - last_flag_log > 2000) {
            if (!guest) last_flag_log = GetTickCount64();
            logf_("appear lock flags of %s 0x%llX: b83 %u b84 %u b85 %u (count %d)", guest ? "GUEST" : "host", a, b83, b84, b85,
                  *(volatile int *)0x14413C404ULL);
        }
        if (guest && (b83 == 1 || b85 == 1)) {
            ((lockrel2_fn)0x140447ED0ULL)((void *)(uintptr_t)a, b85 == 1);
            logf_("appear lock: released the guest's 0x%llX (b83 %u b85 %u) -> count %d (keep_outro)", a, b83, b85,
                  *(volatile int *)0x14413C404ULL);
        }
    }
}
static volatile ULONGLONG g_busy_since;
static void release_stale_locks(void) {
    ULONGLONG now = GetTickCount64();
    for (int i = 0; i < LOCK_MAX; i++) {
        uintptr_t o = g_lock_obj[i];
        if (!o || now - g_lock_at[i] < 5000) continue;
        if (readable(o + 0xB85, 1) && *(uint8_t *)(o + 0xB85) == 1) {
            logf_("appear lock: releasing 0x%llX (held %llu ms) so the memory can start (keep_outro)", (unsigned long long)o,
                  (unsigned long long)(now - g_lock_at[i]));
            g_orig_lock_release((void *)o);
            logf_("appear lock: count now %d", *(volatile int *)0x14413C404ULL);
        }
        g_lock_obj[i] = 0;
    }
}

// Appear finish per character (0x1405B07B0 -> body 0x1463440D0, session 10): runs while +0xC12 (appear pending) is set and
// nothing is loading; it clears +0xC12, then only if APawn::IsPlayerControlled (bit 3 of +0x3C8, engine 0x14204C650) is true
// does it RequestUnfade(101) and end the appear (dropping the +0xB83 lock). The host's memory character took the other branch.
// Every real attempt (+0xC12 set) is logged before and after: player-controlled bits, lock flags, is it the host's pawn.
static volatile LONG g_busy_count;   // calls of the loading check that said busy (defined here for the appear-finish log)
typedef void (*appearfin_fn)(void *pawn);
static appearfin_fn g_orig_appear_finish;
static volatile LONG g_appear_logs;
static void detour_appear_finish(void *pawn) {
    uintptr_t p = (uintptr_t)pawn;
    int pend = readable(p + 0xC12, 1) ? *(uint8_t *)(p + 0xC12) : -1;
    if (pend <= 0) { g_orig_appear_finish(pawn); return; }
    uint8_t pc0 = readable(p + 0x3C8, 1) ? *(uint8_t *)(p + 0x3C8) : 0, b83_0 = readable(p + 0xB83, 1) ? *(uint8_t *)(p + 0xB83) : 0;
    LONG busy0 = g_busy_count;
    // fix attempt: the host's own memory character (the host controller's +0x388 points to it) without the player-controlled bit
    // -> set it (bit 2 "set" + bit 3 "player controlled") so the finish ends the appear and lifts the loading fade (keep_outro)
    int fixed = 0;
    uintptr_t hpc = g_host_pc;
    if (g_keep_outro && g_outro_at_early && GetTickCount64() - g_outro_at_early < 600000 && !((pc0 >> 3) & 1) && hpc &&
        readable(hpc + 0x388, 8) && *(uintptr_t *)(hpc + 0x388) == p) {
        *(volatile uint8_t *)(p + 0x3C8) = (uint8_t)(pc0 | 0x0C);
        fixed = 1;
    }
    g_orig_appear_finish(pawn);
    uint8_t pend1 = *(uint8_t *)(p + 0xC12), pc1 = *(uint8_t *)(p + 0x3C8), b83_1 = *(uint8_t *)(p + 0xB83);
    if (InterlockedIncrement(&g_appear_logs) <= 300)
        logf_("appear finish on 0x%llX%s%s: pending %d->%u, +0x3C8 0x%02X->0x%02X (playerControlled %u, set %u), b83 %u->%u, busy calls %ld->%ld",
              (unsigned long long)p, p == g_host_pawn ? " (HOST pawn)" : "", fixed ? " [player-controlled bit SET by CoopNative]" : "", pend,
              pend1, pc0, pc1, (pc1 >> 3) & 1, (pc1 >> 2) & 1, b83_0, b83_1, busy0, g_busy_count);
}

// 2026-11-02 (both PCs crashed at a host rest: "BitArrayIndex" assert, Actor.cpp:88, right after "+0xB84 holders -1/-2"): zeroing
// the counters in v5 while other characters still had their lock flags set let those characters decrement again later -> the
// counters went negative -> the engine used them as an index. Every reset now also clears the flags of all known player
// characters, and the worker keeps the three counters from staying below 0.
static void clear_one_lock_flags(uintptr_t a) {
    if (a > 0x10000 && readable(a + 0xB80, 8)) {
        *(volatile uint8_t *)(a + 0xB83) = 0; *(volatile uint8_t *)(a + 0xB84) = 0; *(volatile uint8_t *)(a + 0xB85) = 0;
    }
}
// 2026-11-06: v6 freed the players only. The 22 other holders are the Home Base NPCs: their flags stayed, so they stayed unfinished and invisible
// until the session ended (12:47:01, all at once; 44 releases on counters already at 0). CoopProbe lists every character in CoopNative.holders.
static int clear_holder_flags(void) {
    static char hb[16384];
    if (!read_small_file("CoopNative.holders", hb, sizeof hb)) return 0;
    int n = 0;
    char *q = hb;
    while (*q) {
        char *end; unsigned long long v = strtoull(q, &end, 16);
        if (end == q) break;
        uintptr_t a = (uintptr_t)v;
        if (a > 0x10000 && readable(a + 0xB80, 8) && readable(a + 0x28, 0x10) && readable(a + 0xC10, 4)) {
            uint8_t b83 = *(volatile uint8_t *)(a + 0xB83), b84 = *(volatile uint8_t *)(a + 0xB84), b85 = *(volatile uint8_t *)(a + 0xB85);
            if ((b83 == 1 || b84 == 1 || b85 == 1) && b83 <= 1 && b84 <= 1 && b85 <= 1) {
                if (n < 4) logf_("appear lock: holder 0x%llX b83 %u b84 %u b85 %u, tick registered %u enabled %u, pending %u", v, b83, b84, b85,
                                 *(volatile uint8_t *)(a + 0x35), *(volatile uint8_t *)(a + 0x37), *(volatile uint8_t *)(a + 0xC12));
                clear_one_lock_flags(a);
                n++;
            }
        }
        q = end; while (*q == ' ') q++;
    }
    return n;
}
// only character addresses: "hpawn"/"gpawn" lines of tpinfo (it also lists controllers and drivers) and CoopNative.pawns
static void clear_player_lock_flags(void) {
    char buf[600];
    if (read_small_file("CoopNative.tpinfo", buf, sizeof buf)) {
        for (char *line = strtok(buf, "\r\n"); line; line = strtok(NULL, "\r\n")) {
            unsigned long long a;
            if (sscanf(line, "gpawn %llx", &a) == 1 || sscanf(line, "hpawn %llx", &a) == 1) clear_one_lock_flags((uintptr_t)a);
        }
    }
    if (read_small_file("CoopNative.pawns", buf, sizeof buf)) {
        char *q = buf;
        while (*q) {
            char *end; unsigned long long v = strtoull(q, &end, 16);
            if (end == q) break;
            clear_one_lock_flags((uintptr_t)v);
            q = end; while (*q == ' ') q++;
        }
    }
}
static void clamp_lock_counters(void) {
    static ULONGLONG last_log;
    volatile int *c[3] = {(volatile int *)0x14413C404ULL, (volatile int *)0x14413C408ULL, (volatile int *)0x14413C40CULL};
    int fixed = 0;
    for (int i = 0; i < 3; i++) if (*c[i] < 0) { *c[i] = 0; fixed = 1; }
    if (fixed && GetTickCount64() - last_log > 1000) { last_log = GetTickCount64(); logf_("appear lock: negative counter(s) set back to 0"); }
}

// Assert guard (session 10, 12:46:55 crash): after the v5 reset a leftover holder released its lock and the engine check
// "NumInCharacterSetupBeforeAppBeginPlay > 0" (AppCharacter.cpp) aborted the game. [0x14413C404] is exactly that counter. The fatal
// assert 0x140C3EEC0 is skipped (logged) only when called from the lock code (return address 0x145D78000..0x145D86200); the code
// then decrements below 0 and sets the block to the current frame, which is harmless. Every other engine check is untouched.
typedef uint64_t (*assert_fn)(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h);
static assert_fn g_orig_assert_fatal;
static volatile LONG g_assert_skips;
static uint64_t detour_assert_fatal(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) {
    uintptr_t ret = (uintptr_t)__builtin_return_address(0);
    if (ret >= 0x145D78000ULL && ret < 0x145D86200ULL) {
        // 2026-11-03 (both PCs crashed with "BitArrayIndex" right after a negative counter): the failing check is followed by a
        // plain DEC of the counter it tested. Set exactly that counter to 1 first, so the decrement ends at 0, never below:
        // return 0x145D8361B = "[0x14413C40C] > 0" (+0xB84 holders), return 0x145D78817 = "[0x14413C404] > 0" (start counter)
        if (ret == 0x145D8361BULL && *(volatile int *)0x14413C40CULL <= 0) *(volatile int *)0x14413C40CULL = 1;
        if (ret == 0x145D78817ULL && *(volatile int *)0x14413C404ULL <= 0) *(volatile int *)0x14413C404ULL = 1;
        // return 0x145D83247 = AppCharacter.cpp:823 "NumInCharacterSetup > 0" on [0x14413C404] (2026-11-04: went negative -> clamp)
        if (ret == 0x145D83247ULL && *(volatile int *)0x14413C404ULL <= 0) *(volatile int *)0x14413C404ULL = 1;
        LONG n = InterlockedIncrement(&g_assert_skips);
        if (n <= 50) logf_("appear lock: engine check in the lock code skipped (from 0x%llX, count %d, +0xB84 holders %d, %ld so far)",
                           (unsigned long long)ret, *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C40CULL, n);
        return 0;
    }
    return g_orig_assert_fatal(a, b, c, d, e, f, g, h);
}

// Memory step (a) (session 10): with guest_outro the guest's game plays the host's outro and at its end starts its OWN memory
// (PlayMemoryResidue -> impl 0x14090B120(scenario actor, FString*)): a second story copy on its own timer, scenes in his own world
// state. On the guest that call is not run; instead his scenario actor's +0x430 bit 0x100 is set, which keeps his flow in
// WaitForMemoryResidueFinished (done when the bit is clear), and it is cleared when his own pawn is replaced after the memory (the
// host brings him back) or after 10 minutes. CoopProbe writes his pawn to CoopNative.mypawn.
// callers of the last solid fades with usage 104 (cutscene covers); the fade trace fills it (see note_cover)
static volatile uintptr_t g_cover_ctx[4];
static volatile LONG g_cover_n;
typedef uint8_t (*playmem_fn)(void *actor, void *symbol);
static playmem_fn g_orig_play_memory;
static volatile uintptr_t g_guest_mem_actor, g_guest_mem_pawn;
static volatile ULONGLONG g_guest_mem_at;
static uintptr_t read_my_pawn(void) {
    char b[64];
    if (!read_small_file("CoopNative.mypawn", b, sizeof b)) return 0;
    return (uintptr_t)strtoull(b, NULL, 16);
}
static char g_dir[MAX_PATH];   // tentative definition (also further down)
// tell CoopProbe on the guest that the host's memory runs (1) / ended (0): it puts his camera on the host and hides his pawn
static void write_guestmem(int on) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.guestmem", g_dir);
    FILE *f = _fsopen(path, "w", _SH_DENYNO);
    if (f) { fprintf(f, "%d", on); fclose(f); }
}
static uint8_t detour_play_memory(void *actor, void *symbol) {
    if (g_guest_outro && g_guest_mem_block && actor && readable((uintptr_t)actor + 0x430, 4)) {
        *(volatile uint32_t *)((uintptr_t)actor + 0x430) |= 0x100;
        g_guest_mem_actor = (uintptr_t)actor; g_guest_mem_at = GetTickCount64(); g_guest_mem_pawn = read_my_pawn();
        write_guestmem(1);
        logf_("memory (a): the guest's own PlayMemoryResidue NOT run; his flow waits (actor 0x%llX, pawn 0x%llX)",
              (unsigned long long)(uintptr_t)actor, (unsigned long long)g_guest_mem_pawn);
        // his flow covers the screen right before this call (RequestSolidFade(actor, 104), seen in the solo fade trace from
        // 0x146FD0E6A); his own memory would have lifted it. Lift it here (UIHelper RequestUnfade impl, we are on the game thread).
        ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)(actor, actor, 104, 0, 0.3f);
        ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)(actor, actor, 104, 1, 0.3f);
        // (unfading the cutscene model actor's cover as well crashed the guest at 18:59:09: a null call right after it -> only the
        //  scenario actor's own cover is lifted)
        logf_("memory (a): unfade 104 requested for the guest's screen (scenario actor)");
        return 1;
    }
    return g_orig_play_memory(actor, symbol);
}
static void guest_memory_watch(void) {
    uintptr_t a = g_guest_mem_actor;
    if (!a) return;
    ULONGLONG now = GetTickCount64();
    uintptr_t pawn = read_my_pawn();
    int replaced = now - g_guest_mem_at > 15000 && pawn && g_guest_mem_pawn && pawn != g_guest_mem_pawn;
    if (!g_guest_mem_pawn && pawn) g_guest_mem_pawn = pawn;
    // the memory start's group teleport replaces his pawn once in the first seconds: take that one as the memory pawn
    if (now - g_guest_mem_at < 15000 && pawn) g_guest_mem_pawn = pawn;
    if (replaced || now - g_guest_mem_at > 600000) {
        g_guest_mem_actor = 0;
        if (readable(a + 0x430, 4)) *(volatile uint32_t *)(a + 0x430) &= ~0x100u;
        write_guestmem(0);
        logf_("memory (a): released the guest's flow (%s)", replaced ? "his pawn was replaced after the memory" : "timeout");
    }
}

// "Loading in progress?" (0x1407ACD30 -> body 0x146D16E10, session 10): a new character's appear sequence only finishes (and
// lifts the memory's loading fade) when this answers 0. It answers 1 for: world +0x4A0 pending, 0x1407ACE50(world, 0),
// 0x140456550(), 0x141EED8C0(), 0x140E38C30(), or any streaming level of the context's world (+0x88 array, +0x90 count) with
// 0x141EEDFA0(level) true and !(level+0xB0 & 4). Logged (on the game thread, after the original) once a second while it says 1,
// with the first reason found and the level object.
typedef uint8_t (*busy_fn)(void *ctx);
typedef void *(*world_fn)(void *ctx);
typedef void *(*world2_fn)(void *w, int z);
typedef uint8_t (*flag0_fn)(void);
typedef uint8_t (*flagw_fn)(void *w, int z);
typedef uint8_t (*flagl_fn)(void *l);
static busy_fn g_orig_busy;
static volatile ULONGLONG g_last_busy_log;
static uint8_t detour_busy(void *ctx) {
    uint8_t r = g_orig_busy(ctx);
    if (!r) { g_busy_since = 0; return r; }
    if (!g_busy_since) g_busy_since = GetTickCount64();
    if (g_keep_outro && g_outro_at_early && GetTickCount64() - g_outro_at_early < 600000 && GetTickCount64() - g_busy_since > 3000 &&
        ((flag0_fn)0x140456550ULL)()) {
        release_guest_appear_locks();
        // v3 (11:57 measurement): counters [404]=2 [408]=0 [40C]=1 and [410] = -1. "Forever" (-1) comes only from the +0xB85 kind,
        // which had no holder left; the release resets [410] only when the TOTAL count reaches 0, and +0xB83 holders (the host's own
        // memory character during its appear, plus one leftover) keep it above 0 -> deadlock (the appear waits for "not loading").
        // Do what the release would have done: no +0xB85 holder -> block until the current frame only.
        if (*(volatile uint64_t *)0x14413C410ULL == ~0ULL && *(volatile int *)0x14413C408ULL <= 0) {
            *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
            logf_("appear lock: no +0xB85 holder but 'forever' set (count %d, +0xB84 holders %d) -> unblocked at the current frame (keep_outro)",
                  *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C40CULL);
        }
        release_stale_locks();
        r = g_orig_busy(ctx);
        if (!r) { g_busy_since = 0; return r; }
    }
    InterlockedIncrement(&g_busy_count);
    ULONGLONG now = GetTickCount64();
    if (now - g_last_busy_log < 1000) return r;
    g_last_busy_log = now;
    const char *why = "?"; uintptr_t lvl = 0; int li = -1;
    void *w = ((world_fn)0x1409D77C0ULL)(ctx);
    void *w2 = w ? ((world2_fn)0x1422BE540ULL)(w, 0) : NULL;
    if (w2 && readable((uintptr_t)w2 + 0x4A0, 8) && *(uintptr_t *)((uintptr_t)w2 + 0x4A0)) why = "pending at +0x4A0";
    else if (w2 && ((flagw_fn)0x1407ACE50ULL)(w2, 0)) why = "0x1407ACE50";
    else if (((flag0_fn)0x140456550ULL)()) why = "0x140456550 (global counter)";
    else if (((flag0_fn)0x141EED8C0ULL)()) why = "0x141EED8C0";
    else if (((flag0_fn)0x140E38C30ULL)()) why = "0x140E38C30";
    else if (w && readable((uintptr_t)w + 0x88, 16)) {
        uintptr_t arr = *(uintptr_t *)((uintptr_t)w + 0x88); int n = *(int *)((uintptr_t)w + 0x90);
        for (int i = 0; i < n && i < 512; i++) {
            uintptr_t l = readable(arr + i * 8, 8) ? *(uintptr_t *)(arr + i * 8) : 0;
            if (l && ((flagl_fn)0x141EEDFA0ULL)((void *)l) && readable(l + 0xB0, 1) && !(*(uint8_t *)(l + 0xB0) & 4)) {
                why = "streaming level"; lvl = l; li = i; break;
            }
        }
    }
    int name_idx = lvl && readable(lvl + 0x18, 4) ? *(int *)(lvl + 0x18) : -1;
    logf_("loading check says busy (%ld calls): %s%s level #%d 0x%llX (name index %d), ctx 0x%llX", g_busy_count, why,
          lvl ? ":" : "", li, (unsigned long long)lvl, name_idx, (unsigned long long)(uintptr_t)ctx);
    return r;
}

// Freeze watchdog (session 9: the guest froze after a boss kill, the host hung on a loading screen, no crash log). This detour runs
// on the game thread while Lua polls (several times a second in the game); the worker notes when it stops. After 8, 20 and 40 s
// of silence the game thread is suspended for a moment and its RIP plus the exe-range values on its stack are logged.
static volatile ULONGLONG g_heartbeat;
static volatile DWORD g_game_tid;
static void dump_game_thread(ULONGLONG silent_ms) {
    DWORD tid = g_game_tid;
    HANDLE h = tid ? OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid) : NULL;
    if (!h) { logf_("watchdog: game thread silent %llu ms, cannot open it", (unsigned long long)silent_ms); return; }
    // while it is suspended: only raw reads (no CRT calls that could need a lock the game thread holds)
    uint64_t vals[48]; int n = 0; DWORD64 rip = 0; BOOL got = FALSE; DWORD err = 0;
    if (SuspendThread(h) != (DWORD)-1) {
        static CONTEXT c;
        c.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
        got = GetThreadContext(h, &c);
        if (got) {
            rip = c.Rip;
            for (uintptr_t q = c.Rsp; q < c.Rsp + 0x1000 && n < 48; q += 8) {
                if (!readable(q, 8)) break;
                uint64_t v = *(uint64_t *)q;
                if (v >= 0x140001000ULL && v < 0x152000000ULL) vals[n++] = v;
            }
        } else err = GetLastError();
        ResumeThread(h);
    }
    CloseHandle(h);
    char line[1400] = "";
    if (got) {
        snprintf(line, sizeof line, "RIP %llX stack:", (unsigned long long)rip);
        for (int i = 0; i < n; i++) { char one[20]; snprintf(one, sizeof one, " %llX", (unsigned long long)vals[i]); strcat_s(line, sizeof line, one); }
    } else snprintf(line, sizeof line, "no context (%lu)", err);
    logf_("watchdog: game thread silent %llu ms: %s", (unsigned long long)silent_ms, line);
}
// Work that must run on the game thread. Pumped every frame by the GameEngine::Tick hook below and, as before, by the
// GetRescueSignalState hook (fallback: that one only runs while Blueprints poll it, about once a second). Each item is taken with
// an InterlockedExchange, so whichever pump comes first runs it once.
// Cutscene sync trace (2026-11-05, log only): the scenario manager's ready flags, logged on every change. +0x20C own models ready,
// +0x20D partner's, +0x20E partner finished, +0x20F/+0x210 the cutscene's finished check, +0x211/+0x212 multiplay synced.
static volatile uintptr_t g_scen_mgr;
static void scene_flags_sample(void) {
    static uint8_t last[7]; static int have; static uintptr_t lastm;
    uintptr_t m = g_scen_mgr;
    if (!m || !readable(m + 0x20C, 7)) return;
    const uint8_t *f = (const uint8_t *)(m + 0x20C);
    if (have && lastm == m && memcmp(last, f, 7) == 0) return;
    memcpy(last, f, 7); have = 1; lastm = m;
    logf_("scene flags: ready own %u partner %u | partner finished %u | finished %u %u | synced %u %u",
          last[0], last[1], last[2], last[3], last[4], last[5], last[6]);
}
static void pn_game_thread(void);
static void pn_read(void);
static void pn_in_append(int data);
static void game_thread_work(void) {
    scene_flags_sample();
    if (g_unfade_pending && InterlockedExchange(&g_unfade_pending, 0)) run_unfade();
    if (g_memunfade_pending && InterlockedExchange(&g_memunfade_pending, 0)) {
        uintptr_t actor = g_memory_actor;
        if (actor && readable(actor, 8)) {
            uint8_t usage = (uint8_t)g_memunfade_usage;
            logf_("memunfade: UIHelper RequestUnfade(context = caller = 0x%llX, usage %u, down, 0.3 s)", (unsigned long long)actor, usage);
            ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)((void *)actor, (void *)actor, usage, 1, 0.3f);
            logf_("memunfade: returned");
        } else logf_("memunfade: no memory actor");
    }
    {
        LONG tf = InterlockedExchange(&g_tpfade_pending, -1);
        uintptr_t c = g_tpfade_ctx;
        if (tf >= 0 && c && readable(c, 8)) {
            if (tf) ((uitpfade_fn)ADDR_UI_REQUEST_TELEPORT_FADE)((void *)c, (void *)c, 48, 0);
            else ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)((void *)c, (void *)c, 48, 0, 1.0f);
            logf_("tpfade: %s (context 0x%llX)", tf ? "teleport fade requested" : "unfade requested", (unsigned long long)c);
        } else if (tf >= 0) logf_("tpfade: no valid context");
    }
    if (g_fade_release_pending && InterlockedExchange(&g_fade_release_pending, 0)) {
        InterlockedExchange(&g_fade_hold, 0);
        uintptr_t c = g_fade_release_ctx ? g_fade_release_ctx : g_fade_ctx;
        LONG n = g_fade_held_n;
        if (c && readable(c, 8)) for (LONG i = 0; i < n && i < 8; i++) ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)((void *)c, (void *)c, g_fade_held[i], g_fade_held_flag[i], 0.5f);
        logf_("fade hold: over, %ld unfade(s) made (context 0x%llX)", n, (unsigned long long)c);
        g_fade_held_n = 0;
    }
    if (g_levelup_pending && InterlockedExchange(&g_levelup_pending, 0)) run_levelup();
    if (g_syncall_pending && InterlockedExchange(&g_syncall_pending, 0)) run_syncall();
    if (g_seatcam_pending && InterlockedExchange(&g_seatcam_pending, 0)) {
        uintptr_t pc = g_seatcam_pc, pw = g_seatcam_pawn;
        if (pc && pw && readable(pc, 8) && readable(pw, 8) && readable(*(uintptr_t *)pc + 0x8B8, 8)) {
            void **vt = *(void ***)pc;
            ((void (*)(void *, void *))vt[0x8B8 / 8])((void *)pc, (void *)pw);   // ClientRestart_Implementation
            logf_("seats: local restart of 0x%llX with 0x%llX", (unsigned long long)pc, (unsigned long long)pw);
        } else logf_("seats: local restart refused (0x%llX, 0x%llX)", (unsigned long long)pc, (unsigned long long)pw);
    }
    if (g_vols_pending && InterlockedExchange(&g_vols_pending, 0)) run_volcheck();
    if (g_lvlinfo_pending && InterlockedExchange(&g_lvlinfo_pending, 0)) run_lvlinfo();
    pn_game_thread();
}
// Scene relay (2026-10-30, after the Lies of P study, which plays cutscenes on every PC and relays only start/skip by name).
// ScenarioFunctionLibrary:RequestEvent (thunk 0x140B4B6F0) -> impl 0x14090CA30(Actor, FString* Event); SkipEventUIComponent:
// RequestSkipEvent (thunk 0x140B5A240) -> impl 0x1409CC030(component). Both PCs log every call and append it to CoopNative.relay:
// "event <actor name index> <number> <class name index> <event>" / "skip". CoopProbe on the host turns them into ClientMessages
// for the guest; on the guest the lines are its own events (duplicate filter).
#define ADDR_REQUEST_EVENT_IMPL 0x14090CA30ULL
#define ADDR_SKIP_EVENT_IMPL 0x1409CC030ULL
typedef uint64_t (*reqevent_fn)(void *actor, void *event);
typedef uint64_t (*skipevent_fn)(void *comp);
static reqevent_fn g_orig_request_event;
static int in_session_as_guest(void) {
    char b[16];
    return read_small_file("CoopNative.role", b, sizeof b) && strncmp(b, "guest", 5) == 0;
}
static skipevent_fn g_orig_skip_event;
static volatile LONG g_relay_logs;
static void relay_append(const char *line) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.relay", g_dir);
    FILE *f = _fsopen(path, "a", _SH_DENYNO);
    if (f) { fputs(line, f); fputc('\n', f); fclose(f); }
}
static uint64_t detour_request_event(void *actor, void *event) {
    char name[160] = "";
    uintptr_t e = (uintptr_t)event;
    if (e && readable(e, 16)) {
        const uint16_t *w = *(const uint16_t **)e;
        int n = *(int *)(e + 8);
        if (w && n > 0 && n < 150 && readable((uintptr_t)w, (size_t)n * 2)) {
            int k = 0;
            for (int i = 0; i < n - 1 && k < 150; i++) name[k++] = (w[i] >= 32 && w[i] < 127 && w[i] != ' ') ? (char)w[i] : '_';
            name[k] = 0;
        }
    }
    uintptr_t a = (uintptr_t)actor;
    int ni = 0, nn = 0, ci = 0;
    if (a && readable(a + 0x10, 0x10)) {
        ni = *(int *)(a + 0x18); nn = *(int *)(a + 0x1C);
        uintptr_t cls = *(uintptr_t *)(a + 0x10);
        if (cls && readable(cls + 0x18, 4)) ci = *(int *)(cls + 0x18);
    }
    if ((name[0] && strcmp(name, "None") != 0 && InterlockedIncrement(&g_relay_logs) <= 400))
        logf_("scene: RequestEvent(actor 0x%llX name %d_%d class %d, \"%s\")", (unsigned long long)a, ni, nn, ci, name);
    // (2026-10-31 guest log: RequestEvent runs every second for doors/Mistles/chests with an empty or "None" event: not relayed)
    if (name[0] && strcmp(name, "None") != 0) { char line[256]; snprintf(line, sizeof line, "event %d %d %d %s", ni, nn, ci, name); relay_append(line); }
    return g_orig_request_event(actor, event);
}
static uint64_t detour_skip_event(void *comp) {
    // 2026-11-02 (owner): a guest skipping on his own caused problems afterwards. In a session as guest (no fresh tpinfo) his own
    // skip input is ignored; the host's skip arrives through CoopProbe, which touches CoopNative.allowskip right before pressing it
    if (!g_host_pc && g_keep_outro && in_session_as_guest()) {
        char path[MAX_PATH];
        snprintf(path, sizeof path, "%sCoopNative.allowskip", g_dir);
        WIN32_FILE_ATTRIBUTE_DATA fa;
        int fresh = 0;
        if (GetFileAttributesExA(path, GetFileExInfoStandard, &fa)) {
            FILETIME now; GetSystemTimeAsFileTime(&now);
            ULONGLONG t = ((ULONGLONG)fa.ftLastWriteTime.dwHighDateTime << 32) | fa.ftLastWriteTime.dwLowDateTime;
            ULONGLONG n = ((ULONGLONG)now.dwHighDateTime << 32) | now.dwLowDateTime;
            fresh = n >= t && n - t < 3ULL * 10000000ULL;
        }
        if (!fresh) { logf_("scene: our own skip (0x%llX) ignored: only the host skips in co-op", (unsigned long long)(uintptr_t)comp); return 0; }
        DeleteFileA(path);
    }
    uint64_t r = g_orig_skip_event(comp);
    logf_("scene: RequestSkipEvent(0x%llX) -> %llu", (unsigned long long)(uintptr_t)comp, (unsigned long long)(r & 0xFF));
    relay_append("skip");
    return r;
}

// Ending-branch trace (2026-11-02): the guest's game picks a different post-boss ending than the host's (vestige branch). For
// 10 minutes after a boss kill, both PCs log what these queries return (ScenarioManager:GetPlayPolySymbol = the chosen large-poly
// cutscene; the vestige / progress / flag checks the flow may use). Exec thunks: (context, FFrame*, result); the result is read
// after the original ran: its first 16 bytes, and the text if it is an FString. At most 80 lines per function.
#define BRANCH_N 9
static const char *g_branch_name[BRANCH_N] = {"ScenarioManager:GetPlayPolySymbol", "ScenarioActor:GetProgressFlag", "ScenarioActor:GetVolatileFlags", "ScenarioActor:IsVolatileFlagsSet", "CharacterHelper:IsAcquiredBloodCodePiece", "BCRestorationUIComponent:IsAcquiredBloodCodePiece", "CharacterHelper:GetScenarioAfterMemoryResidue", "AppSaveManager:GetGameProgress", "AppSaveManager:CheckGameProgress"};
static const uint64_t g_branch_addr[BRANCH_N] = {0x140B49E40ULL, 0x140B3C9B0ULL, 0x140B3CD30ULL, 0x140B3D150ULL, 0x140A6BA10ULL, 0x140A3E2B0ULL, 0x140A68E10ULL, 0x140A04BB0ULL, 0x140A034A0ULL};
static const char *g_branch_expect[BRANCH_N] = {
    "\xE9\xAB\x92\x28\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xAB\x1A\x21\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xDB\x28\x21\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x2B\x43\x21\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x7B\xC4\x30\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x0B\xEC\x10\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x5B\x18\x30\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x3B\x4C\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xFB\x20\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};
static exec_fn g_branch_orig[BRANCH_N];
static volatile LONG g_branch_count[BRANCH_N];
static volatile ULONGLONG g_branch_kill_at;   // mirror of the boss kill time, set where the boss kill is noted
static void branch_note(int i, void *c, void *r) {
    if (!g_branch_kill_at || GetTickCount64() - g_branch_kill_at > 600000) return;
    if (InterlockedIncrement(&g_branch_count[i]) > 80) return;
    uintptr_t a = (uintptr_t)r;
    if (!a || !readable(a, 16)) { logf_("BRANCH %s ctx=0x%llX -> (no result)", g_branch_name[i], (unsigned long long)(uintptr_t)c); return; }
    const uint8_t *b = (const uint8_t *)a;
    char txt[96] = "";
    const uint16_t *w = *(const uint16_t **)a;
    int len = *(int *)(a + 8);
    if (w && len > 1 && len < 80 && readable((uintptr_t)w, (size_t)len * 2)) {
        int k = 0; txt[k++] = ' '; txt[k++] = '"';
        for (int j = 0; j < len - 1 && k < 90; j++) txt[k++] = (w[j] >= 32 && w[j] < 127) ? (char)w[j] : '?';
        txt[k++] = '"'; txt[k] = 0;
    }
    logf_("BRANCH %s ctx=0x%llX -> %02X %02X %02X %02X %02X %02X %02X %02X | %02X %02X %02X %02X%s", g_branch_name[i],
          (unsigned long long)(uintptr_t)c, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], txt);
}
#define BRANCH_DETOUR(i) static void branch_det_##i(void *c, void *st, void *r) { g_branch_orig[i](c, st, r); branch_note(i, c, r); }
BRANCH_DETOUR(0)
BRANCH_DETOUR(1)
BRANCH_DETOUR(2)
BRANCH_DETOUR(3)
BRANCH_DETOUR(4)
BRANCH_DETOUR(5)
BRANCH_DETOUR(6)
BRANCH_DETOUR(7)
BRANCH_DETOUR(8)
static void *g_branch_det[BRANCH_N] = {branch_det_0, branch_det_1, branch_det_2, branch_det_3, branch_det_4, branch_det_5, branch_det_6, branch_det_7, branch_det_8};

// CheckGameProgress trace (2026-11-03): on the guest it answered "yes" where his synced flags say no (all vestiges, extra Nicola
// statue in the memory, the Nicola knight figure in the field). Impl 0x140792570(FString* symbol, UObject* ctx) -> bool; inside,
// 0x141DF3070(ctx) fetches the data object that is checked (cast against 0x1409FA3B0's class). Both PCs log symbol, answer, the
// context's class and the data object (address + class/name FName indexes; "fname <idx>" in CoopProbe.cmd resolves them):
// the first 150 calls of a run, and all calls for 10 min after a boss kill (at most 1500 more).
#define ADDR_CHECK_PROGRESS_IMPL 0x140792570ULL
#define ADDR_CTX_DATA 0x141DF3070ULL
typedef uint8_t (*checkprog_fn)(void *symbol, void *ctx);
typedef void *(*ctxdata_fn)(void *ctx);
static checkprog_fn g_orig_check_progress;
static volatile LONG g_cgp_logs, g_cgp_boss_logs;
// 2026-11-04: the trace stopped after 1500 calls, inside the memory, before the vestige checks that decide the ending. After the
// kill every symbol is now logged only when its answer changes, so the whole 10 minutes fit (hash -> last answer + 1).
static struct { uint32_t h; uint8_t v; } g_cgp_seen[4096];
static int cgp_changed(const char *name, uint8_t r) {
    uint32_t h = 2166136261u;
    for (const char *p = name; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    if (!h) h = 1;
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t k = (h + i) & 4095;
        if (g_cgp_seen[k].h == 0) { g_cgp_seen[k].h = h; g_cgp_seen[k].v = (uint8_t)(r + 1); return 1; }
        if (g_cgp_seen[k].h == h) { if (g_cgp_seen[k].v == r + 1) return 0; g_cgp_seen[k].v = (uint8_t)(r + 1); return 1; }
    }
    return 0;
}
static uint8_t detour_check_progress(void *symbol, void *ctx) {
    // the symbol is read BEFORE the call (2026-11-03: read afterwards it came out garbled; the impl consumes the FString)
    int boss = g_branch_kill_at && GetTickCount64() - g_branch_kill_at < 600000;
    int first = InterlockedIncrement(&g_cgp_logs) <= 150;
    if (!first && !boss) return g_orig_check_progress(symbol, ctx);
    char name[120] = "";
    uintptr_t e = (uintptr_t)symbol;
    if (e && readable(e, 16)) {
        const uint16_t *w = *(const uint16_t **)e;
        int n = *(int *)(e + 8);
        if (w && n > 0 && n < 110 && readable((uintptr_t)w, (size_t)n * 2)) {
            int k = 0;
            for (int i = 0; i < n - 1 && k < 110; i++) name[k++] = (w[i] >= 32 && w[i] < 127) ? (char)w[i] : '?';
            name[k] = 0;
        }
    }
    uint8_t r = g_orig_check_progress(symbol, ctx);
    if (!first && (!cgp_changed(name, r) || InterlockedIncrement(&g_cgp_boss_logs) > 4000)) return r;
    uintptr_t c = (uintptr_t)ctx, d = 0;
    int cc = -1, dc = -1, dn = -1;
    if (c && readable(c + 0x10, 0x10)) { uintptr_t cl = *(uintptr_t *)(c + 0x10); if (cl && readable(cl + 0x18, 4)) cc = *(int *)(cl + 0x18); }
    if (c) d = (uintptr_t)((ctxdata_fn)ADDR_CTX_DATA)(ctx);
    if (d && readable(d + 0x10, 0x10)) {
        dn = *(int *)(d + 0x18);
        uintptr_t cl = *(uintptr_t *)(d + 0x10); if (cl && readable(cl + 0x18, 4)) dc = *(int *)(cl + 0x18);
    }
    logf_("CGP %s -> %u | ctx 0x%llX class %d | data 0x%llX class %d name %d", name, r, (unsigned long long)c, cc, (unsigned long long)d, dc, dn);
    return r;
}

// Game-thread pump (2026-10-30, after the Lies of P study, which drains its queue from a hooked engine tick): UGameEngine::Tick
// 0x14EBE3C20 (UE4SS finds the same address; it hooks it too, later, on top of ours). (this, float DeltaSeconds, bool bIdleMode).
#define ADDR_GAME_ENGINE_TICK 0x14EBE3C20ULL
typedef void (*enginetick_fn)(void *self, float delta, uint8_t idle);
static enginetick_fn g_orig_engine_tick;
static volatile LONG64 g_engine_ticks;
static void detour_engine_tick(void *self, float delta, uint8_t idle) {
    g_heartbeat = GetTickCount64(); g_game_tid = GetCurrentThreadId();
    if (InterlockedIncrement64(&g_engine_ticks) == 1) {
        logf_("game-thread pump: first GameEngine::Tick (thread %lu)", GetCurrentThreadId());
        // 2026-11-04: first tick 22 s with the Lua mods off, 80 s with them on: their polling slows the load. They wait for this file.
        char tp[MAX_PATH + 32];
        snprintf(tp, sizeof tp, "%sCoopNative.ticked", g_dir);
        FILE *tf = fopen(tp, "w");
        if (tf) { fputs("1", tf); fclose(tf); }
    }
    game_thread_work();
    g_orig_engine_tick(self, delta, idle);
}
static void detour_get_state(void *context, void *stack, void *result) {
    g_heartbeat = GetTickCount64(); g_game_tid = GetCurrentThreadId();
    if (g_replay_pending && context && context == g_vetoed_sm && InterlockedExchange(&g_replay_pending, 0)) {
        LONG kind = InterlockedExchange(&g_vetoed_kind, 0);
        g_vetoed_sm = NULL;
        logf_("replay: calling the vetoed %s for real", kind == 2 ? "EndCooperativeMode" : "SwitchToEndCoop");
        if (kind == 2) g_orig_end_coop(context); else g_orig_switch_end_coop(context);
    }
    game_thread_work();
    int menu = g_vestige_enabled && from_menu(stack);
    g_orig_get_state(context, stack, result);
    if (menu && result) { *(uint8_t *)result = 0; InterlockedIncrement(&g_vestige_overrides); }
    InterlockedIncrement(&g_calls);
    if (result) InterlockedExchange(&g_last_state, *(uint8_t *)result);
}

// UAppSessionManager state-machine handler (body moved by Denuvo; original-location stub 0x140839A30).
// It maps an internal session event code (0..0x22) to ERescueSignalState at this+0xE08; events 0x1F and 0x20
// set 4 = EndOfCooperativeMode (Ghidra, 2026-10-26). Called indirectly (no direct calls to the stub).
#define ADDR_SESSION_STATE_HANDLER 0x146EA3AC0ULL
#define OFF_RESCUE_SIGNAL_STATE 0xE08
typedef void (*state_fn)(uint8_t *self, uint32_t a2, uint32_t event);
static state_fn g_orig_state_handler;

// The handler above is only the "on enter state" notification (veto there did not hold, 2-PC test 2026-10-26): the state
// machine stores the new internal state at this+0xD90 before notifying. It only logs now.
static void note_rest_event(void *frame);
static void detour_state_handler(uint8_t *self, uint32_t a2, uint32_t event) {
    void *caller = __builtin_return_address(0);
    void *frames[12];
    USHORT n = RtlCaptureStackBackTrace(1, 12, frames, NULL);
    uint8_t before = self[OFF_RESCUE_SIGNAL_STATE];
    g_orig_state_handler(self, a2, event);
    char bt[12 * 20] = "";
    for (USHORT i = 0; i < n; i++) {
        char one[20];
        snprintf(one, sizeof one, " %llX", (unsigned long long)(uintptr_t)frames[i]);
        strcat_s(bt, sizeof bt, one);
    }
    logf_("SESSION EVENT 0x%02X (a2=%u) state %u -> %u, caller %llX, backtrace:%s",
          event, a2, before, self[OFF_RESCUE_SIGNAL_STATE], (unsigned long long)(uintptr_t)caller, bt);
    if (event == 0x16 && n > 1) note_rest_event(frames[1]);
}

// Veto experiment (off by default): AppSessionManager "EndCooperativeMode" (stub 0x140832D70, body 0x146E92EF0; only direct
// caller 0x146966279, a player-death handler). With no other players it switches the internal state (+0xD90) to 0x1F at once;
// otherwise it sets the request flag +0xDC0, which 0x14081C940 turns into 0x1F shortly after. Skipping the whole function while
// CoopNative.ini has veto_endcoop=1 AND CoopNative.flags reports a spectate window (boss fight, one player dead, one alive)
// keeps both the request and the state change from happening. Needed on host and guest (each ends co-op on its own side).
#define ADDR_END_COOP_BODY 0x146E92EF0ULL
static volatile LONG g_veto_enabled, g_spectate_window;

// Session 7: a boss kill calls EndCooperativeMode ~2 s after MulticastGainRewards; the polled flag was 0.3 s stale and the veto
// stalled the host's outro on a black screen. Re-read the flag file at the moment of the decision instead.
static int read_small_file(const char *name, char *buf, size_t size);
static int window_now(void) {
    char buf[8];
    LONG win = read_small_file("CoopNative.flags", buf, sizeof buf) && buf[0] == '1';
    InterlockedExchange(&g_spectate_window, win);
    return win;
}

static void detour_end_coop(void *sm) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (g_veto_enabled && window_now()) {
        logf_("EndCooperativeMode from 0x%llX  *** VETOED (spectate window) ***", (unsigned long long)caller);
        g_vetoed_sm = sm; InterlockedExchange(&g_vetoed_kind, 2);
        return;
    }
    logf_("EndCooperativeMode from 0x%llX (allowed)", (unsigned long long)caller);
    g_orig_end_coop(sm);
}

// Session 7 (2026-10-27): with the EndCooperativeMode veto on, both sides still ended co-op through 0x14081BDA0 (in .xtls, not
// Denuvo-moved), the small "switch the internal state to 0x1F" function that EndCooperativeMode has inlined. The guest reached it
// from a Blueprint-called native (return 0x14633CFA0, after getting the session manager); the host from the session monitor
// (return 0x146E653C0) once no other player was left. Veto it in the spectate window, except from the monitor: when the other
// player is really gone, the host must end co-op.
#define ADDR_SWITCH_END_COOP 0x14081BDA0ULL
#define CALLER_NO_PLAYERS_LEFT 0x146E653C0ULL

// Group teleport (session 9 two-PC test): the host's Mistle teleport calls SwitchToEndCoop from 0x146678D02 in the same
// millisecond as RequestPlayerSpawnToCheckPoint and the session ended (guest disconnected). Never seen from anywhere else, so with
// group_teleport=1 that caller is vetoed and the guest stays in the session for the follow-up spawn.
#define CALLER_TELEPORT_END_COOP 0x146678D02ULL
// Far teleport (session 9, St09 -> another stage): ~1 s after the arrival a second end came from 0x146D627CF (area-entry handling,
// behind check 0x140829370; also seen once after a solo cross-area teleport) and ended the session. Vetoed for 60 s after a
// group teleport starts, logged at most once a second, to see whether the game keeps retrying.
#define CALLER_AREA_END_COOP 0x146D627CFULL
static volatile ULONGLONG g_tp_started_at, g_last_area_veto_log;
static volatile LONG g_area_vetoes;
static volatile LONG g_group_teleport;
// Home Base (session 9): a separate map. Vanilla ends co-op and then travels there; with the vetoes the host was spawned at the
// Home Base spot inside the field map, fell into a pit and died. The teleport's destination comes from the native implementation
// 0x1409A1800(component, FieldID, PointIndex) (called by the RequestPlayerSpawnToCheckPoint thunk); destinations listed in
// teleport_skip_fields=<id>,<id> (CoopNative.ini) keep the vanilla behaviour. Every teleport logs its FieldID/PointIndex.
#define ADDR_SPAWN_TO_CHECKPOINT_IMPL 0x1409A1800ULL
// (all three: 12 arguments passed through, so stack arguments 5+ reach the original unchanged; 4 broke a boss intro, session 9)
typedef uint64_t (*spawnimpl_fn)(void *self, int64_t field, int64_t point, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l);
static spawnimpl_fn g_orig_spawn_impl;
static volatile LONG g_tp_skip;            // 1 while the current teleport goes to a skipped destination
static volatile ULONGLONG g_hb_at;         // Home Base teleport with the session kept: start
static void rec_window(int seconds, const char *why);
static int g_skip_fields[16], g_skip_n;
static uint64_t detour_spawn_impl(void *self, int64_t field, int64_t point, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l) {
    int skip = 0;
    int fid = (int)field, pid = (int)point;   // 32-bit ints in edx/r8d; the upper halves are not defined
    for (int i = 0; i < g_skip_n; i++) if (g_skip_fields[i] == fid) skip = 1;
    InterlockedExchange(&g_tp_skip, skip);
    logf_("teleport destination: FieldID %d, PointIndex %d%s", fid, pid, skip ? "  (teleport_skip_fields: vanilla behaviour)" : "");
    if (fid == 0 && !skip) {   // Home Base with the session kept (2026-11-06): CoopProbe watches the levels and holds the character
        g_hb_at = GetTickCount64();
        rec_window(85, "Home Base trip");
        char hp[MAX_PATH + 32];
        snprintf(hp, sizeof hp, "%sCoopNative.hbwatch", g_dir);
        FILE *hf = fopen(hp, "w");
        if (hf) { fputs("1", hf); fclose(hf); }
    }
    return g_orig_spawn_impl(self, field, point, d, e, f, g, h, i, j, k, l);
}
// Second far-teleport test: with that veto the same area-entry code went on to 0x1409F1BA0 (called from 0x146D62972, result
// unused), which showed "multiplayer is not possible in this area" and ended co-op through a Blueprint path (state 0x1F from
// 0x146E85B35). That call is skipped in the same 60 s window.
#define ADDR_AREA_NOTIFY 0x1409F1BA0ULL
#define CALLER_AREA_NOTIFY 0x146D62977ULL
typedef uint64_t (*areanotify_fn)(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l);
static areanotify_fn g_orig_area_notify;
static int in_teleport_window(void);
static uint64_t detour_area_notify(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l) {
    if ((uintptr_t)__builtin_return_address(0) == CALLER_AREA_NOTIFY) {
        if ((g_group_teleport || g_keep_outro) && in_teleport_window()) {
            logf_("teleport: area-entry \"no multiplayer here\" step skipped (group_teleport)");
            return 0;
        }
        logf_("area-entry \"no multiplayer here\" step (allowed)");
    }
    return g_orig_area_notify(a, b, c, d, e, f, g, h, i, j, k, l);
}
// Just before that call the teleport code shows "ending the co-op activity / distress signal" (IsOnlineMultiplay picks the text,
// then 0x14083A630(ctx, text); return value unused there). With group_teleport=1 the call from that spot is skipped.
#define ADDR_SHOW_SESSION_MESSAGE 0x14083A630ULL
#define CALLER_TELEPORT_MESSAGE 0x146678CFAULL
typedef uint64_t (*showmsg_fn)(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l);
static showmsg_fn g_orig_show_msg;
static uint64_t detour_show_msg(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l) {
    if (g_group_teleport && !g_tp_skip && (uintptr_t)__builtin_return_address(0) == CALLER_TELEPORT_MESSAGE) {
        logf_("teleport: \"ending co-op / distress signal\" message skipped (group_teleport)");
        return 0;
    }
    return g_orig_show_msg(a, b, c, d, e, f, g, h, i, j, k, l);
}
// session 10: also for 10 minutes after a boss kill with keep_outro=1 (entering the memory area ran the same area-entry check and
// ended co-op, 07:11:55)
static volatile ULONGLONG g_outro_at, g_bosskill_at;   // bosskill: any MulticastFinishBossBattle (also solo)
static int in_teleport_window(void) {
    ULONGLONG now = GetTickCount64();
    return (g_tp_started_at && now - g_tp_started_at < 60000) || (g_keep_outro && g_outro_at && now - g_outro_at < 600000);
}
static void detour_switch_end_coop(void *sm) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (g_group_teleport && caller == CALLER_TELEPORT_END_COOP && !g_tp_skip) {
        logf_("SwitchToEndCoop from 0x%llX  *** VETOED (group_teleport: Mistle teleport) ***", (unsigned long long)caller);
        g_tp_started_at = GetTickCount64();
        return;
    }
    if ((g_group_teleport || g_keep_outro) && caller == CALLER_AREA_END_COOP && in_teleport_window()) {
        LONG n = InterlockedIncrement(&g_area_vetoes);
        ULONGLONG now = GetTickCount64();
        if (now - g_last_area_veto_log > 1000) {
            g_last_area_veto_log = now;
            logf_("SwitchToEndCoop from 0x%llX  *** VETOED (group_teleport: area entry, %ld so far) ***", (unsigned long long)caller, n);
        }
        return;
    }
    if (g_veto_enabled && caller != CALLER_NO_PLAYERS_LEFT && window_now()) {
        logf_("SwitchToEndCoop from 0x%llX  *** VETOED (spectate window) ***", (unsigned long long)caller);
        g_vetoed_sm = sm; InterlockedExchange(&g_vetoed_kind, 1);
        return;
    }
    rec_window(20, "session end");
    logf_("SwitchToEndCoop from 0x%llX (allowed)", (unsigned long long)caller);
    g_orig_switch_end_coop(sm);
}

// R1 (rest at a Mistle in co-op), off unless CoopNative.ini has rest_in_coop=1. The Mistle's IsActionButtonActive override
// (vtable 0x142D09658 +0x660 -> stub 0x1406AF330 -> body 0x1469781B0) greys the prompt out when IsOnlineMultiplay() is true
// (Ghidra 2026-10-26). We answer "false" to IsOnlineMultiplay only for calls coming from inside that function.
#define ADDR_IS_ONLINE_MULTIPLAY_BODY 0x146E7BC90ULL   // impl stub 0x140828C80
#define MISTLE_PROMPT_BEGIN 0x1469781B0ULL
#define MISTLE_PROMPT_END   0x1469782E0ULL               // past the last return seen in the decompile
typedef uint8_t (*multiplay_fn)(void *ctx);
static multiplay_fn g_orig_multiplay;
static volatile LONG g_rest_in_coop, g_rest_overrides;

// The rest action: the Mistle's ProcessInputButtonEvent (vtable +0x618 -> stub 0x1406BB510 -> body 0x146A1CB70) starts with
// "if ((state != Opened || !MultiPlayersCheck()) && pressed) { rest }" (Ghidra 2026-10-26); the call is near the start.
#define MISTLE_INPUT_BEGIN 0x146A1CB70ULL
#define MISTLE_INPUT_END   0x146A1CC00ULL
static int from_mistle_prompt(uintptr_t caller) {
    return (caller >= MISTLE_PROMPT_BEGIN && caller < MISTLE_PROMPT_END) ||
           (caller >= MISTLE_INPUT_BEGIN && caller < MISTLE_INPUT_END);
}

// While rest_in_coop is on, log every distinct caller (outside the prompt) that gets "true" from one of the three
// co-op checks, so the check behind the rest action itself shows up when the player presses E.
#define MAX_CALLERS 64
static volatile LONG64 g_seen[3][MAX_CALLERS];
// Item 6 research (2026-10-30): enemies do not respawn on a co-op rest; the reset callers above were not even called at the last
// rests. For 120 s after each rest start, log every distinct caller of IsOnlineMultiplay / MultiPlayersCheck with its answer (also
// solo, where they answer false), so a solo rest and a co-op rest can be compared.
static volatile LONG64 g_rest_seen[2][MAX_CALLERS];
static volatile ULONGLONG g_rest_log_from;
static void note_rest_caller(int which, uintptr_t caller, int answer) {
    static const char *names[2] = {"IsOnlineMultiplay", "MultiPlayersCheck"};
    if (!g_rest_log_from || GetTickCount64() - g_rest_log_from > 120000) return;
    LONG64 key = (LONG64)(caller | ((uintptr_t)(answer & 1) << 63));
    for (int i = 0; i < MAX_CALLERS; i++) {
        LONG64 v = g_rest_seen[which][i];
        if (v == key) return;
        if (v == 0 && InterlockedCompareExchange64(&g_rest_seen[which][i], key, 0) == 0) {
            logf_("rest window: %s from 0x%llX -> %d (+%llu ms)", names[which], (unsigned long long)caller, answer,
                  (unsigned long long)(GetTickCount64() - g_rest_log_from));
            return;
        }
    }
}
static void start_rest_log(const char *why) {
    for (int w = 0; w < 2; w++) for (int i = 0; i < MAX_CALLERS; i++) g_rest_seen[w][i] = 0;
    g_rest_log_from = GetTickCount64();
    logf_("rest window: logging co-op checks for 120 s (%s)", why);
}
static void note_caller(int which, uintptr_t caller) {
    static const char *names[3] = {"IsOnlineMultiplay", "MultiPlayersCheck", "PromptBlock1"};
    for (int i = 0; i < MAX_CALLERS; i++) {
        LONG64 v = g_seen[which][i];
        if (v == (LONG64)caller) return;
        if (v == 0 && InterlockedCompareExchange64(&g_seen[which][i], (LONG64)caller, 0) == 0) {
            logf_("new caller of %s returning true: 0x%llX", names[which], (unsigned long long)caller);
            return;
        }
    }
}

// R6, the guest's own rest (guest_rest=1, guest only; session 8). With rest_in_coop his E press starts the vanilla rest, which asks
// the session to close the enemy-reset channel: CloseOnlineSession (stub 0x1408176A0 -> body 0x146E5C3D0(world context, bits)),
// called with 8 from the Mistle's ProcessInputButtonEvent. On the host that runs session events 0x16 -> 0x17 -> 0x18 and the rest goes
// on; on a guest only 0x16 -> 0x19 came and he sat at the Mistle for good. On the guest, answer "done" for that call without touching
// the session: the host's world is not reset by his rest, and his rest no longer waits for the session.
#define ADDR_CLOSE_SESSION 0x1408176A0ULL
typedef uint64_t (*closesession_fn)(void *ctx, uint8_t bits);
static closesession_fn g_orig_close_session;
static volatile LONG g_guest_rest;
static uint64_t detour_close_session(void *ctx, uint8_t bits) {
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (bits == 8 && caller >= 0x146A1CB70ULL && caller < 0x146A1CB70ULL + 0x800) start_rest_log("CloseOnlineSession(8) from the Mistle input");
    if (g_guest_rest && bits == 8 && caller >= 0x146A1CB70ULL && caller < 0x146A1CB70ULL + 0x800) {
        logf_("CloseOnlineSession(8) from the Mistle input 0x%llX  *** SKIPPED (guest_rest) ***", (unsigned long long)caller);
        return 1;
    }
    return g_orig_close_session(ctx, bits);
}

// R6 v2: skipping the session part was not enough: the rest also changes the Mistle actor itself and asserted on the guest
// (CheckPointBase.cpp:850). With guest_rest=1 the guest's E press at an opened Mistle no longer runs the Mistle's
// ProcessInputButtonEvent (vtable +0x618 -> stub 0x1406BB510 -> body 0x146A1CB70(mistle, pressed, character)) at all; CoopNative
// writes CoopNative.restreq and CoopProbe opens his Mistle menu directly (BP_CheckpointUIComponent:Open, validated on the host).
#define ADDR_MISTLE_INPUT 0x1406BB510ULL
static char g_dir[MAX_PATH];   // defined (tentatively) again further down
typedef void (*mistleinput_fn)(void *mistle, uint8_t pressed, void *character);
static mistleinput_fn g_orig_mistle_input;
static void detour_mistle_input(void *mistle, uint8_t pressed, void *character) {
    if (g_guest_rest && pressed == 1 && mistle && readable((uintptr_t)mistle + 0x660, 1) && *((uint8_t *)mistle + 0x660) == 2) {
        // item 7 (2026-10-30 20:51): his game crashed (inside UE4SS, null read) opening the menu while the host sat at the Mistle.
        // ACheckPointBase.InputterHolder (+0x6C0) = the character using it; while that is someone else, open nothing
        uintptr_t holder = readable((uintptr_t)mistle + 0x6C0, 8) ? *(uintptr_t *)((uintptr_t)mistle + 0x6C0) : 0;
        if (holder && holder != (uintptr_t)character) {
            logf_("Mistle input at 0x%llX: in use by 0x%llX (the host rests) -> menu NOT opened", (unsigned long long)(uintptr_t)mistle,
                  (unsigned long long)holder);
            return;
        }
        char path[MAX_PATH];
        snprintf(path, sizeof path, "%sCoopNative.restreq", g_dir);
        FILE *f = _fsopen(path, "w", _SH_DENYNO);
        if (f) { fputs("1", f); fclose(f); }
        logf_("Mistle input at 0x%llX  *** vanilla rest SKIPPED (guest_rest), menu requested *** (holder 0x%llX)", (unsigned long long)(uintptr_t)mistle,
              (unsigned long long)holder);
        return;
    }
    g_orig_mistle_input(mistle, pressed, character);
}

// Enemy reset on a co-op rest (session 7: the host rested, enemies stayed). During those rests two more callers got "true" from
// IsOnlineMultiplay: 0x1465871A7 ("if multiplayer, an extra condition must hold, else skip") and 0x1462711CE (branches on
// multiplayer). Guess, to be tested: answer "false" to those two for 6 s after a rest starts (session event 0x16 raised from the
// Mistle's ProcessInputButtonEvent).
#define REST_RESET_CALLER1 0x1465871A7ULL
#define REST_RESET_CALLER2 0x1462711CEULL
#define REST_WINDOW_MS 120000   // the reset check comes when the player leaves the Mistle (session 8: 19 s after sitting down)
static volatile ULONGLONG g_rest_started;
static volatile LONG g_reset_overrides;
static int in_rest_window(void) { return g_rest_started && GetTickCount64() - g_rest_started < REST_WINDOW_MS; }
// Session event 0x16 raised from the Mistle's input function (frame 2 in session 7) = a rest just started.
static void note_rest_event(void *frame) {
    uintptr_t f = (uintptr_t)frame;
    if (!g_rest_in_coop || f < MISTLE_INPUT_BEGIN || f >= MISTLE_INPUT_BEGIN + 0x800) return;
    g_rest_started = GetTickCount64();
    logf_("rest_in_coop: rest started, enemy-reset overrides active for %d ms", REST_WINDOW_MS);
}

// Talking to NPCs as a guest (2026-11-06): BP_ScenarioStarter:ProcessInputButtonEvent shows "Unable to start the conversation in online mode"
// when AppOnlineWrapper:IsOnlineMultiplay is true and GetHostActor != Inputter. Blueprint functions cannot be hooked on our UE4SS, so the
// exec thunk of IsOnlineMultiplay answers false when the calling script function has that name (FFrame+0x10 = Node, UObject+0x18 = FName
// index; the index comes from CoopProbe: "talkfn <hex>"). Every other caller gets the real answer.
#define ADDR_EXEC_ONLINE_MULTIPLAY 0x140A056C0ULL
static exec_fn g_orig_exec_multiplay;
static volatile LONG g_talk_name = -1, g_talk_answers;
static void detour_exec_multiplay(void *ctx, void *stack, void *result) {
    g_orig_exec_multiplay(ctx, stack, result);
    LONG want = g_talk_name;
    if (want >= 0 && stack && result) {
        uintptr_t node = *(uintptr_t *)((uintptr_t)stack + 0x10);
        if (node && *(int *)(node + 0x18) == want && *(uint8_t *)result) {
            *(uint8_t *)result = 0;
            if (InterlockedIncrement(&g_talk_answers) <= 20) logf_("talk: IsOnlineMultiplay answered false for ProcessInputButtonEvent (Node 0x%llX, object 0x%llX)", (unsigned long long)node, (unsigned long long)*(uintptr_t *)((uintptr_t)stack + 0x18));
        }
    }
}

// Recording round (2026-11-06, rec=1 in the ini; none of this is hooked without it). Log only: what the game itself does with NPCs on each PC.
// Lines start with "rec ". Windows (rec_window) reset the per-kind caps, so every event of interest gets its own share of the log.
//   setvis/hide   SetProgressVisibility impl 0x140913E80, hide-all-components 0x140913E90
//   onrep         exec OnRepProgressVisibility: the replicated value really arrived here
//   npcstart      NPC start 0x1408E54F0 (+0xBD8 value, +0xBD9 a replicated value is waiting, +0xBDA started)
//   unique        duplicate pick 0x14090C6A0: did the Destroy work on this PC? (UE refuses it without authority)
//   exclude       ExcludeCharacters 0x1408F2DA0
//   release       +0xB84 drop 0x140448000 and 0x140447ED0 with a backtrace: who finishes a character's setup
//   flag          UScenarioManager::SetProgressFlag 0x140913590 (does nothing on a guest: shows what his game tried)
//   lock          [404]/[408]/[40C]/block sampled every 50 ms inside a window, on change
//   raw           census of the addresses in CoopNative.recset (command "reccensus")
static volatile LONG g_rec;
static volatile ULONGLONG g_rec_until;
static volatile LONG g_rec_win[8];
#define REC_CAP(kind, cap) (g_rec && InterlockedIncrement(&g_rec_win[kind]) <= (cap))
static void rec_window(int seconds, const char *why) {
    if (!g_rec) return;
    g_rec_until = GetTickCount64() + (ULONGLONG)seconds * 1000;
    for (int i = 0; i < 8; i++) InterlockedExchange(&g_rec_win[i], 0);
    logf_("rec window: %d s (%s)", seconds, why);
}
static int rec_killed(uintptr_t o) {   // bit 29 of the FUObjectItem flags, as the game checks it
    if (o < 0x10000 || !readable(o + 0xC, 4)) return -1;
    int idx = *(int *)(o + 0xC);
    uintptr_t base = *(volatile uintptr_t *)0x14429EC50ULL;
    if (idx < 0 || idx >= *(volatile int *)0x14429EC5CULL || !base || !readable(base + (uintptr_t)idx * 0x18 + 8, 4)) return -1;
    return (int)((*(uint32_t *)(base + (uintptr_t)idx * 0x18 + 8) >> 29) & 1);
}
static int rec_client_flag(void) {     // what 0x141EBAA10 (IsServer) reads: [0x144380950]+0xE39, 0 = server
    uintptr_t g = *(volatile uintptr_t *)0x144380950ULL;
    return g && readable(g + 0xE39, 1) ? *(uint8_t *)(g + 0xE39) : -1;
}
static void rec_bt(char *out, size_t size) {
    void *f[14];
    USHORT n = RtlCaptureStackBackTrace(2, 14, f, NULL);
    size_t at = 0;
    out[0] = 0;
    for (USHORT i = 0; i < n && at + 20 < size; i++) at += (size_t)snprintf(out + at, size - at, " %llX", (unsigned long long)(uintptr_t)f[i]);
}
typedef void (*rec_v1)(void *self);
typedef void (*rec_vb)(void *self, char v);
typedef uint64_t (*rec_r4)(uint64_t a, uint64_t b, uint64_t c, uint64_t d);
static rec_vb g_orig_setvis, g_orig_hide;
static void detour_setvis(void *self, char v) {
    uintptr_t a = (uintptr_t)self;
    if (REC_CAP(0, 250) && readable(a + 0xBD8, 4) && readable(a + 0x118, 2))
        logf_("rec setvis 0x%llX -> %d (value %u, waiting %u, started %u, role %u)", (unsigned long long)a, (int)v, *(uint8_t *)(a + 0xBD8),
              *(uint8_t *)(a + 0xBD9), *(uint8_t *)(a + 0xBDA), *(uint8_t *)(a + 0x118));
    g_orig_setvis(self, v);
}
static void detour_hide(void *self, char v) {
    uintptr_t a = (uintptr_t)self;
    if (REC_CAP(1, 250) && readable(a + 0xBD8, 4) && readable(a + 0x118, 2))
        logf_("rec hide 0x%llX hide=%d (value %u, waiting %u, started %u, role %u)", (unsigned long long)a, (int)v, *(uint8_t *)(a + 0xBD8),
              *(uint8_t *)(a + 0xBD9), *(uint8_t *)(a + 0xBDA), *(uint8_t *)(a + 0x118));
    g_orig_hide(self, v);
}
static exec_fn g_orig_onrep;
static void detour_onrep(void *ctx, void *stack, void *result) {
    uintptr_t a = (uintptr_t)ctx;
    if (REC_CAP(2, 300) && readable(a + 0xBD8, 4))
        logf_("rec onrep 0x%llX value %u, started %u", (unsigned long long)a, *(uint8_t *)(a + 0xBD8), *(uint8_t *)(a + 0xBDA));
    g_orig_onrep(ctx, stack, result);
}
static rec_v1 g_orig_npc_start;
static void detour_npc_start(void *self) {
    uintptr_t a = (uintptr_t)self;
    if (REC_CAP(4, 300) && readable(a + 0xBD8, 4) && readable(a + 0x118, 2))
        logf_("rec npcstart 0x%llX value %u, waiting %u, role %u, dormancy %u", (unsigned long long)a, *(uint8_t *)(a + 0xBD8), *(uint8_t *)(a + 0xBD9),
              *(uint8_t *)(a + 0x118), *(uint8_t *)(a + 0x119));
    g_orig_npc_start(self);
}
typedef struct { uintptr_t *data; int num; int max; } rec_ptrs;
typedef void (*rec_unique_fn)(void *self, rec_ptrs *a);
static rec_unique_fn g_orig_unique;
static void detour_unique(void *self, rec_ptrs *a) {
    uintptr_t c[6]; int n = a && a->data ? a->num : 0;
    if (n > 6) n = 6;
    for (int i = 0; i < n; i++) c[i] = a->data[i];
    g_orig_unique(self, a);
    if (!g_rec) return;
    char line[260]; size_t at = 0; line[0] = 0;
    for (int i = 0; i < n && at + 44 < sizeof line; i++)
        at += (size_t)snprintf(line + at, sizeof line - at, " 0x%llX role %d gone %d", (unsigned long long)c[i],
                               readable(c[i] + 0x118, 1) ? *(uint8_t *)(c[i] + 0x118) : -1, rec_killed(c[i]));
    logf_("rec unique: %d of one character:%s", n, line);
}
static rec_r4 g_orig_exclude, g_orig_relc, g_orig_relb;
static uint64_t detour_exclude(uint64_t self, uint64_t b, uint64_t c, uint64_t d) {
    uintptr_t a = (uintptr_t)self;
    int n0 = readable(a + 0x3B0, 4) ? *(int *)(a + 0x3A8) : -1;
    uint64_t r = g_orig_exclude(self, b, c, d);
    if (g_rec) logf_("rec exclude: loader 0x%llX, list %d before, %d after, tries %d", (unsigned long long)a, n0, readable(a + 0x3B0, 4) ? *(int *)(a + 0x3A8) : -1,
                     readable(a + 0x3B0, 4) ? *(int *)(a + 0x3B0) : -1);
    return r;
}
static void rec_release_log(const char *kind, uintptr_t a) {
    char bt[300];
    if (!g_rec || a < 0x10000 || !readable(a + 0xB80, 8) || *(uint8_t *)(a + 0xB84) != 1 || !REC_CAP(3, 120)) return;
    rec_bt(bt, sizeof bt);
    logf_("rec release %s 0x%llX (b83 %u b84 %u b85 %u, count %d, b84 holders %d) backtrace:%s", kind, (unsigned long long)a, *(uint8_t *)(a + 0xB83),
          *(uint8_t *)(a + 0xB84), *(uint8_t *)(a + 0xB85), *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C40CULL, bt);
}
static uint64_t detour_relc(uint64_t o, uint64_t b, uint64_t c, uint64_t d) {
    rec_release_log("C", (uintptr_t)o);
    return g_orig_relc(o, b, c, d);
}
static uint64_t detour_relb(uint64_t o, uint64_t b, uint64_t c, uint64_t d) {
    rec_release_log("B", (uintptr_t)o);
    return g_orig_relb(o, b, c, d);
}
typedef void (*rec_flag_fn)(void *world, uint64_t *fstr, char v);
static rec_flag_fn g_orig_setflag;
static void detour_setflag(void *world, uint64_t *fstr, char v) {
    if (REC_CAP(5, 600) && fstr && fstr[0] && readable(fstr[0], 2)) {
        char s[90]; int n = *(int *)(fstr + 1), i = 0;
        const uint16_t *w = (const uint16_t *)(uintptr_t)fstr[0];
        if (n > 88) n = 88;
        for (; i < n && w[i]; i++) s[i] = w[i] < 127 ? (char)w[i] : '?';
        s[i] = 0;
        logf_("rec flag %s -> %d (client flag %d)", s, (int)v, rec_client_flag());
    }
    g_orig_setflag(world, fstr, v);
}
static void rec_census(void) {
    static char rb[8192];
    logf_("rec raw census: client flag %d, count %d, b85 holders %d, b84 holders %d, block %s", rec_client_flag(), *(volatile int *)0x14413C404ULL,
          *(volatile int *)0x14413C408ULL, *(volatile int *)0x14413C40CULL, *(volatile uint64_t *)0x14413C410ULL == ~0ULL ? "forever" : "frame");
    if (!read_small_file("CoopNative.recset", rb, sizeof rb)) return;
    char *q = rb;
    while (*q) {
        char *end; unsigned long long v = strtoull(q, &end, 16);
        if (end == q) break;
        uintptr_t a = (uintptr_t)v;
        if (a > 0x10000 && readable(a + 0x8C, 4) && readable(a + 0x118, 2) && readable(a + 0xB80, 8) && readable(a + 0xBD8, 4) && readable(a + 0xC10, 4) && readable(a + 0x35, 3))
            logf_("rec raw 0x%llX vt %llX net %02X %02X %02X role %u/%u dormancy %u | kind %u reports %d ba0 %u | b81-85 %u%u%u%u%u | value %u waiting %u started %u | c10-12 %u%u%u | tick %u%u | gone %d", v, *(unsigned long long *)a,
                  *(uint8_t *)(a + 0x8C), *(uint8_t *)(a + 0x8D), *(uint8_t *)(a + 0x8E), *(uint8_t *)(a + 0x118), *(uint8_t *)(a + 0x8F), *(uint8_t *)(a + 0x119),
                  *(uint8_t *)(a + 0xB80), *(int *)(a + 0xB9C), *(uint8_t *)(a + 0xBA0),
                  *(uint8_t *)(a + 0xB81), *(uint8_t *)(a + 0xB82), *(uint8_t *)(a + 0xB83), *(uint8_t *)(a + 0xB84), *(uint8_t *)(a + 0xB85),
                  *(uint8_t *)(a + 0xBD8), *(uint8_t *)(a + 0xBD9), *(uint8_t *)(a + 0xBDA), *(uint8_t *)(a + 0xC10), *(uint8_t *)(a + 0xC11), *(uint8_t *)(a + 0xC12),
                  *(uint8_t *)(a + 0x35), *(uint8_t *)(a + 0x37), rec_killed(a));
        q = end; while (*q == ' ') q++;
    }
}
static DWORD WINAPI rec_thread(LPVOID unused) {
    (void)unused;
    int p4 = -99, p8 = -99, pc = -99, pb = -1;
    for (;;) {
        Sleep(50);
        if (!g_rec || GetTickCount64() > g_rec_until) continue;
        int c4 = *(volatile int *)0x14413C404ULL, c8 = *(volatile int *)0x14413C408ULL, cc = *(volatile int *)0x14413C40CULL;
        int fb = *(volatile uint64_t *)0x14413C410ULL == ~0ULL;
        if (c4 == p4 && c8 == p8 && cc == pc && fb == pb) continue;
        p4 = c4; p8 = c8; pc = cc; pb = fb;
        if (REC_CAP(6, 500)) logf_("rec lock: count %d, b85 holders %d, b84 holders %d, block %s", c4, c8, cc, fb ? "forever" : "frame");
    }
}

// NPC layouts (2026-11-06): each area's ScenarioProgressLoader (Base01: SelectMap) picks its NPC layout with RandomChoice, so the two PCs loaded
// different layouts, hence "the same NPCs in different places" and NPCs that are not on the host's screen. Hiding them afterwards was the wrong
// end: with the same story flags and the same pick both games load the same level by themselves. Inner function of the exec thunk (only caller
// 0x148FBF33F): (loader, FName *out, TArray<FChoiceContainer> *), element 0x10 bytes: FName, float Weight. The first entry with a weight wins.
// Off with layout_fixed=0.
#define ADDR_LAYOUT_CHOICE 0x14090C3C0ULL
typedef struct { uint8_t *data; int num; int max; } choice_array;
typedef uint64_t *(*layout_fn)(void *self, uint64_t *out, choice_array *a);
static layout_fn g_orig_layout_choice;
static volatile LONG g_layout_random, g_layout_logs;
static uint64_t *detour_layout_choice(void *self, uint64_t *out, choice_array *a) {
    // read everything BEFORE the call: the array is a by-value argument, the callee frees it (11-06 13:46: reading it afterwards gave a garbage
    // name, and ToString on that name in the "rec stream" hook crashed the host at Home Base)
    int pick = -1, num = 0;
    uint64_t want = 0;
    if (!g_layout_random && a && a->data && a->num > 0) {
        num = a->num;
        pick = 0;
        for (int i = 0; i < a->num; i++) if (*(float *)(a->data + i * 0x10 + 8) > 0.0f) { pick = i; break; }
        want = *(uint64_t *)(a->data + pick * 0x10);
    }
    uint64_t *r = g_orig_layout_choice(self, out, a);
    if (pick < 0 || !r) return r;
    uint64_t rolled = *r;
    *r = want;
    if (InterlockedIncrement(&g_layout_logs) <= 40)
        logf_("layout: %d choices, rolled name %u, fixed to entry %d name %u", num, (unsigned)rolled, pick, (unsigned)want);
    return r;
}

// Post-boss outro (session 10): the "large-poly prepared" check 0x14705DE20 (polled by ScenarioActor:WaitForPreparePolyFinished)
// needs the manager's +0x20C (own models ready) and, when IsOnlineMultiplay is true, also +0x20D, which the guest's game never
// sets; the host hung there until the guest left. With keep_outro=1 that one call is answered "not multiplayer".
#define OUTRO_POLY_CALLER 0x14705DE3FULL
// Second stage (same day): after the cutscene, WaitForLargePolyFinished's sync check (function around 0x147061370) returns true when
// not in multiplayer, else the manager's +0x20E (the partner finished the cutscene; also what skipping waits for). Same treatment.
#define OUTRO_POLY_END_CALLER 0x1470613D3ULL
// A scan of the exe (every CALL to IsOnlineMultiplay followed by a byte compare in +0x200..+0x23F) finds exactly four such
// checks in this manager: 0x14705DE3F (+0x20C/+0x20D prepared), 0x1470613D3 (+0x20E), 0x147050AB8 (+0x20F/+0x210, the cutscene's
// own finished check, where test 3 hung) and 0x14705DD11 (+0x211/+0x212). All four get the same answer.
#define OUTRO_POLY_FIN_CALLER 0x147050AB8ULL
#define OUTRO_POLY_X_CALLER 0x14705DD11ULL
static volatile ULONGLONG g_last_poly_log;
static uint8_t detour_multiplay(void *ctx) {
    uint8_t r = g_orig_multiplay(ctx);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    note_rest_caller(0, caller, r);
    // Character setup 0x145DA0600 (recording 11-06): online, the host keeps a character in setup until every guest has reported it (+0xB9C >= players - 1,
    // retried every tick; solo it just finishes). The Home Base NPCs (22: layout + ForFastLoad) are not relevant to a guest who is still far away, so
    // no report came, the appear lock stayed shut and the host's own arrival hung with it, until the session ended: IsOnlineMultiplay false, all finished
    // within 2 ms. Story NPCs take the solo way during a Home Base trip, on each PC. Their visibility comes from the layout there, both PCs have the same one.
    if (r && caller == 0x145DA0630ULL && g_hb_at && GetTickCount64() - g_hb_at < 300000 && ctx && readable((uintptr_t)ctx, 8) &&
        *(uint64_t *)ctx == 0x142D8C268ULL) {
        static volatile LONG npc_solo;
        if (InterlockedIncrement(&npc_solo) <= 60)
            logf_("hb: NPC 0x%llX takes the solo setup (reports %d)", (unsigned long long)(uintptr_t)ctx, readable((uintptr_t)ctx + 0xB9C, 4) ? *(int *)((uintptr_t)ctx + 0xB9C) : -1);
        return 0;
    }
    // option A (session 10): the outro keeps the game's own sync (outro_partner_override=0); from the memory start on (15 min:
    // memory, its scenes, the cutscene out of it) the checks are answered again, so neither game waits for the other's copy
    int memwin = g_memory_start_at && GetTickCount64() - g_memory_start_at < 900000;
    // 2026-11-05: the trace showed both games send their ready reports in the memory and the final cutscene too; the 5 s gap between
    // the PCs came from the answer below (the guest did not wait for the host's load). The scene start now gets the game's real answer,
    // so each game waits for the other, for at most 10 s; then the old answer takes over, so a missing report cannot hang a scene.
    if (r && g_keep_outro && g_scene_wait && memwin && caller == OUTRO_POLY_CALLER) {
        static ULONGLONG start, lastp; static int gaveup;
        ULONGLONG now = GetTickCount64();
        if (now - lastp > 3000) { start = now; gaveup = 0; logf_("scene start: waiting for the other player (game's own sync, 10 s at most)"); }
        lastp = now;
        if (now - start < 10000) return r;
        if (!gaveup) { gaveup = 1; logf_("scene start: no report after 10 s -> not waiting any longer"); }
    }
    if (r && g_keep_outro && (g_partner_override || memwin) && (caller == OUTRO_POLY_CALLER || caller == OUTRO_POLY_END_CALLER || caller == OUTRO_POLY_FIN_CALLER ||
                              caller == OUTRO_POLY_X_CALLER)) {
        ULONGLONG now = GetTickCount64();
        if (now - g_last_poly_log > 2000) { g_last_poly_log = now; logf_("outro: large-poly check at 0x%llX answered \"not multiplayer\" (keep_outro)", (unsigned long long)caller); }
        return 0;
    }
    // item 10 (2026-10-30 21:13): pressing "Restore Vestige" with a guest showed "unavailable in multiplayer"; the only new
    // IsOnlineMultiplay caller at that moment was 0x14713D46D. With vestige_keep it is answered "not multiplayer"
    // 21:22: the next one (0x147143D7B, 0.9 s later) blocked the screen from opening; both sit in the restoration code, so the whole
    // stretch 0x14713D000..0x147145000 is answered (each new caller logged once)
    if (r && g_vestige_keep && caller >= 0x14713D000ULL && caller < 0x147145000ULL) {
        static uintptr_t seen_v[16];
        int known = 0;
        for (int i = 0; i < 16 && seen_v[i]; i++) if (seen_v[i] == caller) known = 1;
        if (!known) { for (int i = 0; i < 16; i++) if (!seen_v[i]) { seen_v[i] = caller; break; }
            logf_("vestige: check at 0x%llX answered \"not multiplayer\" (vestige_keep)", (unsigned long long)caller); }
        return 0;
    }
    if (r && g_rest_in_coop) {
        if (from_mistle_prompt(caller)) { InterlockedIncrement(&g_rest_overrides); return 0; }
        if ((caller == REST_RESET_CALLER1 || caller == REST_RESET_CALLER2) && in_rest_window()) {
            // item 6b (2026-10-30): the guest's rest should reset the enemies too; log the call chain of the reset (once per caller
            // and rest) to find an entry point the host can run on the guest's request
            static ULONGLONG bt_logged[2];
            int k = caller == REST_RESET_CALLER2;
            if (bt_logged[k] != g_rest_started) {
                bt_logged[k] = g_rest_started;
                void *frames[24];
                USHORT n = RtlCaptureStackBackTrace(1, 24, frames, NULL);
                char bt[24 * 20] = "";
                for (USHORT i = 0; i < n; i++) { char one[20]; snprintf(one, sizeof one, " %llX", (unsigned long long)(uintptr_t)frames[i]); strcat_s(bt, sizeof bt, one); }
                logf_("enemy reset: caller 0x%llX (ctx 0x%llX) backtrace:%s", (unsigned long long)caller, (unsigned long long)(uintptr_t)ctx, bt);
            }
            InterlockedIncrement(&g_reset_overrides); return 0;
        }
        note_caller(0, caller);
    }
    return r;
}

// Two more co-op checks in the same prompt (2-PC test 2026-10-26: overriding IsOnlineMultiplay alone was not enough):
// 0x140828970 (body 0x146E7AEF0) returns true when a counter difference on some game object is > 1 or another count > 0
// (reads like "more than one player"); the prompt calls it at the end, and through 0x140828AC0 (body 0x146E7B3C0:
// "0x140828970() && !0x1408285D0(x)") at the start. Both answer false only for calls from the Mistle prompt.
#define ADDR_MULTI_PLAYERS_BODY 0x146E7AEF0ULL
#define ADDR_PROMPT_BLOCK1_BODY 0x146E7B3C0ULL
typedef uint8_t (*check_fn)(void *a);
static check_fn g_orig_multi_players, g_orig_prompt_block1;

static uint8_t detour_multi_players(void *a) {
    uint8_t r = g_orig_multi_players(a);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    note_rest_caller(1, caller, r);
    if (r && g_rest_in_coop) {
        if (from_mistle_prompt(caller)) { InterlockedIncrement(&g_rest_overrides); return 0; }
        note_caller(1, caller);
    }
    return r;
}

static uint8_t detour_prompt_block1(void *a) {
    uint8_t r = g_orig_prompt_block1(a);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (r && g_rest_in_coop) {
        if (from_mistle_prompt(caller)) { InterlockedIncrement(&g_rest_overrides); return 0; }
        note_caller(2, caller);
    }
    return r;
}

// Home Base seats and jukeboxes for guests (2026-11-06, guest_seats=1 in the ini; none of this is hooked without it). What stopped him (kit 159 and the game's code):
//  1. AFieldTriggerBase / AFieldTriggerItemBase IsActionButtonActive (vtable +0x660) end in "is this the server": his prompt never turns on. CoopProbe lists the
//     seat and jukebox triggers in CoopNative.seats ("btn"), only those answer yes. Mistles, NPCs, chests have their own versions and stay as they are.
//  2. A seat gives the view to its camera with PlayerController:Possess, which does nothing without authority. On a guest, for a seat camera and for the way back,
//     the Possess exec thunk calls ClientRestart_Implementation (vtable +0x8B8) instead: what his PC does when the host hands him a pawn, so input, the seat camera
//     and the head run as on the host. The host's controller keeps his real character.
//  3. ClientRestart acknowledges the pawn to the server, and a pawn that is not the server's would make the host hand him back at once: the host drops an
//     acknowledge of a seat camera (or of none) in Home Base.
//  4. The seat's Blueprints use GetAllActorsOfClass(BP_Player_C)[0] as "the player". With two players that may be the other one, on the host too, where standing up
//     would Possess the guest's character. GetAllActorsOfClass puts our own character first while CoopNative.seats names it ("me").
#define ADDR_BTN_BASE            0x1406E7670ULL
#define ADDR_BTN_ITEM            0x1406E7860ULL
#define ADDR_EXEC_POSSESS        0x142314E40ULL
#define ADDR_EXEC_ACK_POSSESSION 0x1423D27D0ULL
#define ADDR_GET_ALL_ACTORS      0x141DF1430ULL
#define ADDR_FRAME_STEP          0x140EA1500ULL   // FFrame::Step(frame, object, result)
#define VT_POSSESS        0x670
#define VT_CLIENT_RESTART 0x8B8
typedef char (*btn_fn)(void *self, void *inputter);
typedef void (*pawn_fn)(void *pc, void *pawn);
typedef void (*frame_step_fn)(void *frame, void *object, void *result);
typedef void (*get_all_fn)(void *ctx, void *cls, rec_ptrs *out);
static volatile LONG g_seats_on, g_seat_logs, g_seat_ncam, g_seat_nbtn;
static volatile uintptr_t g_seat_me, g_seat_cam;
static uintptr_t g_seat_cams[64], g_seat_btns[64];
static btn_fn g_orig_btn_base, g_orig_btn_item;
static exec_fn g_orig_exec_possess, g_orig_exec_ack;
static get_all_fn g_orig_get_all;
static int seat_in(const uintptr_t *list, LONG n, uintptr_t a) {
    for (LONG i = 0; i < n && i < 64; i++) if (list[i] == a) return 1;
    return 0;
}
static int seat_log(void) { return InterlockedIncrement(&g_seat_logs) <= 40; }
static void btn_dyn_check(void);
static void seats_read(void) {
    static char sb[8192];
    if (!read_small_file("CoopNative.seats", sb, sizeof sb)) return;
    uintptr_t me = 0;
    LONG nc = 0, nb = 0;
    g_seat_ncam = 0; g_seat_nbtn = 0;
    char *line = sb;
    while (line && *line) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        int kind = strncmp(line, "me ", 3) == 0 ? 0 : strncmp(line, "cam ", 4) == 0 ? 1 : strncmp(line, "btn ", 4) == 0 ? 2 : -1;
        char *q = strchr(line, ' ');
        while (kind >= 0 && q && *q) {
            char *end; unsigned long long v = strtoull(q, &end, 16);
            if (end == q) break;
            if (kind == 0) me = (uintptr_t)v;
            else if (kind == 1 && nc < 64) g_seat_cams[nc++] = (uintptr_t)v;
            else if (kind == 2 && nb < 64) g_seat_btns[nb++] = (uintptr_t)v;
            q = end;
        }
        line = next;
    }
    g_seat_me = me; g_seat_ncam = nc; g_seat_nbtn = nb;
    if (!me) g_seat_cam = 0;
    if (nb > 0) btn_dyn_check();
    logf_("seats: our character 0x%llX, %ld seat cameras, %ld triggers open for us", (unsigned long long)me, nc, nb);
}
// Taken seats (owner 11-07: "i'm able to sit on the same chair as him while he is already sitting on it"): CoopProbe names the seat trigger the other player
// sits on ("taken <trigger> ..."); its button check answers no on this PC (greyed out, as his seats were before kit 169) until he is up again.
static volatile uintptr_t g_seat_taken[4];
static char btn_answer(char r, void *self) {
    for (int i = 0; i < 4; i++) if (g_seat_taken[i] && g_seat_taken[i] == (uintptr_t)self) {
        static uintptr_t lastt;
        if (lastt != (uintptr_t)self) { lastt = (uintptr_t)self; logf_("seats: 0x%llX is taken by the other player: its button is off here", (unsigned long long)(uintptr_t)self); }
        return 0;
    }
    if (!r && g_seats_on && seat_in(g_seat_btns, g_seat_nbtn, (uintptr_t)self)) {
        static uintptr_t last;
        if (last != (uintptr_t)self) { last = (uintptr_t)self; if (seat_log()) logf_("seats: button of 0x%llX turned on for the guest", (unsigned long long)(uintptr_t)self); }
        return 1;
    }
    return r;
}
static char detour_btn_base(void *self, void *inputter) { return btn_answer(g_orig_btn_base(self, inputter), self); }
static char detour_btn_item(void *self, void *inputter) { return btn_answer(g_orig_btn_item(self, inputter), self); }
// 11-07 12:17: his seat prompt finally came, greyed out: the menu asks Trigger:IsActionButtonActive (exec thunk 0x140AD3E40 -> vtable +0x660 of the object), and
// neither hook above ever ran for a seat, so the seats' class answers through another function. The seats list gives the real objects: their vtable slot +0x660
// is read at run time and that function is hooked too (once, if it is neither of the two above).
static btn_fn g_orig_btn_dyn;
static volatile uintptr_t g_btn_dyn_at;
static char detour_btn_dyn(void *self, void *inputter) { return btn_answer(g_orig_btn_dyn(self, inputter), self); }
static void btn_dyn_one(uintptr_t a) {
    if (!a || !readable(a, 8)) return;
    uintptr_t vt = *(uintptr_t *)a;
    if (!vt || !readable(vt + 0x660, 8)) return;
    uintptr_t fn = *(uintptr_t *)(vt + 0x660);
    static uintptr_t seen[8]; static int nseen;
    int known = 0;
    for (int k = 0; k < nseen; k++) if (seen[k] == vt) known = 1;
    if (!known && nseen < 8) { seen[nseen++] = vt; logf_("seats: trigger 0x%llX: vtable 0x%llX, button check 0x%llX", (unsigned long long)a, (unsigned long long)vt, (unsigned long long)fn); }
    if (fn == ADDR_BTN_BASE || fn == ADDR_BTN_ITEM || fn == g_btn_dyn_at || g_btn_dyn_at) return;
    if (!readable(fn, 16) || *(uint8_t *)fn != 0xE9) { logf_("seats: button check 0x%llX not a jump stub, left alone", (unsigned long long)fn); return; }
    MH_STATUS c = MH_CreateHook((void *)fn, (void *)detour_btn_dyn, (void **)&g_orig_btn_dyn);
    MH_STATUS e = c == MH_OK ? MH_EnableHook((void *)fn) : c;
    g_btn_dyn_at = fn;
    logf_("seats: button check 0x%llX hooked for the seats -> %s / %s", (unsigned long long)fn, MH_StatusToString(c), MH_StatusToString(e));
}
static void btn_dyn_check(void) {
    for (LONG i = 0; i < g_seat_nbtn && i < 64; i++) btn_dyn_one(g_seat_btns[i]);
}
// "taken <hex> ..." (up to 4; "taken 0" opens them all again). On the host no seats list names the triggers, so the check is hooked from here too.
static void seats_taken(const char *args) {
    uintptr_t v[4] = {0, 0, 0, 0};
    int n = 0;
    const char *q = args;
    while (n < 4 && q && *q) {
        char *end; unsigned long long x = strtoull(q, &end, 16);
        if (end == q) break;
        if (x) v[n++] = (uintptr_t)x;
        q = end;
    }
    for (int i = 0; i < n; i++) if (g_seats_on) btn_dyn_one(v[i]);
    for (int i = 0; i < 4; i++) g_seat_taken[i] = v[i];
    logf_("seats: %d seat(s) taken by others (0x%llX)", n, (unsigned long long)v[0]);
}
static void detour_exec_possess(void *ctx, void *stack, void *result) {
    uintptr_t s = (uintptr_t)stack;
    // Blueprint calls only (Code set), on a guest only; the rest of this function is the game's thunk with the one choice added
    if (!g_seats_on || rec_client_flag() <= 0 || !s || *(uintptr_t *)(s + 0x20) == 0) { g_orig_exec_possess(ctx, stack, result); return; }
    uintptr_t pawn = 0;
    ((frame_step_fn)ADDR_FRAME_STEP)(stack, *(void **)(s + 0x18), &pawn);
    *(uintptr_t *)(s + 0x20) += 1;
    void **vt = *(void ***)ctx;
    int to_cam = pawn && seat_in(g_seat_cams, g_seat_ncam, pawn);
    if (to_cam || (pawn && g_seat_cam)) {
        uintptr_t target = to_cam ? pawn : (g_seat_me ? g_seat_me : pawn);
        if (seat_log()) logf_("seats: Possess 0x%llX on the guest -> local restart with 0x%llX (%s)", (unsigned long long)pawn, (unsigned long long)target, to_cam ? "sitting down" : "standing up");
        g_seat_cam = to_cam ? pawn : 0;
        ((pawn_fn)vt[VT_CLIENT_RESTART / 8])(ctx, (void *)target);
        return;
    }
    ((pawn_fn)vt[VT_POSSESS / 8])(ctx, (void *)pawn);
}
static void detour_exec_ack(void *ctx, void *stack, void *result) {
    uintptr_t s = (uintptr_t)stack;
    if (g_seats_on && g_seat_ncam > 0 && s && *(uintptr_t *)(s + 0x20) == 0) {
        uintptr_t locals = *(uintptr_t *)(s + 0x28);
        if (locals && readable(locals, 8)) {
            uintptr_t p = *(uintptr_t *)locals;
            // Controller::Pawn +0x388: 11-06 22:30 this also dropped the host's own seat cameras, which are real on the server
            if (!p || (seat_in(g_seat_cams, g_seat_ncam, p) && *(uintptr_t *)((uintptr_t)ctx + 0x388) != p)) {
                if (seat_log()) logf_("seats: the guest's acknowledge of 0x%llX dropped (his seat camera)", (unsigned long long)p);
                return;
            }
        }
    }
    g_orig_exec_ack(ctx, stack, result);
}
// Head on a seat (11-06 22:3x, owner: "it's using his mouse movement"): ABP_ScenarioChara_Sitting* turns the head from GetPlayerCameraManager(0):GetCameraRotation, the
// viewer's camera, for every character that sits. CoopProbe writes CoopNative.head ("<anim instance> <pitch> <yaw>", the other player's camera): the exec thunk answers
// with those numbers when that anim instance is the caller (FFrame+0x18). Everything else gets the real camera.
#define ADDR_EXEC_CAM_ROT 0x1423D0080ULL
static exec_fn g_orig_exec_camrot;
static volatile uintptr_t g_head_anim;
static volatile float g_head_pitch, g_head_yaw;
static void head_read(void) {
    char hb[96];
    if (!read_small_file("CoopNative.head", hb, sizeof hb)) return;
    unsigned long long a = 0; float p = 0, y = 0;
    if (sscanf(hb, "%llx %f %f", &a, &p, &y) != 3) return;
    static LONG logs;
    if ((uintptr_t)a != g_head_anim || logs < 6) { if (InterlockedIncrement(&logs) <= 12) logf_("seats: head for 0x%llX: pitch %.0f yaw %.0f", a, p, y); }
    g_head_pitch = p; g_head_yaw = y; g_head_anim = (uintptr_t)a;
}
static void detour_exec_camrot(void *ctx, void *stack, void *result) {
    uintptr_t s = (uintptr_t)stack, a = g_head_anim;
    if (a && s && result && *(uintptr_t *)(s + 0x18) == a) {
        static LONG hits;
        if (InterlockedIncrement(&hits) == 1) logf_("seats: head: the animation of 0x%llX reads our numbers", (unsigned long long)a);
        uintptr_t code = *(uintptr_t *)(s + 0x20);
        if (code) *(uintptr_t *)(s + 0x20) = code + 1;
        float *r = (float *)result;
        r[0] = g_head_pitch; r[1] = g_head_yaw; r[2] = 0;
        return;
    }
    g_orig_exec_camrot(ctx, stack, result);
}
// Leaving Home Base (11-06 22:34): "vols" takes CoopNative.vols ("x y z", then one volume address per line) and writes the volumes around that point to
// CoopNative.volsout. AVolume::EncompassesPoint, the check the teleport driver makes; on the game thread with the other pending calls.
#define ADDR_ENCOMPASSES 0x1422BB980ULL
typedef char (*encompass_fn)(void *self, float *pt, float radius, float *out);
static volatile LONG g_vols_pending;
static void run_volcheck(void) {
    static char vb[32768];
    if (!read_small_file("CoopNative.vols", vb, sizeof vb)) return;
    float pt[3];
    if (sscanf(vb, "%f %f %f", &pt[0], &pt[1], &pt[2]) != 3) return;
    char op[MAX_PATH];
    snprintf(op, sizeof op, "%sCoopNative.volsout", g_dir);
    FILE *f = fopen(op, "w");
    if (!f) return;
    int n = 0, hit = 0;
    char *line = strchr(vb, '\n');
    while (line && *++line) {
        unsigned long long a = strtoull(line, NULL, 16);
        if (a && readable((uintptr_t)a, 0x410)) {
            n++;
            if (((encompass_fn)ADDR_ENCOMPASSES)((void *)(uintptr_t)a, pt, 0.0f, NULL)) { fprintf(f, "%llX\n", a); hit++; }
        }
        line = strchr(line, '\n');
    }
    fprintf(f, "done\n");
    fclose(f);
    logf_("vols: %d of %d volumes around %.0f %.0f %.0f", hit, n, pt[0], pt[1], pt[2]);
}
// Getting up (11-07: the other screen played it after the player was already walking): the seat's camera calls Mesh:SetAnimInstanceClass the moment the player leaves the seat
// (a no-op there, same class), then sets isSittingEnd for a few frames, then waits 3 s (bed 8 s). The exec thunk sees the caller (FFrame+0x18) is a seat camera: CoopNative.stand.
#define ADDR_EXEC_ANIM_CLASS 0x1423F37C0ULL
static exec_fn g_orig_exec_animclass;
static void detour_exec_animclass(void *ctx, void *stack, void *result) {
    uintptr_t s = (uintptr_t)stack;
    if (g_seat_ncam > 0 && s && seat_in(g_seat_cams, g_seat_ncam, *(uintptr_t *)(s + 0x18))) {
        char sp[MAX_PATH + 32];
        snprintf(sp, sizeof sp, "%sCoopNative.stand", g_dir);
        FILE *sf = fopen(sp, "w");
        if (sf) { fputs("1\n", sf); fclose(sf); }
        if (seat_log()) logf_("seats: the seat's camera 0x%llX sets the animation", (unsigned long long)*(uintptr_t *)(s + 0x18));
    }
    g_orig_exec_animclass(ctx, stack, result);
}
static void detour_get_all(void *ctx, void *cls, rec_ptrs *out) {
    g_orig_get_all(ctx, cls, out);
    uintptr_t me = g_seat_me;
    if (!me || !out || !out->data || out->num < 2 || out->data[0] == me) return;
    for (int i = 1; i < out->num; i++) {
        if (out->data[i] == me) {
            out->data[i] = out->data[0]; out->data[0] = me;
            if (seat_log()) logf_("seats: GetAllActorsOfClass had 0x%llX first, our character 0x%llX put there", (unsigned long long)out->data[i], (unsigned long long)me);
            return;
        }
    }
}

// ---- small file channel next to the DLL: CoopNative.cmd (one-shot commands), .ini (settings), .flags (from Lua) ----
static char g_dir[MAX_PATH];

static int read_small_file(const char *name, char *buf, size_t size) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s%s", g_dir, name);
    // 2026-10-31: the guest's PC had an old CoopNative.tpinfo from a session he hosted, so his CoopNative acted as host. tpinfo is
    // written by the host's CoopProbe (on change, and touched every 30 s, see sendTpInfo): older than 2 minutes = not ours
    if (strcmp(name, "CoopNative.tpinfo") == 0) {
        WIN32_FILE_ATTRIBUTE_DATA fa;
        if (!GetFileAttributesExA(path, GetFileExInfoStandard, &fa)) return 0;
        FILETIME now; GetSystemTimeAsFileTime(&now);
        ULONGLONG t = ((ULONGLONG)fa.ftLastWriteTime.dwHighDateTime << 32) | fa.ftLastWriteTime.dwLowDateTime;
        ULONGLONG n = ((ULONGLONG)now.dwHighDateTime << 32) | now.dwLowDateTime;
        if (n > t && n - t > 120ULL * 10000000ULL) return 0;
    }
    FILE *f = _fsopen(path, "r", _SH_DENYNO);
    if (!f) return 0;
    size_t n = fread(buf, 1, size - 1, f);
    fclose(f);
    buf[n] = 0;
    return 1;
}

static int readable(uintptr_t a, size_t len) {
    MEMORY_BASIC_INFORMATION mbi;
    if (!a || !VirtualQuery((void *)a, &mbi, sizeof mbi) || mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    return a + len <= (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
}

static void log_code_at(const char *what, uintptr_t fn) {
    if (!readable(fn, 8)) { logf_("%s 0x%llX: not readable", what, (unsigned long long)fn); return; }
    const uint8_t *p = (const uint8_t *)fn;
    uintptr_t target = p[0] == 0xE9 ? fn + 5 + *(const int32_t *)(p + 1) : 0;
    logf_("%s 0x%llX: bytes %02X %02X %02X %02X %02X %02X %02X %02X%s%llX", what, (unsigned long long)fn,
          p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], target ? "  (jmp -> 0x" : "", (unsigned long long)target);
}

// "vfunc <object hex> <offset hex>": object's vtable and the entry at offset;  "peek <addr hex> <len>": hex dump (<=64)
// Post-boss outro with a guest (session 9): the host's cutscene waits until the guest leaves, then plays at once. Suspect: the
// cutscene's DeferredTeleportDriver waits for its pause tokens (TokenMap, +0x110: TMap<TWeakObjectPtr<UObject> issuer,
// UDeferredTeleportPausedToken*>), and the guest's objects on the host hold one his game never withdraws; his leaving makes the
// weak key stale. CoopProbe writes CoopNative.tpinfo ("driver <hex>" and "guest <hex>" lines: the driver objects and the guest's
// pawn/controller). "tpdump" logs the driver and its tokens (issuer = ObjectIndex/serial, marked when it is a guest object);
// "tpfree" makes the guest's keys stale (ObjectIndex -1), as his leaving does. Both run on the worker and only read/write raw memory.
#define TP_MAX 8
static int g_host_idx[TP_MAX], g_nhost;
static int tp_read_info(uintptr_t *drivers, int *nd, int *guest_idx, int *ng) {
    char buf[600];
    *nd = *ng = 0; g_nhost = 0;
    // 2026-10-31: before joining, the guest hosts his own world and his CoopProbe writes a tpinfo; it is deleted after the join,
    // but g_host_pc stayed set, so his CoopNative kept acting as host (no guest v5). No (fresh) tpinfo = not the host now.
    if (!read_small_file("CoopNative.tpinfo", buf, sizeof buf)) { g_host_pc = 0; g_host_pawn = 0; return 0; }
    for (char *p = strtok(buf, "\r\n"); p; p = strtok(NULL, "\r\n")) {
        unsigned long long a;
        if (sscanf(p, "driver %llx", &a) == 1 && *nd < TP_MAX) drivers[(*nd)++] = (uintptr_t)a;
        else if (sscanf(p, "guest %llx", &a) == 1 && *ng < TP_MAX && readable((uintptr_t)a + 0xC, 4))
            guest_idx[(*ng)++] = *(int *)((uintptr_t)a + 0xC);   // UObject::InternalIndex
        else if (sscanf(p, "host %llx", &a) == 1 && g_nhost < TP_MAX && readable((uintptr_t)a + 0xC, 4)) {
            if (g_nhost == 0) g_host_pc = (uintptr_t)a; else if (g_nhost == 1) g_host_pawn = (uintptr_t)a;
            g_host_idx[g_nhost++] = *(int *)((uintptr_t)a + 0xC);
        }
    }
    return 1;
}
static const char *tp_state_name(int st) {
    static const char *n[] = {"ErrorFailedToGetManager", "ErrorNotGameWorld", "ErrorListenerUnsupported", "ErrorOtherDriverIsRunning",
        "ErrorFailedToGenerateDriver", "ErrorMax", "WaitingForCovering", "WaitingForEndStreamingLevel", "WaitingForEndStreamingOther",
        "WaitingForPermissionResume", "Done"};
    return st >= 0 && st <= 10 ? n[st] : "?";
}
// once per second from the worker: log every change of a driver's running flag, state or lock counter (no command needed)
static void tp_watch(void) {
    static uintptr_t last_drv[TP_MAX]; static int last_key[TP_MAX];
    uintptr_t drivers[TP_MAX]; int guest_idx[TP_MAX], nd, ng;
    if (!tp_read_info(drivers, &nd, guest_idx, &ng)) return;
    for (int d = 0; d < nd; d++) {
        uintptr_t drv = drivers[d];
        if (!readable(drv + 0x100, 0x48)) continue;
        int key = (*(uint8_t *)(drv + 0x100)) | (*(uint8_t *)(drv + 0x103) << 8) | ((*(int *)(drv + 0x104) & 0xFF) << 16) |
                  ((*(int *)(drv + 0x118) & 0x7F) << 24);
        if (last_drv[d] == drv && last_key[d] == key) continue;
        last_drv[d] = drv; last_key[d] = key;
        // session 10: who the driver moves (DriverListener, weak object at +0x108: index, serial)
        int lidx = *(int *)(drv + 0x108);
        const char *who = "";
        for (int k = 0; k < ng; k++) if (guest_idx[k] == lidx) who = " = GUEST";
        for (int k = 0; k < g_nhost; k++) if (g_host_idx[k] == lidx) who = " = HOST";
        logf_("tp watch: driver 0x%llX running %d state %d %s locks %d token slots %d listener index %d%s", (unsigned long long)drv,
              key & 0xFF, (key >> 8) & 0xFF, tp_state_name((key >> 8) & 0xFF), (key >> 16) & 0xFF, (key >> 24) & 0x7F, lidx, who);
    }
}
static void tp_tokens(int free_guest) {
    uintptr_t drivers[TP_MAX]; int guest_idx[TP_MAX], nd, ng;
    if (!tp_read_info(drivers, &nd, guest_idx, &ng)) { logf_("tp: no CoopNative.tpinfo yet"); return; }
    char g[120] = ""; for (int i = 0; i < ng; i++) { char one[16]; snprintf(one, sizeof one, " %d", guest_idx[i]); strcat_s(g, sizeof g, one); }
    logf_("tp: %d driver(s), guest object indices:%s", nd, g);
    for (int d = 0; d < nd; d++) {
        uintptr_t drv = drivers[d];
        if (!readable(drv + 0x100, 0x48)) { logf_("tp: driver 0x%llX unreadable", (unsigned long long)drv); continue; }
        uint8_t running = *(uint8_t *)(drv + 0x100), state = *(uint8_t *)(drv + 0x103);
        int locks = *(int *)(drv + 0x104);
        uintptr_t data = *(uintptr_t *)(drv + 0x110);
        int num = *(int *)(drv + 0x118);
        uint32_t *flags_inline = (uint32_t *)(drv + 0x120);
        uintptr_t flags_heap = *(uintptr_t *)(drv + 0x130);
        int nbits = *(int *)(drv + 0x138);
        logf_("tp: driver 0x%llX running %u state %u %s locks %d tokens slots %d (bits %d)", (unsigned long long)drv, running, state,
              tp_state_name(state), locks, num, nbits);
        if (free_guest == 2) { *(int *)(drv + 0x104) = 0; logf_("tp: driver 0x%llX lock counter %d -> 0", (unsigned long long)drv, locks); continue; }
        for (int i = 0; i < num && i < 64; i++) {
            uint32_t word;
            if (flags_heap && readable(flags_heap + (i / 32) * 4, 4)) word = *(uint32_t *)(flags_heap + (i / 32) * 4);
            else if (i < 128) word = flags_inline[i / 32]; else break;
            if (!(word & (1u << (i % 32)))) continue;
            uintptr_t e = data + (uintptr_t)i * 0x18;
            if (!readable(e, 0x18)) break;
            int idx = *(int *)e, serial = *(int *)(e + 4);
            uintptr_t token = *(uintptr_t *)(e + 8);
            int count = token && readable(token + 0x28, 4) ? *(int *)(token + 0x28) : -1;
            int is_guest = 0;
            for (int k = 0; k < ng; k++) if (guest_idx[k] == idx) is_guest = 1;
            logf_("tp:   token %d: issuer index %d serial %d, token 0x%llX count %d%s", i, idx, serial, (unsigned long long)token, count,
                  is_guest ? "  <- GUEST" : "");
            if (free_guest && is_guest) {
                *(int *)e = -1;
                logf_("tp:   token %d: guest key made stale", i);
            }
        }
    }
}

// Command queue (2026-10-30, after the Lies of P study): CoopNative.cmd used to hold ONE command, and two writers overwrote each
// other (menuclass / restclass). Now Lua appends one command per line; the file is renamed before reading (a writer appending
// at that moment starts a new file) and every line is run in order.
static void run_command(char *buf);
static void run_commands(void) {
    char path[MAX_PATH], work[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.cmd", g_dir);
    snprintf(work, sizeof work, "%sCoopNative.cmd.work", g_dir);
    if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) return;
    if (!MoveFileExA(path, work, MOVEFILE_REPLACE_EXISTING)) return;
    char all[4096] = "";
    FILE *f = _fsopen(work, "rb", _SH_DENYNO);
    if (f) { size_t n = fread(all, 1, sizeof all - 1, f); all[n] = 0; fclose(f); }
    DeleteFileA(work);
    char *ctx = NULL;
    for (char *line = strtok_s(all, "\r\n", &ctx); line; line = strtok_s(NULL, "\r\n", &ctx))
        if (*line) run_command(line);
}
static void run_command(char *buf) {
    unsigned long long a = 0, b = 0;
    if (sscanf(buf, "vfunc %llx %llx", &a, &b) == 2) {
        if (!readable((uintptr_t)a, 8)) { logf_("vfunc: object 0x%llX not readable", a); return; }
        uintptr_t vt = *(uintptr_t *)(uintptr_t)a;
        if (!readable(vt + (uintptr_t)b, 8)) { logf_("vfunc: vtable 0x%llX + 0x%llX not readable", (unsigned long long)vt, b); return; }
        uintptr_t fn = *(uintptr_t *)(vt + (uintptr_t)b);
        logf_("vfunc: object 0x%llX vtable 0x%llX [+0x%llX] = 0x%llX", a, (unsigned long long)vt, b, (unsigned long long)fn);
        log_code_at("vfunc target", fn);
    } else if (sscanf(buf, "peek %llx %llu", &a, &b) == 2) {
        if (b > 64) b = 64;
        if (!readable((uintptr_t)a, (size_t)b)) { logf_("peek: 0x%llX not readable", a); return; }
        char hex[64 * 3 + 1] = "";
        for (unsigned i = 0; i < b; i++) snprintf(hex + i * 3, 4, "%02X ", ((uint8_t *)(uintptr_t)a)[i]);
        logf_("peek 0x%llX: %s", a, hex);
    } else if (strncmp(buf, "lvlinfo ", 8) == 0) {
        unsigned long long c[4] = {0, 0, 0, 0};
        int n = sscanf(buf + 8, "%llx %llx %llx %llx", &c[0], &c[1], &c[2], &c[3]);
        for (int k = 0; k < 4 && k < n; k++) g_lvlinfo_comp[k] = (uintptr_t)c[k];
        InterlockedExchange(&g_lvlinfo_pending, 1);
        logf_("lvlinfo requested for %d component(s)", n);
    } else if (sscanf(buf, "syncall %llx", &a) == 1) {
        g_syncall_pawn = (uintptr_t)a; InterlockedExchange(&g_syncall_pending, 1);
        logf_("syncall requested for 0x%llX", a);
    } else if (strncmp(buf, "levelup ", 8) == 0) {
        unsigned long long ctx = 0, pawn = 0; int n = 0;
        if (sscanf(buf + 8, "%llx %d %llx", &ctx, &n, &pawn) >= 2) {
            g_levelup_ctx = (uintptr_t)ctx; g_levelup_n = n; g_levelup_pawn = (uintptr_t)pawn;
            InterlockedExchange(&g_levelup_pending, 1);
            logf_("levelup requested: ctx 0x%llX, +%d, pawn 0x%llX", ctx, n, pawn);
        }
    } else if (sscanf(buf, "uiunfade %llu", &a) == 1) {
        // session 10: release any fade usage (e.g. 104 LargePoly, 64 LongLoading, 48 TeleportPC) with the memory actor as context
        g_memunfade_usage = (LONG)a; InterlockedExchange(&g_memunfade_pending, 1);
        logf_("uiunfade %llu requested (memory actor 0x%llX)", a, (unsigned long long)g_memory_actor);
    } else if (strncmp(buf, "memunfade", 9) == 0) {
        g_memunfade_usage = 106;
        // session 10: the memory's fade (usage 106 MemoryResidue, Caller = the scenario actor) stays on the host
        InterlockedExchange(&g_memunfade_pending, 1);
        logf_("memunfade requested (memory actor 0x%llX)", (unsigned long long)g_memory_actor);
    } else if (sscanf(buf, "unfade %llx", &a) == 1) {
        g_unfade_obj = (uintptr_t)a; g_unfade_caller = 0; g_unfade_usage = 102; InterlockedExchange(&g_unfade_pending, 1);
        logf_("unfade requested for component 0x%llX", a);
    } else if (strncmp(buf, "tpdump", 6) == 0) {
        tp_tokens(0);
    } else if (strncmp(buf, "tpfree", 6) == 0) {
        tp_tokens(1);
    } else if (strncmp(buf, "tpunlock", 8) == 0) {
        tp_tokens(2);
    } else if (strncmp(buf, "tpfade ", 7) == 0) {
        unsigned long long ctx = 0; int on = 0;
        if (sscanf(buf + 7, "%llx %d", &ctx, &on) == 2) { g_tpfade_ctx = (uintptr_t)ctx; InterlockedExchange(&g_tpfade_pending, on ? 1 : 0); }
    } else if (strncmp(buf, "recwin ", 7) == 0) {
        rec_window(atoi(buf + 7), "event");
    } else if (strncmp(buf, "reccensus", 9) == 0) {
        if (g_rec) rec_census();
    } else if (strncmp(buf, "seats", 5) == 0) {
        seats_read();
    } else if (strncmp(buf, "piano", 5) == 0) {
        pn_read();
    } else if (strncmp(buf, "taken ", 6) == 0) {
        seats_taken(buf + 6);
    } else if (strncmp(buf, "fadehold ", 9) == 0) {
        int on = 0; unsigned long long c = 0;
        if (sscanf(buf + 9, "%d %llx", &on, &c) == 2) {
            if (on) { g_fade_held_n = 0; g_fade_hold_at = GetTickCount64(); InterlockedExchange(&g_fade_hold, 1); logf_("fade hold: on"); }
            else { g_fade_release_ctx = (uintptr_t)c; InterlockedExchange(&g_fade_release_pending, 1); }
        }
    } else if (strncmp(buf, "seatcam ", 8) == 0) {
        unsigned long long p1 = 0, p2 = 0;
        if (sscanf(buf + 8, "%llx %llx", &p1, &p2) == 2) { g_seatcam_pc = (uintptr_t)p1; g_seatcam_pawn = (uintptr_t)p2; InterlockedExchange(&g_seatcam_pending, 1); }
    } else if (strncmp(buf, "vols", 4) == 0) {
        InterlockedExchange(&g_vols_pending, 1);
    } else if (strncmp(buf, "hbstart", 7) == 0) {
        g_hb_at = GetTickCount64();   // the guest has no teleport of his own, and his lock stuck the same way
        rec_window(85, "Home Base trip");
        logf_("hb: Home Base trip started by the host");
    } else if (sscanf(buf, "talkfn %llx", &a) == 1) {
        if (a && readable((uintptr_t)a + 0x18, 4)) { g_talk_name = *(int *)((uintptr_t)a + 0x18); logf_("talk: ProcessInputButtonEvent 0x%llX, name index %ld", a, g_talk_name); }
    } else if (sscanf(buf, "scenmgr %llx", &a) == 1) {
        if (g_scen_mgr != (uintptr_t)a) logf_("scene flags: scenario manager 0x%llX", a);
        g_scen_mgr = (uintptr_t)a;
    } else if (sscanf(buf, "restclass %llx", &a) == 1) {
        g_restore_class = (uintptr_t)a;
        logf_("vestige_keep: BP_BCRestorationUIComponent_C class = 0x%llX", a);
    } else if (sscanf(buf, "menuclass %llx", &a) == 1) {
        g_menu_class = (uintptr_t)a;
        logf_("vestige_menu: WDT_CheckpointMenu_C class = 0x%llX", a);
    } else if (strncmp(buf, "replay", 6) == 0) {
        if (g_vetoed_kind) { InterlockedExchange(&g_replay_pending, 1); logf_("replay requested (sm 0x%p)", g_vetoed_sm); }
        else logf_("replay requested, but nothing was vetoed");
    } else {
        logf_("unknown command: %s", buf);
    }
}

static void read_settings(void) {
    char buf[2048];   // the ini outgrew 256 bytes on 2026-10-30
    int have_ini = read_small_file("CoopNative.ini", buf, sizeof buf);
    LONG veto = have_ini && strstr(buf, "veto_endcoop=1") != NULL;
    if (InterlockedExchange(&g_veto_enabled, veto) != veto) logf_("setting veto_endcoop = %ld", veto);
    LONG vest = have_ini && strstr(buf, "vestige_menu=1") != NULL;
    if (InterlockedExchange(&g_vestige_enabled, vest) != vest) logf_("setting vestige_menu = %ld", vest);
    LONG relay = have_ini && strstr(buf, "levelup_relay=1") != NULL;
    if (InterlockedExchange(&g_levelup_relay, relay) != relay) logf_("setting levelup_relay = %ld", relay);
    LONG gtp = have_ini && strstr(buf, "group_teleport=1") != NULL;
    {
        int n = 0;
        const char *p = have_ini ? strstr(buf, "teleport_skip_fields=") : NULL;
        if (p) {
            p += strlen("teleport_skip_fields=");
            while (n < 16) {
                char *end;
                long v = strtol(p, &end, 10);
                if (end == p) break;
                g_skip_fields[n++] = (int)v;
                p = end;
                if (*p != ',') break;
                p++;
            }
        }
        if (n != g_skip_n) logf_("setting teleport_skip_fields: %d destination(s)", n);
        g_skip_n = n;
    }
    if (InterlockedExchange(&g_group_teleport, gtp) != gtp) logf_("setting group_teleport = %ld", gtp);
    LONG vkeep = have_ini && strstr(buf, "vestige_keep=1") != NULL;
    if (InterlockedExchange(&g_vestige_keep, vkeep) != vkeep) logf_("setting vestige_keep = %ld", vkeep);
    LONG gmb = have_ini && strstr(buf, "guest_memory_block=1") != NULL;
    if (InterlockedExchange(&g_guest_mem_block, gmb) != gmb) logf_("setting guest_memory_block = %ld", gmb);
    LONG mst = !(have_ini && strstr(buf, "memory_start_teleport=0") != NULL);
    if (InterlockedExchange(&g_memstart_tp, mst) != mst) logf_("setting memory_start_teleport = %ld", mst);
    LONG pov = !(have_ini && strstr(buf, "outro_partner_override=0") != NULL);
    if (InterlockedExchange(&g_partner_override, pov) != pov) logf_("setting outro_partner_override = %ld", pov);
    LONG swt = !(have_ini && strstr(buf, "scene_start_wait=0") != NULL);
    if (InterlockedExchange(&g_scene_wait, swt) != swt) logf_("setting scene_start_wait = %ld", swt);
    LONG gout = have_ini && strstr(buf, "guest_outro=1") != NULL;
    if (InterlockedExchange(&g_guest_outro, gout) != gout) logf_("setting guest_outro = %ld", gout);
    g_layout_random = have_ini && strstr(buf, "layout_fixed=0") != NULL;
    LONG kout = have_ini && strstr(buf, "keep_outro=1") != NULL;
    if (InterlockedExchange(&g_keep_outro, kout) != kout) logf_("setting keep_outro = %ld", kout);
    LONG grest = have_ini && strstr(buf, "guest_rest=1") != NULL;
    if (InterlockedExchange(&g_guest_rest, grest) != grest) logf_("setting guest_rest = %ld", grest);
    LONG rest = have_ini && strstr(buf, "rest_in_coop=1") != NULL;
    if (InterlockedExchange(&g_rest_in_coop, rest) != rest) logf_("setting rest_in_coop = %ld", rest);
    LONG win = read_small_file("CoopNative.flags", buf, sizeof buf) && buf[0] == '1';
    if (InterlockedExchange(&g_spectate_window, win) != win) logf_("spectate window (from Lua) = %ld", win);
}

// Returns 1 hooked, 0 not executable yet (retry later), -1 refused for good. Every address is hard-coded for Code Vein
// 1.53.93354 (exe SHA-256 8fa550fe...); the first 16 bytes must match what was measured there, or the hook is skipped, so a
// different build (e.g. on another player's PC) cannot get a patch at the wrong place.
// Startup batching (session 10): MH_EnableHook pauses all game threads each time (~0.1 s per hook, ~7 s for the startup set);
// during the startup set the hooks are only created, then enabled together with MH_EnableHook(MH_ALL_HOOKS).
static int g_hook_batch;
static int g_diag_hooks;

// ---- Piano (2026-11-07) ----
// BP_SittingPianoChair_Camera: 13 keys, D4..B5 (actions Trigger_L2, Trigger_L1, Direction_Left, Direction_Up, Direction_Right, FaceButton_Left, FaceButton_Top,
// Decide, Trigger_R1, Trigger_R2, Direction_Down, Trigger_L3, Trigger_R3). A press sets Is<key>Down; the camera's tick runs PlayingPianoFunc, which for the key
// (or two keys) pressed sets PoseChise (1..91, the hand pose: a BlendListByInt in ABP_ScenarioChara_SittingPianoChair) on the pianist's animation and posts
// SE_PIANO_KEY_<note>_Play on the camera's AkComponent ("Ak"). All of it on one PC only.
// Relay: UAkComponent::PostAkEvent (impl stub 0x14298F1E0; the exec thunk 0x14299BA40 calls it with this, event, FString*) is hooked. While we sit at the
// piano ("rec 1") the notes of one engine frame are one press: CoopNative.pianoout ("id ms mask"), sent by CoopProbe. Incoming presses (CoopNative.pianoin,
// "p <ms/4 mod 2048> <mask>"; from the guest straight from Server_AddExp kind 12) are played with their spacing kept, 150 ms behind, on our own piano camera's
// AkComponent, and PoseChise is set on our copy of the pianist. The guest's camera never gets his input (no possession), so for him ("keys 1") the keys of the
// 13 actions are read here (keyboard, mouse, XInput pads; only while the game window has focus), played on our side the same way and sent.
#define ADDR_AK_POST_IMPL 0x14298F1E0ULL
#define PN_BUFFER_MS 350   // presses leave every 200 ms (CoopProbe probe loop) plus the network
typedef int32_t (*akpost_fn)(void *comp, void *event, void *name);
static akpost_fn g_orig_akpost;
static const uint8_t g_pn_pose[13][13] = {
    {1,14,15,16,17,18,19,20,21,22,23,24,25},
    {14,2,26,27,28,29,30,31,32,33,34,35,36},
    {15,26,3,37,38,39,40,41,42,43,44,45,46},
    {16,27,37,4,47,48,49,50,51,52,53,54,55},
    {17,28,38,47,5,56,57,58,59,60,61,62,63},
    {18,29,39,48,56,6,64,65,66,67,68,69,70},
    {19,30,40,49,57,64,7,71,72,73,74,75,76},
    {20,31,41,50,58,65,71,8,77,78,79,80,81},
    {21,32,42,51,59,66,72,77,9,82,83,84,85},
    {22,33,43,52,60,67,73,78,82,10,86,87,88},
    {23,34,44,53,61,68,74,79,83,86,11,89,90},
    {24,35,45,54,62,69,75,80,84,87,89,12,91},
    {25,36,46,55,63,70,76,81,85,88,90,91,13}
};
static const char *g_pn_note[13] = {"D4", "E4", "F4", "G4", "A4", "B4", "C5", "D5", "E5", "F5", "G5", "A5", "B5"};
static volatile uintptr_t g_pn_ak, g_pn_ak_vt, g_pn_ev[13], g_pn_cls, g_pn_ranim, g_pn_ranim_vt, g_pn_manim, g_pn_manim_vt;
static volatile LONG g_pn_off, g_pn_rec, g_pn_keys, g_pn_have, g_pn_cs_ok, g_pn_logs;
static CRITICAL_SECTION g_pn_cs;
// keys per action: type << 16 | value. 1 = virtual key, 2 = XInput button bits, 3 = left trigger, 4 = right trigger
static volatile uint32_t g_pn_key[13][6];
static volatile LONG g_pn_nkey[13];
typedef struct { LONG id; uint32_t ms; uint16_t mask; LONG64 tick; } pn_rec_t;
static pn_rec_t g_pn_out[64];
static LONG g_pn_out_n;
static volatile LONG g_pn_out_dirty;
typedef struct { ULONGLONG due; uint16_t mask; uint8_t local; ULONGLONG arrived; } pn_due_t;
static pn_due_t g_pn_q[64];
static volatile LONG g_pn_qn;
static ULONGLONG g_pn_in_last;
static LONG64 g_pn_in_T, g_pn_in_off;
static int g_pn_in_have;
static uint8_t g_pn_empty[16];
static int pn_log(void) { LONG n = InterlockedIncrement(&g_pn_logs); return n <= 80 || n % 50 == 0; }
// 11-07 20:52: our own notes (80 lines) used up the counter and the other player's never showed: each kind counts on its own
static volatile LONG g_pn_logs_play;
static int pn_log_play(void) { LONG n = InterlockedIncrement(&g_pn_logs_play); return n <= 80 || n % 50 == 0; }
static void pn_notes(uint16_t mask, char *out, size_t n) {
    size_t k = 0; out[0] = 0;
    for (int i = 0; i < 13 && k + 4 < n; i++) if (mask & (1 << i)) k += snprintf(out + k, n - k, "%s%s", k ? "+" : "", g_pn_note[i]);
}
static int pn_pose_of(uint16_t mask) {
    int a = -1, b = -1;
    for (int i = 0; i < 13; i++) if (mask & (1 << i)) { if (a < 0) a = i; else if (b < 0) b = i; }
    if (a < 0) return 0;
    return g_pn_pose[a][b < 0 ? a : b];
}
// a press of ours, to send. From the hook: the notes of one engine frame are one press (it is complete once the frame is over).
static void pn_record(uint16_t mask, int from_hook) {
    if (!g_pn_cs_ok) return;
    EnterCriticalSection(&g_pn_cs);
    LONG64 t = g_engine_ticks;
    pn_rec_t *last = g_pn_out_n > 0 ? &g_pn_out[(g_pn_out_n - 1) & 63] : NULL;
    if (from_hook && last && last->tick == t) last->mask |= mask;
    else {
        pn_rec_t *r = &g_pn_out[g_pn_out_n & 63];
        r->id = g_pn_out_n + 1; r->ms = (uint32_t)GetTickCount64(); r->mask = mask; r->tick = from_hook ? t : -1;
        g_pn_out_n++;
    }
    InterlockedExchange(&g_pn_out_dirty, 1);
    LeaveCriticalSection(&g_pn_cs);
}
static int32_t detour_akpost(void *comp, void *event, void *name) {
    if (g_pn_rec && !g_pn_keys && g_pn_have && event) {
        for (int i = 0; i < 13; i++) if (g_pn_ev[i] == (uintptr_t)event) {
            pn_record((uint16_t)(1 << i), 1);
            if (pn_log()) logf_("piano: our camera plays %s (component 0x%llX)", g_pn_note[i], (unsigned long long)(uintptr_t)comp);
            break;
        }
    }
    return g_orig_akpost(comp, event, name);
}
static void pn_schedule(ULONGLONG due, uint16_t mask, int local, ULONGLONG arrived) {
    if (!g_pn_cs_ok) return;
    EnterCriticalSection(&g_pn_cs);
    if (g_pn_qn < 64) { pn_due_t *q = &g_pn_q[g_pn_qn]; q->due = due; q->mask = mask; q->local = (uint8_t)local; q->arrived = arrived; g_pn_qn++; }
    LeaveCriticalSection(&g_pn_cs);
}
// game thread
static void pn_play(const pn_due_t *q) {
    uintptr_t ak = g_pn_ak;
    int ok = g_pn_have && ak && readable(ak, 8) && *(uintptr_t *)ak == g_pn_ak_vt, n = 0;
    akpost_fn post = g_orig_akpost ? g_orig_akpost : (akpost_fn)ADDR_AK_POST_IMPL;
    if (ok) for (int i = 0; i < 13; i++) if (q->mask & (1 << i)) {
        uintptr_t ev = g_pn_ev[i];
        if (ev && readable(ev, 0x28)) { post((void *)ak, (void *)ev, g_pn_empty); n++; }
    }
    uintptr_t a = q->local ? g_pn_manim : g_pn_ranim, vt = q->local ? g_pn_manim_vt : g_pn_ranim_vt;
    LONG off = g_pn_off;
    int pose = pn_pose_of(q->mask), posed = 0;
    if (a && off > 0x28 && off < 0x40000 && readable(a, (size_t)off + 4) && *(uintptr_t *)a == vt && *(uintptr_t *)(a + 0x10) == g_pn_cls) {
        *(int32_t *)(a + off) = pose; posed = 1;
    }
    if (pn_log_play()) {
        char nb[64]; pn_notes(q->mask, nb, sizeof nb);
        logf_("piano: %s %s (%d note%s), pose %d %s", q->local ? "our key" : "the other player:", nb, n, n == 1 ? "" : "s", pose,
              posed ? "set" : (a ? "NOT set (animation gone or no offset)" : "(no animation)"));
        if (!q->local && q->arrived) logf_("piano: ... %llu ms after it came in", (unsigned long long)(GetTickCount64() - q->arrived));
    }
    if (!ok) { static LONG warned; if (InterlockedIncrement(&warned) <= 5) logf_("piano: no piano component to play on (have %ld, 0x%llX)", g_pn_have, (unsigned long long)ak); }
    // 11-09: "his hands do not move" with the pose set: the camera also flips IsPianoPlay / IsPianoPlay2 (they are bit fields in the animation, so Lua sets them):
    // CoopNative.pianofx "r <mask>" = the other player's press, "l <mask>" = ours (guest)
    {
        char fp[MAX_PATH + 32];
        snprintf(fp, sizeof fp, "%sCoopNative.pianofx", g_dir);
        FILE *ff = fopen(fp, "a");
        if (ff) { fprintf(ff, "%c %u\n", q->local ? 'l' : 'r', (unsigned)q->mask); fclose(ff); }
    }
}
static void pn_game_thread(void) {
    if (!g_pn_cs_ok || !g_pn_qn) return;
    ULONGLONG now = GetTickCount64();
    pn_due_t run[16]; int nr = 0;
    EnterCriticalSection(&g_pn_cs);
    int k = 0;
    for (int i = 0; i < g_pn_qn; i++) {
        if (g_pn_q[i].due <= now && nr < 16) run[nr++] = g_pn_q[i];
        else g_pn_q[k++] = g_pn_q[i];
    }
    g_pn_qn = k;
    LeaveCriticalSection(&g_pn_cs);
    for (int i = 0; i < nr; i++) pn_play(&run[i]);
}
// incoming press (piano thread): keep the sender's spacing, PN_BUFFER_MS behind; a pause of 4 s starts over
static void pn_incoming(int t4, uint16_t mask) {
    ULONGLONG now = GetTickCount64();
    LONG64 T;
    if (!g_pn_in_have || now - g_pn_in_last > 4000) {
        T = t4; g_pn_in_off = (LONG64)now + PN_BUFFER_MS - T * 4; g_pn_in_have = 1;
    } else {
        int d = (t4 - (int)(g_pn_in_T & 2047) + 2048) & 2047;
        if (d > 1800) d = 0;
        T = g_pn_in_T + d;
    }
    g_pn_in_T = T; g_pn_in_last = now;
    LONG64 due = T * 4 + g_pn_in_off;
    if (due < (LONG64)now) { g_pn_in_off += (LONG64)now - due; due = (LONG64)now; }
    pn_schedule((ULONGLONG)due, mask, 0, now);
}
// host: from the guest's Server_AddExp (game thread)
static void pn_in_append(int data) {
    char p[MAX_PATH + 32];
    snprintf(p, sizeof p, "%sCoopNative.pianoin", g_dir);
    FILE *f = fopen(p, "a");
    if (f) { fprintf(f, "p %d %d\n", (data / 8192) & 2047, data & 8191); fclose(f); }
}
static void pn_take_in(void) {
    char p[MAX_PATH + 32], q[MAX_PATH + 40];
    snprintf(p, sizeof p, "%sCoopNative.pianoin", g_dir);
    if (GetFileAttributesA(p) == INVALID_FILE_ATTRIBUTES) return;
    snprintf(q, sizeof q, "%sCoopNative.pianoin.take", g_dir);
    DeleteFileA(q);
    if (!MoveFileA(p, q)) return;   // still open by its writer: next time
    FILE *f = fopen(q, "r");
    if (!f) return;
    char line[64]; int t4, m, n = 0;
    while (fgets(line, sizeof line, f)) if (sscanf(line, "p %d %d", &t4, &m) == 2) { pn_incoming(t4 & 2047, (uint16_t)(m & 0x1FFF)); n++; }
    fclose(f); DeleteFileA(q);
    static LONG logs;
    if (n && InterlockedIncrement(&logs) <= 10) logf_("piano: %d press(es) came in", n);
}
static void pn_write_out(void) {
    if (!g_pn_out_dirty || !g_pn_cs_ok) return;
    char buf[32 * 40]; size_t len = 0; int pending = 0;
    EnterCriticalSection(&g_pn_cs);
    LONG64 t = g_engine_ticks;
    LONG n = g_pn_out_n;
    for (LONG id = n > 32 ? n - 31 : 1; id <= n; id++) {
        pn_rec_t *r = &g_pn_out[(id - 1) & 63];
        if (r->tick >= 0 && r->tick == t) { pending = 1; break; }
        len += (size_t)snprintf(buf + len, sizeof buf - len, "%ld %lu %u\n", r->id, (unsigned long)r->ms, (unsigned)r->mask);
    }
    if (!pending) InterlockedExchange(&g_pn_out_dirty, 0);
    LeaveCriticalSection(&g_pn_cs);
    char p[MAX_PATH + 32], tmp[MAX_PATH + 40];
    snprintf(p, sizeof p, "%sCoopNative.pianoout", g_dir);
    snprintf(tmp, sizeof tmp, "%sCoopNative.pianoout.tmp", g_dir);
    FILE *f = fopen(tmp, "w");
    if (!f) { InterlockedExchange(&g_pn_out_dirty, 1); return; }
    fwrite(buf, 1, len, f); fclose(f);
    if (!MoveFileExA(tmp, p, MOVEFILE_REPLACE_EXISTING)) InterlockedExchange(&g_pn_out_dirty, 1);   // being read: next time
}
typedef struct { DWORD packet; WORD buttons; BYTE lt, rt; SHORT lx, ly, rx, ry; } pn_xstate;
typedef DWORD (WINAPI *pn_xget_fn)(DWORD, pn_xstate *);
static pn_xget_fn g_pn_xget;
static int g_pn_kactive;   // piano thread only: the key poll runs (its first round only takes what is already held)
static uint32_t pn_keycode(const char *k) {
    static const struct { const char *n; uint32_t c; } T[] = {
        {"Up", 0x10000 | VK_UP}, {"Down", 0x10000 | VK_DOWN}, {"Left", 0x10000 | VK_LEFT}, {"Right", 0x10000 | VK_RIGHT},
        {"Enter", 0x10000 | VK_RETURN}, {"SpaceBar", 0x10000 | VK_SPACE}, {"BackSpace", 0x10000 | VK_BACK}, {"Tab", 0x10000 | VK_TAB},
        {"Escape", 0x10000 | VK_ESCAPE}, {"LeftShift", 0x10000 | VK_LSHIFT}, {"RightShift", 0x10000 | VK_RSHIFT},
        {"LeftControl", 0x10000 | VK_LCONTROL}, {"RightControl", 0x10000 | VK_RCONTROL}, {"LeftAlt", 0x10000 | VK_LMENU}, {"RightAlt", 0x10000 | VK_RMENU},
        {"CapsLock", 0x10000 | VK_CAPITAL}, {"Insert", 0x10000 | VK_INSERT}, {"Delete", 0x10000 | VK_DELETE}, {"Home", 0x10000 | VK_HOME},
        {"End", 0x10000 | VK_END}, {"PageUp", 0x10000 | VK_PRIOR}, {"PageDown", 0x10000 | VK_NEXT},
        {"Zero", 0x10000 | '0'}, {"One", 0x10000 | '1'}, {"Two", 0x10000 | '2'}, {"Three", 0x10000 | '3'}, {"Four", 0x10000 | '4'},
        {"Five", 0x10000 | '5'}, {"Six", 0x10000 | '6'}, {"Seven", 0x10000 | '7'}, {"Eight", 0x10000 | '8'}, {"Nine", 0x10000 | '9'},
        {"NumPadZero", 0x10000 | VK_NUMPAD0}, {"NumPadOne", 0x10000 | VK_NUMPAD1}, {"NumPadTwo", 0x10000 | VK_NUMPAD2}, {"NumPadThree", 0x10000 | VK_NUMPAD3},
        {"NumPadFour", 0x10000 | VK_NUMPAD4}, {"NumPadFive", 0x10000 | VK_NUMPAD5}, {"NumPadSix", 0x10000 | VK_NUMPAD6}, {"NumPadSeven", 0x10000 | VK_NUMPAD7},
        {"NumPadEight", 0x10000 | VK_NUMPAD8}, {"NumPadNine", 0x10000 | VK_NUMPAD9}, {"Multiply", 0x10000 | VK_MULTIPLY}, {"Add", 0x10000 | VK_ADD},
        {"Subtract", 0x10000 | VK_SUBTRACT}, {"Decimal", 0x10000 | VK_DECIMAL}, {"Divide", 0x10000 | VK_DIVIDE},
        {"Semicolon", 0x10000 | VK_OEM_1}, {"Equals", 0x10000 | VK_OEM_PLUS}, {"Comma", 0x10000 | VK_OEM_COMMA}, {"Hyphen", 0x10000 | VK_OEM_MINUS},
        {"Underscore", 0x10000 | VK_OEM_MINUS}, {"Period", 0x10000 | VK_OEM_PERIOD}, {"Slash", 0x10000 | VK_OEM_2}, {"Tilde", 0x10000 | VK_OEM_3},
        {"LeftBracket", 0x10000 | VK_OEM_4}, {"Backslash", 0x10000 | VK_OEM_5}, {"RightBracket", 0x10000 | VK_OEM_6}, {"Apostrophe", 0x10000 | VK_OEM_7},
        {"LeftMouseButton", 0x10000 | VK_LBUTTON}, {"RightMouseButton", 0x10000 | VK_RBUTTON}, {"MiddleMouseButton", 0x10000 | VK_MBUTTON},
        {"ThumbMouseButton", 0x10000 | VK_XBUTTON1}, {"ThumbMouseButton2", 0x10000 | VK_XBUTTON2},
        {"Gamepad_DPad_Up", 0x20000 | 0x0001}, {"Gamepad_DPad_Down", 0x20000 | 0x0002}, {"Gamepad_DPad_Left", 0x20000 | 0x0004},
        {"Gamepad_DPad_Right", 0x20000 | 0x0008}, {"Gamepad_Special_Right", 0x20000 | 0x0010}, {"Gamepad_Special_Left", 0x20000 | 0x0020},
        {"Gamepad_LeftThumbstick", 0x20000 | 0x0040}, {"Gamepad_RightThumbstick", 0x20000 | 0x0080}, {"Gamepad_LeftShoulder", 0x20000 | 0x0100},
        {"Gamepad_RightShoulder", 0x20000 | 0x0200}, {"Gamepad_FaceButton_Bottom", 0x20000 | 0x1000}, {"Gamepad_FaceButton_Right", 0x20000 | 0x2000},
        {"Gamepad_FaceButton_Left", 0x20000 | 0x4000}, {"Gamepad_FaceButton_Top", 0x20000 | 0x8000},
        {"Gamepad_LeftTrigger", 0x30000}, {"Gamepad_RightTrigger", 0x40000},
    };
    if (k[0] >= 'A' && k[0] <= 'Z' && k[1] == 0) return 0x10000 | (uint32_t)k[0];
    if (k[0] == 'F' && k[1] >= '1' && k[1] <= '9' && (k[2] == 0 || (k[2] >= '0' && k[2] <= '2' && k[3] == 0))) {
        int n = atoi(k + 1);
        if (n >= 1 && n <= 12) return 0x10000 | (uint32_t)(VK_F1 + n - 1);
    }
    for (size_t i = 0; i < sizeof T / sizeof T[0]; i++) if (strcmp(T[i].n, k) == 0) return T[i].c;
    return 0;
}
static void pn_keys_poll(void) {
    static uint16_t was, pend; static ULONGLONG pend_at, scan_at; static int pads[4];
    ULONGLONG now = GetTickCount64();
    HWND fg = GetForegroundWindow(); DWORD pid = 0;
    if (fg) GetWindowThreadProcessId(fg, &pid);
    int focus = pid == GetCurrentProcessId();
    WORD btn = 0; BYTE lt = 0, rt = 0;
    if (focus && g_pn_xget) {
        if (!g_pn_kactive || now - scan_at > 3000) {
            scan_at = now;
            for (int i = 0; i < 4; i++) { pn_xstate s; pads[i] = g_pn_xget((DWORD)i, &s) == 0; }
        }
        for (int i = 0; i < 4; i++) if (pads[i]) {
            pn_xstate s;
            if (g_pn_xget((DWORD)i, &s) == 0) { btn |= s.buttons; if (s.lt > lt) lt = s.lt; if (s.rt > rt) rt = s.rt; } else pads[i] = 0;
        }
    }
    uint16_t down = 0;
    if (focus) for (int a = 0; a < 13; a++) {
        LONG nk = g_pn_nkey[a];
        for (LONG k = 0; k < nk && k < 6; k++) {
            uint32_t c = g_pn_key[a][k], v = c & 0xFFFF; int d = 0;
            switch (c >> 16) {
            case 1: d = (GetAsyncKeyState((int)v) & 0x8000) != 0; break;
            case 2: d = (btn & v) != 0; break;
            case 3: d = lt > 60; break;
            case 4: d = rt > 60; break;
            }
            if (d) { down |= (uint16_t)(1 << a); break; }
        }
    }
    if (!g_pn_kactive) { g_pn_kactive = 1; was = down; pend = 0; logf_("piano: reading our keys (%s, XInput %s)", focus ? "window has focus" : "window not in front", g_pn_xget ? "there" : "missing"); return; }
    uint16_t edge = down & (uint16_t)~was; was = down;
    if (edge) { if (!pend) pend_at = now; pend |= edge; }
    int bits = 0;
    for (int i = 0; i < 13; i++) if (pend & (1 << i)) bits++;
    // two keys within 25 ms are one chord, like two in one frame for the camera
    if (pend && (bits >= 2 || now - pend_at >= 25)) {
        while (pend) {
            uint16_t m = 0; int got = 0;
            for (int i = 0; i < 13 && got < 2; i++) if (pend & (1 << i)) { m |= (uint16_t)(1 << i); got++; }
            pend &= (uint16_t)~m;
            pn_schedule(now, m, 1, 0);
            pn_record(m, 0);
        }
    }
}
static DWORD WINAPI pn_thread(LPVOID unused) {
    (void)unused;
    // 11-09 20:33: pianoout from the last run kept ids up to 60; this run's presses 1..60 were taken for "already sent" (about 15 s of playing never left the PC)
    {
        static const char *stale[] = { "CoopNative.pianoout", "CoopNative.pianoin", "CoopNative.pianofx", "CoopNative.piano" };
        for (int i = 0; i < 4; i++) {
            char sp[MAX_PATH + 40];
            snprintf(sp, sizeof sp, "%s%s", g_dir, stale[i]);
            DeleteFileA(sp);
        }
    }
    HMODULE x = LoadLibraryA("xinput1_4.dll");
    if (!x) x = LoadLibraryA("xinput9_1_0.dll");
    if (x) g_pn_xget = (pn_xget_fn)GetProcAddress(x, "XInputGetState");
    logf_("piano: thread up (XInput %s)", g_pn_xget ? "found" : "missing");
    ULONGLONG last_in = 0, last_out = 0;
    for (;;) {
        ULONGLONG now = GetTickCount64();
        int busy = g_pn_keys || g_pn_rec || g_pn_qn || (g_pn_in_have && now - g_pn_in_last < 15000);
        Sleep(busy ? 4 : 50);
        now = GetTickCount64();
        if (g_pn_keys) pn_keys_poll();
        else g_pn_kactive = 0;
        if (now - last_in >= (ULONGLONG)(busy ? 8 : 50)) { last_in = now; pn_take_in(); }
        if (now - last_out >= 15) { last_out = now; pn_write_out(); }
    }
    return 0;
}
static void pn_read(void) {
    char b[6144];
    if (!read_small_file("CoopNative.piano", b, sizeof b)) return;
    unsigned long long ak = 0, ev[13] = {0}, cls = 0, ranim = 0, manim = 0, v = 0;
    int off = 0, rec = 0, keys = 0, i = 0, nev = 0;
    uint32_t key[13][6]; LONG nkey[13]; int unknown = 0, nk = 0;
    memset(key, 0, sizeof key); memset(nkey, 0, sizeof nkey);
    char kn[64];
    for (char *line = strtok(b, "\r\n"); line; line = strtok(NULL, "\r\n")) {
        if (sscanf(line, "ak %llx", &v) == 1) ak = v;
        else if (sscanf(line, "ev %d %llx", &i, &v) == 2) { if (i >= 0 && i < 13) { ev[i] = v; nev++; } }
        else if (sscanf(line, "cls %llx", &v) == 1) cls = v;
        else if (sscanf(line, "off %d", &i) == 1) off = i;
        else if (sscanf(line, "rec %d", &i) == 1) rec = i;
        else if (sscanf(line, "keys %d", &i) == 1) keys = i;
        else if (sscanf(line, "ranim %llx", &v) == 1) ranim = v;
        else if (sscanf(line, "manim %llx", &v) == 1) manim = v;
        else if (sscanf(line, "key %d %63s", &i, kn) == 2 && i >= 0 && i < 13) {
            uint32_t c = pn_keycode(kn);
            if (!c) unknown++;
            else if (nkey[i] < 6) { key[i][nkey[i]++] = c; nk++; }
        }
    }
    int have = ak && nev == 13 && readable((uintptr_t)ak, 8);
    for (int k = 0; k < 13; k++) if (!ev[k]) have = 0;
    InterlockedExchange(&g_pn_keys, 0);
    for (int a = 0; a < 13; a++) { for (int k = 0; k < 6; k++) g_pn_key[a][k] = key[a][k]; g_pn_nkey[a] = nkey[a]; }
    g_pn_ak_vt = have ? *(uintptr_t *)(uintptr_t)ak : 0;
    for (int k = 0; k < 13; k++) g_pn_ev[k] = (uintptr_t)ev[k];
    g_pn_ak = (uintptr_t)ak; g_pn_cls = (uintptr_t)cls; g_pn_off = off;
    g_pn_ranim_vt = ranim && readable((uintptr_t)ranim, 8) ? *(uintptr_t *)(uintptr_t)ranim : 0; g_pn_ranim = (uintptr_t)ranim;
    g_pn_manim_vt = manim && readable((uintptr_t)manim, 8) ? *(uintptr_t *)(uintptr_t)manim : 0; g_pn_manim = (uintptr_t)manim;
    InterlockedExchange(&g_pn_have, have);
    InterlockedExchange(&g_pn_rec, rec);
    InterlockedExchange(&g_pn_keys, keys && have);
    logf_("piano: %s, component 0x%llX, pose offset 0x%X, record %d, our keys %d (%d keys read, %d unknown names), other pianist 0x%llX, us 0x%llX",
          have ? "ready" : "not ready", ak, off, rec, keys, nk, unknown, ranim, manim);
}
static int install(const char *name, uint64_t addr, const char *expect16, void *detour, void **orig) {
    const uint8_t *p = (const uint8_t *)(uintptr_t)addr;
    MEMORY_BASIC_INFORMATION mbi;
    const DWORD exec = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (!VirtualQuery(p, &mbi, sizeof mbi) || mbi.State != MEM_COMMIT || !(mbi.Protect & exec)) {
        logf_("%s: 0x%llX not executable yet (state 0x%lX, protect 0x%lX)", name, (unsigned long long)addr,
              (unsigned long)mbi.State, (unsigned long)mbi.Protect);
        return 0;
    }
    logf_("%s: first bytes %02X %02X %02X %02X %02X %02X %02X %02X", name, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    if (!readable(addr, 16) || memcmp(p, expect16, 16) != 0) {
        logf_("%s: bytes at 0x%llX do not match this build's code, NOT hooking (different game version?)", name,
              (unsigned long long)addr);
        return -1;
    }
    MH_STATUS s = MH_CreateHook((LPVOID)p, detour, orig);
    if (s == MH_OK && !g_hook_batch) s = MH_EnableHook((LPVOID)p);
    logf_("%s: hook at 0x%llX -> %s%s", name, (unsigned long long)addr, MH_StatusToString(s), g_hook_batch ? " (queued)" : "");
    return s == MH_OK ? 1 : -1;
}


// Death trace (trace_death=1 in CoopNative.ini, read once at startup; log only). Session 8: a Lua trace of these UFunctions crashed
// the game at the title screen, so the exec thunks (UE4SS object dump [f:], fixed without ASLR) are detoured natively instead. Each
// detour logs the call with the calling object (FFrame + 0x18) and its class (UObject + 0x10), then passes through. Calls from
// Blueprints and Lua go through these thunks; native C++ callers do not.
#define TRACE_N 17
static const char *g_trace_name[TRACE_N] = {"CharacterHelper:TryExecuteDeath", "CharacterHelper:RequestTryExecuteDeath", "DeathComponent:Multicast_MigrationToDeath", "AIDataManager:OnPlayerDeath", "UIHelper:RequestDeathFade", "FadeUIComponentIF:RequestDeathFade", "FadeUIComponentIF:RequestUnfade", "FadeUIComponentIF:RequestLoadingFade", "FadeUIComponentIF:FinishCurrentFadeKind", "CharacterHelper:RequestPlayerRespawn", "CharacterHelper:RequestPlayerSpawn", "BaseInputController:ServerRequestGuestPlayerSpawn", "HumanCommonBase:RPCServer_RequestRespawn", "CheckPointUIComponent:RequestPlayerSpawnToLastCheckPoint", "BaseInputController:SetTemporaryInputMask", "BaseInputController:ClearTemporaryInputMask", "BaseInputController:ClearAllTemporaryInputMask"};
static exec_fn g_trace_orig[TRACE_N];
static void trace_note(int i, void *ctx, void *stack) {
    uintptr_t obj = 0, cls = 0;
    if (stack && readable((uintptr_t)stack + 0x18, 8)) obj = *(uintptr_t *)((uintptr_t)stack + 0x18);
    if (obj && readable(obj + 0x10, 8)) cls = *(uintptr_t *)(obj + 0x10);
    logf_("TRACE %s ctx=0x%llX caller=0x%llX class=0x%llX", g_trace_name[i], (unsigned long long)(uintptr_t)ctx,
          (unsigned long long)obj, (unsigned long long)cls);
    // Session 8: an enemy kill on the guest reached RequestDeathFade without TryExecuteDeath or MigrationToDeath on either PC:
    // log the native call chain for the death-fade requests to find the common death point.
    if (strstr(g_trace_name[i], "DeathFade") || strstr(g_trace_name[i], "TryExecuteDeath")) {
        void *frames[24];
        USHORT n = RtlCaptureStackBackTrace(1, 24, frames, NULL);
        char bt[24 * 20] = "";
        for (USHORT k = 0; k < n; k++) {
            char one[20];
            snprintf(one, sizeof one, " %llX", (unsigned long long)(uintptr_t)frames[k]);
            strcat_s(bt, sizeof bt, one);
        }
        logf_("TRACE   backtrace:%s", bt);
    }
}
#define TRACE_DETOUR(i) static void trace_det_##i(void *c, void *s, void *r) { trace_note(i, c, s); g_trace_orig[i](c, s, r); }

TRACE_DETOUR(0)
TRACE_DETOUR(1)
TRACE_DETOUR(2)
TRACE_DETOUR(3)
TRACE_DETOUR(4)
TRACE_DETOUR(5)
TRACE_DETOUR(6)
TRACE_DETOUR(7)
TRACE_DETOUR(8)
TRACE_DETOUR(9)
TRACE_DETOUR(10)
TRACE_DETOUR(11)
TRACE_DETOUR(12)
TRACE_DETOUR(13)
TRACE_DETOUR(14)
TRACE_DETOUR(15)
TRACE_DETOUR(16)
static void *g_trace_det[TRACE_N] = {(void *)trace_det_0, (void *)trace_det_1, (void *)trace_det_2, (void *)trace_det_3, (void *)trace_det_4, (void *)trace_det_5, (void *)trace_det_6, (void *)trace_det_7, (void *)trace_det_8, (void *)trace_det_9, (void *)trace_det_10, (void *)trace_det_11, (void *)trace_det_12, (void *)trace_det_13, (void *)trace_det_14, (void *)trace_det_15, (void *)trace_det_16};
static const uint64_t g_trace_addr[TRACE_N] = {0x140A7CA70ULL, 0x140A76D10ULL, 0x140AA3D40ULL, 0x1409E4700ULL, 0x140B6ECF0ULL, 0x140AC7230ULL, 0x140AC76F0ULL, 0x140AC7330ULL, 0x140B62460ULL, 0x140A76620ULL, 0x140A767A0ULL, 0x140A3EF80ULL, 0x140ADA3B0ULL, 0x140A84770ULL, 0x140A3F380ULL, 0x140A3BE80ULL, 0x140A3BDE0ULL};
static const char *g_trace_expect[TRACE_N] = {
    "\xE9\x7B\x55\x34\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xDB\x2B\x33\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xBB\x63\x64\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x4B\xEB\xAF\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xCB\x7F\x52\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x8B\x83\x91\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xAB\x8B\x91\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x2B\x84\x91\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\x48\x8B\x42\x20\x45\x33\xC0\x48\x85\xC0\x41\x0F\x95\xC0\x4C\x03",
    "\xE9\xCB\x1C\x33\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x6B\x25\x33\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\x40\x53\x48\x83\xEC\x20\x48\x8B\x42\x20\x45\x33\xC0\x48\x85\xC0",
    "\x40\x53\x48\x83\xEC\x20\x48\x8B\x42\x20\x45\x33\xC0\x48\x85\xC0",
    "\xE9\xEB\xAA\x3A\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\xCB\x18\x11\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x3B\xEC\x01\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC",
    "\xE9\x5B\xE9\x01\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};

// Keep a guest "dying" instead of dead (keep_dying=1, host only; session 8). A final death on the host goes CharacterHelper::
// RequestTryExecuteDeath (thunk 0x140A76D10) -> 0x140508540(world context, dying character, ...), which sends "execute death" to that
// character's death component and returns whether it did; Multicast_MigrationToDeath follows and the dead player's own death sequence
// starts (death fade, input lock, leave). Patching that sequence after the fact failed, so answer "no" here for any character that is
// not the host's own while the host lives: the guest stays in the revivable dying state. CoopProbe writes the host's living pawn
// address to CoopNative.host ("0" = do not veto); it is read at the moment of the decision.
// Second test (same session): an enemy kill of the guest never reached this function: his own game ran the death through a
// component's death-processing function (stub 0x14056AC60, body 0x14628F790; arg 1 = the component, its +0xE8 = the dying
// character) when his dying countdown ran out. Enemies die through it too, so "everyone but the host" became an explicit list:
// CoopProbe writes the characters to protect to CoopNative.protect (hex addresses separated by spaces; host: the guests' pawns in its
// world, guest: his own pawn), and both functions veto only for those.
#define ADDR_TRY_EXECUTE_DEATH 0x140508540ULL
#define ADDR_DEATH_PROCESS 0x14056AC60ULL
typedef uint8_t (*trydeath_fn)(void *world, void *target, uint8_t a3, uint8_t a4, uint8_t a5);
typedef void (*deathproc_fn)(void *component, void *arg);
static trydeath_fn g_orig_try_death;
static deathproc_fn g_orig_death_process;
static volatile ULONGLONG g_last_death_veto_log, g_last_proc_veto_log;
static int is_protected(uintptr_t who) {
    char buf[128];
    if (!who || !read_small_file("CoopNative.protect", buf, sizeof buf)) return 0;
    for (char *p = buf; *p; ) {
        char *end;
        uintptr_t a = (uintptr_t)strtoull(p, &end, 16);
        if (end == p) break;
        if (a && a == who) return 1;
        p = end;
    }
    return 0;
}
// The moment a veto fires is the "true death" (the revive window ran out): note the character in CoopNative.truedead so
// CoopProbe starts spectating only then, and teleports the guest next to the host when he is revived on the host's rest.
// The marker is "<hex address> <source>": T = TryExecuteDeath (a death request while standing: an enemy hit, after which he goes
// down, or a fall, after which he stays standing), P = DeathProcess (his revive window ran out). CoopProbe tells them apart (session 9).
static void note_true_death(uintptr_t who, char src) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.truedead", g_dir);
    FILE *f = _fsopen(path, "w", _SH_DENYNO);
    if (f) { fprintf(f, "%llX %c", (unsigned long long)who, src); fclose(f); }
}
static uint8_t detour_try_death(void *world, void *target, uint8_t a3, uint8_t a4, uint8_t a5) {
    if (is_protected((uintptr_t)target)) {
        ULONGLONG now = GetTickCount64();
        if (now - g_last_death_veto_log > 1000) {
            g_last_death_veto_log = now;
            logf_("TryExecuteDeath on 0x%llX (args %u %u %u)  *** VETOED (keep_dying) ***",
                  (unsigned long long)(uintptr_t)target, a3, a4, a5);
            note_true_death((uintptr_t)target, 'T');
        }
        return 0;
    }
    logf_("TryExecuteDeath on 0x%llX (args %u %u %u) (allowed)", (unsigned long long)(uintptr_t)target, a3, a4, a5);
    return g_orig_try_death(world, target, a3, a4, a5);
}
// The revive window running out also plays the character's dissolve (AppCharacter:ExecuteDisappearExpression, a Blueprint-callable
// UFunction, exec thunk 0x1409EE3F0); it runs apart from the death processing, so a guest revived after a true death stayed invisible
// on both PCs (session 8). Skip it for protected characters. The function has no parameters; when called from a Blueprint the thunk
// still does P_FINISH (Stack.Code += 1 if Code is set, FFrame + 0x20), which the skip must do too or the Blueprint VM desyncs.
#define ADDR_EXEC_DISAPPEAR 0x1409EE3F0ULL
static exec_fn g_orig_disappear;
static void detour_disappear(void *ctx, void *stack, void *result) {
    if (is_protected((uintptr_t)ctx)) {
        logf_("ExecuteDisappearExpression on 0x%llX  *** SKIPPED (keep_dying) ***", (unsigned long long)(uintptr_t)ctx);
        if (stack && readable((uintptr_t)stack + 0x20, 8)) {
            uintptr_t *code = (uintptr_t *)((uintptr_t)stack + 0x20);
            if (*code) *code += 1;
        }
        return;
    }
    g_orig_disappear(ctx, stack, result);
}

// After a true death the guest is only kept "dying" by our veto, so the partner (Io) could still revive him (session 8). The
// game's own "can this character never be revived" check is CharacterHelper::IsNeverRevive (thunk 0x140A6E6C0 -> impl stub
// 0x1404F8170(target) -> bool); answer true for the character in CoopNative.truedead until the host's rest respawns him.
#define ADDR_NEVER_REVIVE 0x1404F8170ULL
typedef uint8_t (*neverrevive_fn)(void *target);
static neverrevive_fn g_orig_never_revive;
static volatile ULONGLONG g_last_nr_log;
static uintptr_t true_dead_now(void) {
    char buf[32];
    if (!read_small_file("CoopNative.truedead", buf, sizeof buf)) return 0;
    return (uintptr_t)strtoull(buf, NULL, 16);
}
static uint8_t detour_never_revive(void *target) {
    uint8_t r = g_orig_never_revive(target);
    uintptr_t td = true_dead_now();
    if (!r && td && (uintptr_t)target == td) {
        ULONGLONG now = GetTickCount64();
        if (now - g_last_nr_log > 1000) { g_last_nr_log = now; logf_("IsNeverRevive(0x%llX) -> true (true death, keep_dying)", (unsigned long long)td); }
        return 1;
    }
    return r;
}

// Vestige restoration with a session (vestige_keep=1; R4 stage 2, session 9). The restoration screen BP_BCRestorationUIComponent
// asks IsCreateSession and GetOnlineOtherPlayerNum before a memory and then shows "ending the distress signal / co-op" and destroys
// the session. Calls from that screen (FFrame + 0x18 object of the class CoopProbe sends) are always logged; with vestige_keep=1
// they get "no session" / 0 other players, so the memory plays with the session kept. Every other caller sees the real answer.
static int from_restore(void *stack) {
    uintptr_t cls = g_restore_class;
    if (!cls || !stack || !readable((uintptr_t)stack + 0x18, 8)) return 0;
    uintptr_t obj = *(uintptr_t *)((uintptr_t)stack + 0x18);
    return obj && readable(obj + 0x10, 8) && *(uintptr_t *)(obj + 0x10) == cls;
}
static exec_fn g_orig_other_player_num, g_orig_is_create_session;
static void detour_other_player_num(void *ctx, void *stack, void *result) {
    g_orig_other_player_num(ctx, stack, result);
    if (!result || !from_restore(stack)) return;
    int real = *(int *)result;
    if (g_vestige_keep) *(int *)result = 0;
    logf_("restoration screen: GetOnlineOtherPlayerNum = %d%s", real, g_vestige_keep ? " -> 0 (vestige_keep)" : "");
}
static void detour_is_create_session(void *ctx, void *stack, void *result) {
    g_orig_is_create_session(ctx, stack, result);
    if (!result || !from_restore(stack)) return;
    int real = *(unsigned char *)result;
    if (g_vestige_keep) *(unsigned char *)result = 0;
    logf_("restoration screen: IsCreateSession = %d%s", real, g_vestige_keep ? " -> 0 (vestige_keep)" : "");
}

// Group teleport v1 (session 9): a Mistle teleport is not a move but RequestPlayerSpawnToCheckPoint(FieldID, PointIndex), a fresh
// spawn at the target Mistle (solo trace 2026-10-29: no deferred-teleport calls, the characters re-spawned). Note it in
// CoopNative.teleport so CoopProbe (group_teleport=1, host) spawns the guests next to the host once the host has arrived.
// Arrival (second solo run, cross-area): the new characters appear ~8 s later with AppCharacter:MulticastInitialDataSync; the
// first one after the teleport writes "arrived" to the same file (the pawn address alone changed too early, during the loading).
static exec_fn g_orig_spawn_to_checkpoint;
static volatile LONG g_tp_pending;
static void write_teleport_marker(const char *what) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.teleport", g_dir);
    FILE *f = _fsopen(path, "w", _SH_DENYNO);
    if (f) { fprintf(f, "%s %llu", what, (unsigned long long)GetTickCount64()); fclose(f); }
}
static void detour_spawn_to_checkpoint(void *ctx, void *stack, void *result) {
    logf_("RequestPlayerSpawnToCheckPoint on 0x%llX (Mistle teleport)", (unsigned long long)(uintptr_t)ctx);
    write_teleport_marker("start");
    InterlockedExchange(&g_tp_pending, 1);
    g_orig_spawn_to_checkpoint(ctx, stack, result);
}

// Boss-end kick (keep_outro=1; session 8): a boss kill multicasts MulticastFinishBossBattle(true) and the guest reacts by leaving.
// Session 3 flipped it in Lua: the guest stayed, but the host hung on a loading screen at the outro start (and session 7: the
// outro waits for a held guest). With the TRACE of the outro waits this shows which wait it is. Off by default.
static exec_fn g_orig_finish_boss;
static void detour_finish_boss(void *ctx, void *stack, void *result) {
    int flag = -1;
    if (stack && readable((uintptr_t)stack + 0x20, 16) && *(uintptr_t *)((uintptr_t)stack + 0x20) == 0) {
        uintptr_t locals = *(uintptr_t *)((uintptr_t)stack + 0x28);
        if (locals && readable(locals, 1)) {
            flag = *(unsigned char *)locals;
            if (g_keep_outro && flag) { *(unsigned char *)locals = 0; g_outro_at = GetTickCount64(); g_outro_at_early = g_outro_at; }
        }
    }
    g_bosskill_at = GetTickCount64(); g_branch_kill_at = g_bosskill_at;
    logf_("MulticastFinishBossBattle(bWithDisconnect=%d) on 0x%llX%s", flag, (unsigned long long)(uintptr_t)ctx,
          g_keep_outro && flag > 0 ? "  *** FLIPPED to 0 (keep_outro) ***" : "");
    g_orig_finish_boss(ctx, stack, result);
    // session 10: tell CoopProbe which boss area finished (guest_outro starts the area's FinishEvent on the guest)
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.outro", g_dir);
    FILE *f = _fsopen(path, "w", _SH_DENYNO);
    if (f) { fprintf(f, "%llX", (unsigned long long)(uintptr_t)ctx); fclose(f); }
}

// Boss-area cutscenes (session 10): MulticastExecuteFlowDiagramWithCallback(type) runs a flow diagram on every PC (type 0
// PrePhase1Event = the intro, 1/2 EndPhase1Event1/2, 3 FinishEvent = the post-boss cutscene). Logged with its type when it arrives
// as an RPC (no bytecode: parameters at FFrame+0x28); a call from Blueprint bytecode is logged without the type.
static exec_fn g_orig_flow_diagram;
static void detour_flow_diagram(void *ctx, void *stack, void *result) {
    int type = -1;
    if (stack && readable((uintptr_t)stack + 0x20, 16) && *(uintptr_t *)((uintptr_t)stack + 0x20) == 0) {
        uintptr_t locals = *(uintptr_t *)((uintptr_t)stack + 0x28);
        if (locals && readable(locals, 1)) type = *(unsigned char *)locals;
    }
    logf_("MulticastExecuteFlowDiagramWithCallback(type %d%s) on 0x%llX", type, type < 0 ? " = from bytecode" : "",
          (unsigned long long)(uintptr_t)ctx);
    g_orig_flow_diagram(ctx, stack, result);
}

static exec_fn g_orig_server_addexp;
#define GUEST_REST_MAGIC (-2601)
static volatile ULONGLONG g_guest_rest_req_at;
static void detour_server_addexp(void *ctx, void *stack, void *result) {
    // RPCs run through ProcessEvent: no bytecode (FFrame+0x20 == 0), the parameters are at FFrame+0x28 (Locals), Value first
    int value = 1;
    if (stack && readable((uintptr_t)stack + 0x20, 16) && *(uintptr_t *)((uintptr_t)stack + 0x20) == 0) {
        uintptr_t locals = *(uintptr_t *)((uintptr_t)stack + 0x28);
        if (locals && readable(locals, 4)) value = *(int *)locals;
    }
    // Home Base flavor sync (2026-11-06): the guest's only way to the host is a number. Values from -3000000 down are not exp: handed to CoopProbe, swallowed.
    if (value <= -3000000) {
        if ((-value - 3000000) / 16777216 == 12) { pn_in_append((-value - 3000000) % 16777216); return; }
        char fp_[MAX_PATH + 32];
        snprintf(fp_, sizeof fp_, "%sCoopNative.flavorin", g_dir);
        FILE *ff = fopen(fp_, "a");
        if (ff) { fprintf(ff, "%d\n", -value - 3000000); fclose(ff); }
        return;
    }
    // item 6b: the guest's rest asks the host for an enemy reset with Server_AddExp(-2601) (a value no real exp gain has); swallowed
    if (value == GUEST_REST_MAGIC) {
        g_guest_rest_req_at = GetTickCount64();
        logf_("guest rest request (Server_AddExp(%d) from component 0x%llX): enemy reset wanted", value, (unsigned long long)(uintptr_t)ctx);
        {   // 2026-11-06: tells CoopProbe where the last Mistle use was (a guest who dies in the field respawns there)
            char rp_[MAX_PATH + 32];
            snprintf(rp_, sizeof rp_, "%sCoopNative.guestrest", g_dir);
            FILE *rf = fopen(rp_, "w");
            if (rf) { fputs("1", rf); fclose(rf); }
        }
        return;
    }
    if (g_levelup_relay && value != 0) logf_("Server_AddExp(%d) from component 0x%llX", value, (unsigned long long)(uintptr_t)ctx);
    if (g_levelup_relay && value == 0) {
        uintptr_t pawn = first_protected();
        if (pawn) {
            g_levelup_ctx = (uintptr_t)ctx; g_levelup_pawn = pawn;
            InterlockedIncrement(&g_levelup_n);
            InterlockedExchange(&g_levelup_pending, 1);
            logf_("Server_AddExp(0) from component 0x%llX = guest level-up -> +1 for pawn 0x%llX", (unsigned long long)(uintptr_t)ctx,
                  (unsigned long long)pawn);
            g_orig_server_addexp(ctx, stack, result);
            return;
        }
    }
    g_orig_server_addexp(ctx, stack, result);
}
static uint8_t detour_level_up(void *ctx, int uplevel) {
    // Session 8: the guest owns his level and haze (the host copy mirrors him; host-side level-ups do not stick, and his haze went up
    // when the host sent Server_AddExp). His own level-up "succeeded" but his level never moved: on his PC 0x141DF4530(ctx, 0) seems
    // to return the host's character, so the level-up went to the host's copy there. Redirect it to his own pawn (the protect list
    // holds his pawn on his PC); CoopProbe's resync after the menu then carries the new level to the host.
    // update 44: even redirected, the message path reported 1 while neither level nor haze moved on his component. Call the
    // HumanContextIF level-up 0x1405A2E20(iface, N) directly on his own HumanContextComponent (address from CoopProbe in
    // CoopNative.mycomp; interface via 0x140EBF6A0(component, HumanContextIF class)).
    // update 45: called directly on his component the level-up spent his haze but his level stayed: the host owns the level, the
    // guest owns the haze. So the guest does nothing locally and only asks the host (relay file -> Server_AddExp(0)); the host
    // runs the real level-up on his copy (run_levelup below).
    // update 46: the host-side direct level-up did not move his level either (the host's getter derives it too). Now: the direct
    // call on his own component again, with 0x140456A00 forced true for his pawn during the call (see detour_in_charge).
    if (g_guest_rest && !g_override_player) {
        char buf[32];
        uintptr_t comp = read_small_file("CoopNative.mycomp", buf, sizeof buf) ? (uintptr_t)strtoull(buf, NULL, 16) : 0;
        if (comp && readable(comp, 8)) {
            void *ifcls = ((void *(*)(void))0x140AD6680ULL)();
            uintptr_t iface = (uintptr_t)((getiface_fn)0x140EBF6A0ULL)((void *)comp, ifcls);
            if (iface && readable(iface, 8)) {
                uintptr_t me = first_protected();
                g_force_tid = GetCurrentThreadId(); g_force_in_charge = me;
                uint8_t r = ((uint8_t (*)(void *, int))0x1405A2E20ULL)((void *)iface, uplevel);
                g_force_in_charge = 0;
                logf_("LevelUpPlayer(+%d) on the guest: HumanContextIF level-up called directly on 0x%llX (in charge forced for 0x%llX) -> %u",
                      uplevel, (unsigned long long)comp, (unsigned long long)me, r);
                if (r) {   // tell the host so its copy of him gets the level too (max HP is computed there)
                    char rp[MAX_PATH];
                    snprintf(rp, sizeof rp, "%sCoopNative.levelup", g_dir);
                    FILE *rf = _fsopen(rp, "w", _SH_DENYNO);
                    if (rf) { fprintf(rf, "%d", uplevel); fclose(rf); }
                }
                char path[MAX_PATH];
                snprintf(path, sizeof path, "%sCoopNative.lvlwatch", g_dir);
                FILE *f = _fsopen(path, "w", _SH_DENYNO);
                if (f) { fputs("1", f); fclose(f); }
                return r;
            }
        }
    }
    if (g_guest_rest && !g_override_player) {
        uintptr_t me = first_protected();
        if (me) {
            g_override_tid = GetCurrentThreadId(); g_override_player = me;
            uint8_t r = g_orig_level_up(ctx, uplevel);
            g_override_player = 0;
            logf_("LevelUpPlayer(+%d) on the guest, redirected to his own pawn 0x%llX -> %u", uplevel, (unsigned long long)me, r);
            char path[MAX_PATH];   // let CoopProbe measure his component level over the next seconds
            snprintf(path, sizeof path, "%sCoopNative.lvlwatch", g_dir);
            FILE *f = _fsopen(path, "w", _SH_DENYNO);
            if (f) { fputs("1", f); fclose(f); }
            return r;
        }
    }
    return g_orig_level_up(ctx, uplevel);
}

static void detour_death_process(void *component, void *arg) {
    uintptr_t c = (uintptr_t)component, who = 0;
    if (c && readable(c + 0xE8, 8)) who = *(uintptr_t *)(c + 0xE8);
    if (is_protected(who)) {
        ULONGLONG now = GetTickCount64();
        if (now - g_last_proc_veto_log > 1000) {
            g_last_proc_veto_log = now;
            logf_("DeathProcess for 0x%llX  *** VETOED (keep_dying) ***", (unsigned long long)who);
            note_true_death(who, 'P');
        }
        return;
    }
    g_orig_death_process(component, arg);
}

// Initial-data sync trace (always on, log only; session 8 R6): the join-time sync runs per component (AppCharacter /
// AppActorComponent ServerInitialDataSync, Jinkaku/Weapon ServerCustomInitialDataSync, and the Multicast answers) and each marks
// itself bIsInitialSynced. A guest's menu changes (level, gifts) are never synced after joining; CoopProbe clears the flags after his
// Mistle menu closes to see whether the game sends the sync again. These detours only log the calls.
#define SYNC_N 6
static const char *g_sync_name[SYNC_N] = {"AppCharacter:ServerInitialDataSync", "AppCharacter:MulticastInitialDataSync", "AppActorComponent:ServerInitialDataSync", "AppActorComponent:MulticastInitialDataSync", "JinkakuComponent:ServerCustomInitialDataSync", "WeaponComponent:ServerCustomInitialDataSync"};
static const uint64_t g_sync_addr[SYNC_N] = {0x1409EFA20ULL, 0x1409EE880ULL, 0x1409EFAD0ULL, 0x1409EE900ULL, 0x140AE9390ULL, 0x140B83930ULL};
static const char *g_sync_expect[SYNC_N] = {"\xE9\x5B\x7D\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\x36\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\x80\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xAB\x37\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xAB\xE6\xB0\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x31\x5E\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};
static exec_fn g_sync_orig[SYNC_N];
static volatile LONG g_sync_count[SYNC_N];
// the first calls of each: native call chain, to find the function that builds and sends the sync at a join
static void sync_backtrace(int i) {
    if (g_sync_count[i] > 3) return;
    void *frames[20];
    USHORT n = RtlCaptureStackBackTrace(2, 20, frames, NULL);
    char bt[20 * 20] = "";
    for (USHORT k = 0; k < n; k++) { char one[20]; snprintf(one, sizeof one, " %llX", (unsigned long long)(uintptr_t)frames[k]); strcat_s(bt, sizeof bt, one); }
    logf_("SYNC   backtrace:%s", bt);
}
#define SYNC_DETOUR(i) static void sync_det_##i(void *c, void *st, void *r) { \
    if (i == 1 && g_tp_pending && InterlockedExchange(&g_tp_pending, 0)) { logf_("teleport: characters re-spawned (arrived)"); write_teleport_marker("arrived"); } \
    if (InterlockedIncrement(&g_sync_count[i]) <= 400) { logf_("SYNC %s on 0x%llX", g_sync_name[i], (unsigned long long)(uintptr_t)c); sync_backtrace(i); } \
    g_sync_orig[i](c, st, r); }
SYNC_DETOUR(0)
SYNC_DETOUR(1)
SYNC_DETOUR(2)
SYNC_DETOUR(3)
SYNC_DETOUR(4)
SYNC_DETOUR(5)
static void *g_sync_det[SYNC_N] = {(void *)sync_det_0, (void *)sync_det_1, (void *)sync_det_2, (void *)sync_det_3, (void *)sync_det_4, (void *)sync_det_5};

// Call trace (always on, log only; session 8). Gifts (R6): the menu-side calls (CharacterHelper Equip*/AcquireKetsugi) and the
// replicated equip RPCs (KetsugiComponent Server_/Multicast_Equip*Directly), so one equip attempt shows where it stops. Outro and
// memory sequence: the ScenarioActor WaitFor* steps, LargePoly/MemoryResidue and deferred teleport calls, so a boss kill with the
// guest kept shows which wait the host hangs on (session 3: loading screen at the outro start).
#define GIFT_N 27
static const char *g_gift_name[GIFT_N] = {"CharacterHelper:EquipActiveKetsugi", "CharacterHelper:EquipPassiveKetsugi", "CharacterHelper:AcquireKetsugi", "KetsugiComponent:Server_EquipKetsugiDirectly", "KetsugiComponent:Server_EquipPassiveKetsugiDirectly", "KetsugiComponent:Multicast_EquipKetsugiDirectly", "KetsugiComponent:Multicast_EquipPassiveKetsugiDirectly", "ScenarioActor:WaitForDeferredTeleportFinished", "ScenarioActor:WaitForLargePolyFinished", "ScenarioActor:WaitForMemoryResidueFinished", "ScenarioActor:WaitForPreparePolyFinished", "ScenarioActor:WaitForOnlineMultiplaySynced", "ScenarioActor:WaitForFadeFinished", "ScenarioManager:PlayMemoryResidue", "ScenarioManager:PlayLargePolySequence", "ScenarioManager:PrepareLargePolySequence", "ScenarioManager:StartLargePolyLoad", "LIBDeferredTeleportManager:BeginDeferredTeleport", "DeferredTeleportDriver:NotifyReadyToBeginTeleport", "DeferredTeleportDriver:NotifyReadyToEndTeleport", "CharacterHelper:RequestPlayerTeleportToHost", "ArticleAccessUIComponentBase:EquipActiveKetsugi", "ArticleAccessUIComponentBase:EquipPassiveKetsugi", "ArticleAccessUIComponentBase:EquipBloodCode", "CharacterHelper:EquipBloodCode", "BloodCodeComponent:Server_EquipBloodCode", "CheckPointUIComponent:MasterKetsugi"};
static const uint64_t g_gift_addr[GIFT_N] = {0x140A5E650ULL, 0x140A5E800ULL, 0x140A5B330ULL, 0x140AF0CD0ULL, 0x140AF0DD0ULL, 0x140AEFD90ULL, 0x140AEFE90ULL, 0x140B41190ULL, 0x140B41470ULL, 0x140B41550ULL, 0x140B41710ULL, 0x140B41630ULL, 0x140B41270ULL, 0x140B4B1D0ULL, 0x140B4B150ULL, 0x140B4B500ULL, 0x140B4CD80ULL, 0x140AA28F0ULL, 0x140AA3E00ULL, 0x140AA3E20ULL, 0x140A76B90ULL, 0x140A121C0ULL, 0x140A12310ULL, 0x140A12280ULL, 0x140A5E740ULL, 0x140A45360ULL, 0x140A84350ULL};
static const char *g_gift_expect[GIFT_N] = {"\xE9\x4B\xFD\x2D\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xDB\x04\x2E\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x58\x2D\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xCB\x35\xBB\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\x38\xBB\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x14\xBB\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x15\xBB\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x3C\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\x41\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x0B\x43\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xCB\x44\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x0B\x44\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x3D\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\xEC\x28\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x9B\xE8\x28\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\xEE\x28\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\x43\x29\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\x2D\x64\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xDB\x63\x64\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x6B\x66\x64\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x1B\x27\x33\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x2B\xE6\xD0\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\xE9\xD0\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xBB\xE7\xD0\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x2B\xFE\x2D\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xDB\x74\x14\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xAB\xA3\x3A\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};
static exec_fn g_gift_orig[GIFT_N];
static volatile LONG g_gift_count[GIFT_N];
static volatile uintptr_t g_museum_actor;   // (declared here so the memory start can clear it; set by the late scenario hooks)
static void gift_note(int i, void *c, void *st) {
    if (strstr(g_gift_name[i], "WaitForMemoryResidueFinished")) g_memory_actor = (uintptr_t)c;
    // session 10: the memory moves the host into its own area and waits for the guest, who never arrives (his game has no memory
    // ground, he falls). Treat the memory start like a host teleport: group teleport spawns the guest next to the host's memory
    // character once it is up (same "start"/"arrived" markers as a Mistle teleport).
    if (strstr(g_gift_name[i], "PlayMemoryResidue")) {
        g_memory_at = GetTickCount64(); g_memory_start_at = g_memory_at;
        // 2026-11-02: a second memory in the same game session (save reloaded) still had the first memory's museum actor here;
        // it was gone, so "memory end" fired 70 ms after the start (no guest memory window, a group teleport back, v5 off)
        g_museum_actor = 0;
        if (!g_host_pc && g_keep_outro) { write_guestmem(1); logf_("memory: guest memory window open (CoopProbe unlocks his input)"); }
        if (g_host_pc) relay_append("memstart");
    }
    if (g_keep_outro && g_group_teleport && g_memstart_tp && strstr(g_gift_name[i], "PlayMemoryResidue")) {
        logf_("memory start: guest follows like a group teleport");
        write_teleport_marker("start");
        InterlockedExchange(&g_tp_pending, 1);
    }
    if (InterlockedIncrement(&g_gift_count[i]) > 200) return;
    uintptr_t obj = 0;
    if (st && readable((uintptr_t)st + 0x18, 8)) obj = *(uintptr_t *)((uintptr_t)st + 0x18);
    logf_("TRACE %s ctx=0x%llX caller=0x%llX", g_gift_name[i], (unsigned long long)(uintptr_t)c, (unsigned long long)obj);
}
#define GIFT_DETOUR(i) static void gift_det_##i(void *c, void *st, void *r) { gift_note(i, c, st); g_gift_orig[i](c, st, r); }
GIFT_DETOUR(0)
GIFT_DETOUR(1)
GIFT_DETOUR(2)
GIFT_DETOUR(3)
GIFT_DETOUR(4)
GIFT_DETOUR(5)
GIFT_DETOUR(6)
GIFT_DETOUR(7)
GIFT_DETOUR(8)
GIFT_DETOUR(9)
GIFT_DETOUR(10)
GIFT_DETOUR(11)
GIFT_DETOUR(12)
GIFT_DETOUR(13)
GIFT_DETOUR(14)
GIFT_DETOUR(15)
GIFT_DETOUR(16)
GIFT_DETOUR(17)
GIFT_DETOUR(18)
GIFT_DETOUR(19)
GIFT_DETOUR(20)
GIFT_DETOUR(21)
GIFT_DETOUR(22)
GIFT_DETOUR(23)
GIFT_DETOUR(24)
GIFT_DETOUR(25)
GIFT_DETOUR(26)
static void *g_gift_det[GIFT_N] = {(void *)gift_det_0, (void *)gift_det_1, (void *)gift_det_2, (void *)gift_det_3, (void *)gift_det_4, (void *)gift_det_5, (void *)gift_det_6, (void *)gift_det_7, (void *)gift_det_8, (void *)gift_det_9, (void *)gift_det_10, (void *)gift_det_11, (void *)gift_det_12, (void *)gift_det_13, (void *)gift_det_14, (void *)gift_det_15, (void *)gift_det_16, (void *)gift_det_17, (void *)gift_det_18, (void *)gift_det_19, (void *)gift_det_20, (void *)gift_det_21, (void *)gift_det_22, (void *)gift_det_23, (void *)gift_det_24, (void *)gift_det_25, (void *)gift_det_26};

// Late scenario trace (session 10): the memory waits for the guest and the wait is unknown. Tracing every ScenarioActor wait
// from the start hung the boss intro (10-29), so these are installed only after a boss kill with keep_outro (worker thread,
// MinHook), and log each call with its scenario actor.
#define LATE_N 34
static const char *g_late_name[LATE_N] = {"ScenarioActor:WaitForWindowTime", "ScenarioActor:WaitForWindowProcessedOrTime", "ScenarioActor:WaitForWindowProcessed", "ScenarioActor:WaitForUIClosedEx", "ScenarioActor:WaitForUIClosed", "ScenarioActor:WaitForTurnTo", "ScenarioActor:WaitForSpecialPolyFinished", "ScenarioActor:WaitForSenarioActivated", "ScenarioActor:WaitForScenarioFinished", "ScenarioActor:WaitForOnlineMultiplaySynced", "ScenarioActor:WaitForFlowDiagramFinished", "ScenarioActor:WaitForFadeFinished", "ScenarioActor:WaitForDeferredTeleportFinished", "ScenarioActor:WaitForCharaPoseFinishedWithName", "ScenarioActor:WaitForCharaPoseFinishedWithByte", "ScenarioActor:WaitForCameraMoveFinished", "ScenarioActor:WaitForBurnOffFinishedWithName", "ScenarioActor:WaitForBurnOffFinishedWithByte", "ScenarioActor:WaitForAnimationFinished", "ScenarioActor:WaitForActorInvalid", "ScenarioActor:OnMemoryResidueFinished", "ScenarioActor:JumpToMemoryResidue", "MuseumUtilityActor:OnEventPlayed", "MuseumUtilityActor:OnEventFinished", "MuseumUtilityActor:FinishMuseum", "MuseumUtilityActor:SetIsAcceptSkip", "MuseumUtilityActor:SetScenarioFlowDiagram", "MuseumUtilityActor:SetEventSkipIndicator", "MuseumUtilityManager:SkipCurrentMuseum", "MuseumUtilityManager:FinishCurrentMuseum", "MuseumUtilityManager:KillMuseum", "MuseumUtilityManager:RetryCurrentMuseum", "MuseumUtilityManager:SetRelatedFlowDiagram", "MuseumUtilityManager:SetPlaceToGoBack"};
static const uint64_t g_late_addr[LATE_N] = {0x140B42180ULL, 0x140B41FA0ULL, 0x140B41E80ULL, 0x140B41D60ULL, 0x140B41C40ULL, 0x140B41AD0ULL, 0x140B419F0ULL, 0x140B41910ULL, 0x140B417F0ULL, 0x140B41630ULL, 0x140B41350ULL, 0x140B41270ULL, 0x140B41190ULL, 0x140B41070ULL, 0x140B40F50ULL, 0x140B40E30ULL, 0x140B40D10ULL, 0x140B40BF0ULL, 0x140B40A80ULL, 0x140B40960ULL, 0x140B3E100ULL, 0x140B3D200ULL, 0x140B0A000ULL, 0x140B09F10ULL, 0x140B53920ULL, 0x140B0A790ULL, 0x140B0AAC0ULL, 0x140B0A770ULL, 0x140B0AB40ULL, 0x140B09100ULL, 0x140B09E90ULL, 0x140B0A540ULL, 0x140B0AA10ULL, 0x140B0A8A0ULL};
static const char *g_late_expect[LATE_N] = {"\xE9\xDB\x5C\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x9B\x5B\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x5A\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x2B\x57\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x7B\x56\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x7B\x53\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x6B\x4F\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x4B\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xFB\x46\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x0B\x44\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xCB\x3F\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x3D\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x3B\x3C\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xFB\x3B\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x1B\x38\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x7B\x34\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\x32\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\x31\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x6B\x2D\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x2B\x23\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xAB\xB8\x22\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x7B\x47\x21\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x0B\xA8\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xCB\xA6\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\x48\x8B\x42\x20\x45\x33\xC0\x48\x85\xC0\x41\x0F\x95\xC0\x4C\x03", "\xE9\x4B\xC3\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xBB\xDB\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\xC2\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x4B\xDE\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x1B\x6D\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xDB\xA5\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x5B\xB8\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xAB\xD2\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xCB\xCF\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};
static exec_fn g_late_orig[LATE_N];
static volatile LONG g_late_count[LATE_N], g_late_installed;
// Museum state (session 10): OnMemoryResidueFinished is called through the museum manager's OnPostBeginPlayMuseum with the
// MuseumUtilityActor as its parameter (RPC-style call: FFrame+0x20 == 0, Locals at +0x28). Keep it for the worker's field dump.
static volatile ULONGLONG g_museum_at;
static void late_note(int i, void *c, void *st) {
    uintptr_t p0 = 0;
    if (st && readable((uintptr_t)st + 0x20, 16) && *(uintptr_t *)((uintptr_t)st + 0x20) == 0) {
        uintptr_t locals = *(uintptr_t *)((uintptr_t)st + 0x28);
        if (locals && readable(locals, 8)) p0 = *(uintptr_t *)locals;
    }
    if (strstr(g_late_name[i], "OnMemoryResidueFinished") && p0) { g_museum_actor = p0; g_museum_at = GetTickCount64(); }
    // memory polish (1)+(2): the memory ends with FinishMuseum: stop v5/v4 there (back in the field many characters are in setup and
    // must not be reset), and treat the return to the field like a group teleport so the guest is spawned next to the host instead
    // of being left out of bounds (same "start"/"arrived" markers as a Mistle teleport).
    // (0x140B53920 is shared code called for many objects: only the museum actor itself counts)
    if (strstr(g_late_name[i], "FinishMuseum") && g_memory_at && g_museum_actor && (uintptr_t)c == g_museum_actor) {
        g_memory_at = 0;
        if (g_keep_outro && g_group_teleport) {
            logf_("memory end: v5 off; guest follows the host back like a group teleport");
            relay_append("memend");
            write_teleport_marker("start memend");
            InterlockedExchange(&g_tp_pending, 1);
        }
    }
    if (InterlockedIncrement(&g_late_count[i]) <= 100)
        logf_("LATE %s ctx=0x%llX param0=0x%llX", g_late_name[i], (unsigned long long)(uintptr_t)c, (unsigned long long)p0);
}
#define LATE_DETOUR(i) static void late_det_##i(void *c, void *st, void *r) { late_note(i, c, st); g_late_orig[i](c, st, r); }
// MuseumUtilityActor::IsPlayerPlayable (thunk 0x140B09BD0): GetPlayerController(ctx, 0) -> its +0x388 -> a component interface
// check. Both museums (host and guest) sat ready but never started a scene; log each answer change and once every 10 s.
#define ADDR_EXEC_PLAYER_PLAYABLE 0x140B09BD0ULL
static exec_fn g_orig_playable;
static volatile LONG g_last_playable = -1;
static volatile ULONGLONG g_last_playable_log;
static void detour_playable(void *c, void *st, void *r) {
    g_orig_playable(c, st, r);
    int v = r ? *(uint8_t *)r : -1;
    // session 10: on the host this stayed 0 for the whole memory while the guest was connected (his answered 1 at once); with
    // keep_outro the host's museum is told the player is playable so it starts its scenes and lifts the loading screen
    // (the override that answered 1 here was removed: the solo baseline showed 0 is normal until the appear finishes, and forcing 1
    //  early made the museum stop polling before the host's character was ready)
    ULONGLONG now = GetTickCount64();
    if (v != g_last_playable || now - g_last_playable_log > 10000) {
        g_last_playable = v; g_last_playable_log = now;
        logf_("museum: IsPlayerPlayable on 0x%llX -> %s", (unsigned long long)(uintptr_t)c, v == 100 ? "0, answered 1 (keep_outro)" : v ? "1" : "0");
    }
}
LATE_DETOUR(0)
LATE_DETOUR(1)
LATE_DETOUR(2)
LATE_DETOUR(3)
LATE_DETOUR(4)
LATE_DETOUR(5)
LATE_DETOUR(6)
LATE_DETOUR(7)
LATE_DETOUR(8)
LATE_DETOUR(9)
LATE_DETOUR(10)
LATE_DETOUR(11)
LATE_DETOUR(12)
LATE_DETOUR(13)
LATE_DETOUR(14)
LATE_DETOUR(15)
LATE_DETOUR(16)
LATE_DETOUR(17)
LATE_DETOUR(18)
LATE_DETOUR(19)
LATE_DETOUR(20)
LATE_DETOUR(21)
LATE_DETOUR(22)
LATE_DETOUR(23)
LATE_DETOUR(24)
LATE_DETOUR(25)
LATE_DETOUR(26)
LATE_DETOUR(27)
LATE_DETOUR(28)
LATE_DETOUR(29)
LATE_DETOUR(30)
LATE_DETOUR(31)
LATE_DETOUR(32)
LATE_DETOUR(33)
static void *g_late_det[LATE_N] = {(void *)late_det_0, (void *)late_det_1, (void *)late_det_2, (void *)late_det_3, (void *)late_det_4, (void *)late_det_5, (void *)late_det_6, (void *)late_det_7, (void *)late_det_8, (void *)late_det_9, (void *)late_det_10, (void *)late_det_11, (void *)late_det_12, (void *)late_det_13, (void *)late_det_14, (void *)late_det_15, (void *)late_det_16, (void *)late_det_17, (void *)late_det_18, (void *)late_det_19, (void *)late_det_20, (void *)late_det_21, (void *)late_det_22, (void *)late_det_23, (void *)late_det_24, (void *)late_det_25, (void *)late_det_26, (void *)late_det_27, (void *)late_det_28, (void *)late_det_29, (void *)late_det_30, (void *)late_det_31, (void *)late_det_32, (void *)late_det_33};

// Fade trace (session 10): the memory start covers the host with UIHelper RequestLoadingFade(actor, actor, 106) and in co-op it
// never lifts. These are the native implementations behind UIHelper's fade functions: (context, caller, usage, flag, ...). The
// original runs first (its float arguments are on the stack, nothing is clobbered), then the call is logged with its return
// address, so a solo memory shows who lifts the loading fade. Always on, at most 300 lines per function.
#define FADE_N 5
static const char *g_fade_name[FADE_N] = {"RequestLoadingFade", "RequestUnfade", "RequestSolidFade", "RequestTeleportFade", "SetSolidFadeAsLoadingScreen"};
static const uint64_t g_fade_addr[FADE_N] = {0x1409CBDB0ULL, 0x1409CC650ULL, 0x1409CC160ULL, 0x1409CC360ULL, 0x1409CEC80ULL};
static const char *g_fade_expect[FADE_N] = {"\xE9\x4B\xCC\x99\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xEB\x30\x9A\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x9B\x2E\x9A\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\x6B\x2F\x9A\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", "\xE9\xBB\x4F\xA5\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC"};
typedef uint64_t (*fade_fn)(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h);
static fade_fn g_fade_orig[FADE_N];
static volatile LONG g_fade_count[FADE_N];
static void note_cover(int i, void *ctx, void *usage) {
    if (strcmp(g_fade_name[i], "RequestSolidFade") == 0 && ((uintptr_t)usage & 0xFF) == 104)
        g_cover_ctx[InterlockedIncrement(&g_cover_n) & 3] = (uintptr_t)ctx;
}
static int fade_hold_take(void *ctx, uintptr_t usage, uintptr_t flag) {
    if (!g_fade_hold) return 0;
    uint8_t u = (uint8_t)usage;   // 11-07 09:13: the teleport from Home Base lifts with usage 101, not 48
    LONG n = g_fade_held_n, i;
    for (i = 0; i < n && i < 8; i++) if (g_fade_held[i] == u) break;
    if (i == n && n < 8) { g_fade_held[n] = u; g_fade_held_flag[n] = (uint8_t)flag; g_fade_held_n = n + 1; }
    g_fade_ctx = (uintptr_t)ctx;
    logf_("fade hold: unfade with usage %u kept back", u);
    return 1;
}
#define FADE_DETOUR(i) static uint64_t fade_det_##i(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) { \
    uintptr_t ret = (uintptr_t)__builtin_return_address(0); \
    if (i == 1 && fade_hold_take(a, (uintptr_t)c, (uintptr_t)d)) return 0; \
    note_cover(i, a, c); \
    uint64_t r = g_fade_orig[i](a, b, c, d, e, f, g, h); \
    if (InterlockedIncrement(&g_fade_count[i]) <= 300) \
        logf_("FADE %s(ctx 0x%llX, caller 0x%llX, usage %u, flag %u) from 0x%llX", g_fade_name[i], (unsigned long long)(uintptr_t)a, \
              (unsigned long long)(uintptr_t)b, (unsigned)((uintptr_t)c & 0xFF), (unsigned)((uintptr_t)d & 0xFF), (unsigned long long)ret); \
    return r; }
FADE_DETOUR(0)
FADE_DETOUR(1)
FADE_DETOUR(2)
FADE_DETOUR(3)
FADE_DETOUR(4)
static void *g_fade_det[FADE_N] = {(void *)fade_det_0, (void *)fade_det_1, (void *)fade_det_2, (void *)fade_det_3, (void *)fade_det_4};

static char g_cl_result[300];
static void cl_start_zip(void);
static void cl_snapshot(void);
// Exit log package (2026-11-03, owner: no second start to get the zip). At every start CoopNative writes CoopLogs\\collect.ps1
// and starts it hidden with this process id; it waits until the game has ended (quit or crash), then zips CoopNative.log,
// UE4SS.log, the game's CodeVein.log, CoopProgress's journal and a crash report of this run into
// CoopLogs\\CoopLogs-<date>-<time>.zip (newest 5 kept) and, with log_share=<folder> in CoopNative.ini (a LAN share on the host's
// PC), copies the zip there. Nothing goes to the internet.
static const char *g_exit_ps =
    "param([int]$GamePid, [string]$Plugins, [string]$Share)\n"
    "Start-Transcript -Path (Join-Path (Join-Path $Plugins 'CoopLogs') 'collect.log') -Force | Out-Null\n"
    "$start = Get-Date\n"
    "try { Wait-Process -Id $GamePid -ErrorAction Stop } catch {}\n"
    "Start-Sleep -Seconds 8\n"
    "$root = Join-Path $Plugins 'CoopLogs'\n"
    "$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'\n"
    "$tmp = Join-Path $root ('exit-' + $stamp)\n"
    "New-Item -ItemType Directory -Force -Path $tmp | Out-Null\n"
    "Copy-Item (Join-Path $Plugins 'CoopNative.log') $tmp -ErrorAction SilentlyContinue\n"
    "Copy-Item (Join-Path (Split-Path $Plugins -Parent) 'ue4ss\\UE4SS.log') $tmp -ErrorAction SilentlyContinue\n"
    "$saved = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodeVein\\Saved'\n"
    "Copy-Item (Join-Path $saved 'Logs\\CodeVein.log') $tmp -ErrorAction SilentlyContinue\n"
    "$crash = Get-ChildItem (Join-Path $saved 'Crashes') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1\n"
    "if ($crash) { Copy-Item $crash.FullName (Join-Path $tmp 'crash') -Recurse -ErrorAction SilentlyContinue }\n"
    "$journal = Join-Path (Split-Path $Plugins -Parent) 'ue4ss\\Mods\\CoopProgress\\journal.txt'\n"
    "Copy-Item $journal $tmp -ErrorAction SilentlyContinue\n"
    "$zip = Join-Path $root ('CoopLogs-' + $stamp + '.zip')\n"
    "Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force\n"
    "Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue\n"
    "Get-ChildItem (Join-Path $root 'CoopLogs-*.zip') | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue\n"
    "if ($Share -and (Test-Path $zip)) { Copy-Item $zip $Share -ErrorAction SilentlyContinue }\n"
    "# auto update (2026-11-03): a newer guest kit on the host's share (kits\\latest.txt) is unpacked into this game folder now that the game is closed\n"
    "if ($Share) {\n"
    "  try {\n"
    "    $kits = Join-Path $Share 'kits'\n"
    "    $latest = (Get-Content (Join-Path $kits 'latest.txt') -ErrorAction Stop | Select-Object -First 1).Trim()\n"
    "    $cur = ''\n"
    "    $vf = Join-Path $Plugins 'CoopKitVersion.txt'\n"
    "    if (Test-Path $vf) { $cur = (Get-Content $vf | Select-Object -First 1).Trim() }\n"
    "    if ($latest -and $latest -ne $cur -and (Test-Path (Join-Path $kits $latest))) {\n"
    "      Expand-Archive -Path (Join-Path $kits $latest) -DestinationPath (Split-Path $Plugins -Parent) -Force\n"
    "      Write-Output ('auto update: ' + $cur + ' -> ' + $latest)\n"
    "    } else { Write-Output ('auto update: up to date (' + $cur + ')') }\n"
    "  } catch { Write-Output ('auto update failed: ' + $_) }\n"
    "}\n";
static void start_exit_package(void) {
    char root[MAX_PATH], ps1[MAX_PATH], share[600] = "", ini[2048], sysdir[MAX_PATH] = "C:\\Windows\\System32", cmd[2048], plugins[MAX_PATH];
    snprintf(root, sizeof root, "%sCoopLogs", g_dir); CreateDirectoryA(root, NULL);
    snprintf(ps1, sizeof ps1, "%s\\collect.ps1", root);
    FILE *f = _fsopen(ps1, "w", _SH_DENYNO);
    if (!f) { logf_("log package: could not write collect.ps1"); return; }
    fputs(g_exit_ps, f); fclose(f);
    if (read_small_file("CoopNative.ini", ini, sizeof ini)) {
        const char *q = strstr(ini, "log_share=");
        if (q) {
            q += 10;
            size_t k = 0;
            while (q[k] && q[k] != '\r' && q[k] != '\n' && k < sizeof share - 1) { share[k] = q[k]; k++; }
            share[k] = 0;
        }
    }
    snprintf(plugins, sizeof plugins, "%s", g_dir);
    size_t pl = strlen(plugins);
    if (pl && plugins[pl - 1] == '\\') plugins[pl - 1] = 0;
    GetSystemDirectoryA(sysdir, sizeof sysdir);
    snprintf(cmd, sizeof cmd, "\"%s\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" -GamePid %lu -Plugins \"%s\" -Share \"%s\"",
             sysdir, ps1, GetCurrentProcessId(), plugins, share);
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si); si.cb = sizeof si; si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        logf_("log package: waiting for the game to end (zip to CoopLogs%s%s)", share[0] ? ", copy to " : "", share[0] ? share : "");
    } else logf_("log package: could not start the watcher (%lu)", GetLastError());
}
static DWORD WINAPI worker(LPVOID unused) {
    (void)unused;
    Sleep(2000);   // let the engine finish its own startup first
    MH_STATUS s = MH_Initialize();
    logf_("MH_Initialize -> %s", MH_StatusToString(s));
    if (s != MH_OK) return 0;
    g_hook_batch = 1;
    install("GetRescueSignalState", ADDR_EXEC_GET_RESCUE_SIGNAL_STATE,
            "\xE9\x1B\x56\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_get_state, (void **)&g_orig_get_state);
    {
        char ini[4096];
        if (read_small_file("CoopNative.ini", ini, sizeof ini) && strstr(ini, "guest_seats=1")) {
            g_seats_on = 1;
            install("SeatButtonBase", ADDR_BTN_BASE, "\xE9\xDB\xEA\x3E\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_btn_base, (void **)&g_orig_btn_base);
            install("SeatButtonItem", ADDR_BTN_ITEM, "\xE9\x2B\xF1\x3E\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_btn_item, (void **)&g_orig_btn_item);
            install("SeatPossess", ADDR_EXEC_POSSESS, "\xE9\x4B\x49\x1C\x0E\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exec_possess, (void **)&g_orig_exec_possess);
            install("SeatAcknowledge", ADDR_EXEC_ACK_POSSESSION, "\xE9\xDB\xA7\xED\x0E\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exec_ack, (void **)&g_orig_exec_ack);
            install("SeatStand", ADDR_EXEC_ANIM_CLASS, "\xE9\x9B\xED\x08\x0F\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exec_animclass, (void **)&g_orig_exec_animclass);
            install("SeatHead", ADDR_EXEC_CAM_ROT, "\xE9\x9B\x19\xED\x0E\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exec_camrot, (void **)&g_orig_exec_camrot);
            install("SeatGetAllActors", ADDR_GET_ALL_ACTORS, "\xE9\xAB\x44\xE3\x0C\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_get_all, (void **)&g_orig_get_all);
            install("PianoNotes", ADDR_AK_POST_IMPL, "\xE9\xBB\xAA\x24\x12\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_akpost, (void **)&g_orig_akpost);
            InitializeCriticalSection(&g_pn_cs); InterlockedExchange(&g_pn_cs_ok, 1);
            CreateThread(NULL, 0, pn_thread, NULL, 0, NULL);
        }
        if (read_small_file("CoopNative.ini", ini, sizeof ini) && strstr(ini, "rec=1")) {
            g_rec = 1;
            install("RecSetVis", 0x140913E80ULL, "\xE9\x4B\x34\x77\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_setvis, (void **)&g_orig_setvis);
            install("RecHide", 0x140913E90ULL, "\xE9\xFB\x36\x77\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_hide, (void **)&g_orig_hide);
            install("RecOnRep", 0x140B4AE00ULL, "\xE9\x4B\xE5\x28\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_onrep, (void **)&g_orig_onrep);
            install("RecNpcStart", 0x1408E54F0ULL, "\x48\x89\x5C\x24\x08\x57\x48\x83\xEC\x20\x48\x8B\xD9\xE8\xBE\xDD", (void *)detour_npc_start, (void **)&g_orig_npc_start);
            install("RecUnique", 0x14090C6A0ULL, "\xE9\x4B\x9B\x76\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_unique, (void **)&g_orig_unique);
            install("RecExclude", 0x1408F2DA0ULL, "\xE9\x3B\x20\x74\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exclude, (void **)&g_orig_exclude);
            install("RecRelC", 0x140448000ULL, "\xE9\xBB\xB5\x93\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_relc, (void **)&g_orig_relc);
            install("RecRelB", 0x140447ED0ULL, "\xE9\x0B\xB3\x93\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_relb, (void **)&g_orig_relb);
            install("RecSetFlag", 0x140913590ULL, "\xE9\xFB\x2A\x77\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_setflag, (void **)&g_orig_setflag);
            CreateThread(NULL, 0, rec_thread, NULL, 0, NULL);
            rec_window(60, "game start");
        }
    }
    install("LayoutChoice", ADDR_LAYOUT_CHOICE,
            "\xE9\xAB\x98\x76\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_layout_choice, (void **)&g_orig_layout_choice);
    install("IsOnlineMultiplayExec", ADDR_EXEC_ONLINE_MULTIPLAY,
            "\xE9\x9B\xB1\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_exec_multiplay, (void **)&g_orig_exec_multiplay);
    install("IsOnlineMultiplay", ADDR_IS_ONLINE_MULTIPLAY_BODY,
            "\x40\x53\x48\x83\xEC\x20\x48\x89\xCB\xE8\x12\x79\x9A\xF9\x85\xC0", (void *)detour_multiplay, (void **)&g_orig_multiplay);
    install("MultiPlayersCheck", ADDR_MULTI_PLAYERS_BODY,
            "\x40\x53\x48\x83\xEC\x20\xE8\x25\x88\x9A\xF9\x48\x89\xC3\x48\x85", (void *)detour_multi_players, (void **)&g_orig_multi_players);
    install("PromptBlock1", ADDR_PROMPT_BLOCK1_BODY,
            "\x40\x53\x48\x83\xEC\x20\x48\x89\xCB\xE8\xA2\xD5\x9A\xF9\x84\xC0", (void *)detour_prompt_block1, (void **)&g_orig_prompt_block1);
    install("EndCooperativeMode", ADDR_END_COOP_BODY,
            "\x40\x53\x48\x83\xEC\x20\x48\x89\xCB\xE8\x82\x03\x99\xF9\x48\x85", (void *)detour_end_coop, (void **)&g_orig_end_coop);
    {
        char ini[2048];
        if (read_small_file("CoopNative.ini", ini, sizeof ini) && strstr(ini, "trace_death=1"))
            for (int i = 0; i < TRACE_N; i++)
                install(g_trace_name[i], g_trace_addr[i], g_trace_expect[i], g_trace_det[i], (void **)&g_trace_orig[i]);
    }
    {
        // Session 9: with these traced, entering a boss area hung both PCs in the intro (WaitForPreparePolyFinished); the cutscene
        // and deferred-teleport ones are installed only with scenario_trace=1 now
        char ini[2048];
        int scen = read_small_file("CoopNative.ini", ini, sizeof ini) && strstr(ini, "scenario_trace=1");
        for (int i = 0; i < GIFT_N; i++) {
            const char *n = g_gift_name[i];
            // the two memory-residue calls stay traced (not used by the boss intro; the post-boss memory is what hangs)
            int memory = strstr(n, "MemoryResidue") != NULL;
            // session 10: single cutscene waits can be traced by name (scenario_trace_names=A,B in the ini) to find the outro wait
            const char *fn = strchr(n, ':');
            if (fn && strstr(ini, "scenario_trace_names=") && strstr(strstr(ini, "scenario_trace_names="), fn + 1)) memory = 1;
            if (!scen && !memory && (strncmp(n, "Scenario", 8) == 0 || strstr(n, "DeferredTeleport"))) { logf_("%s: not traced (scenario_trace=0)", n); continue; }
            install(n, g_gift_addr[i], g_gift_expect[i], g_gift_det[i], (void **)&g_gift_orig[i]);
        }
    }
    // Cleanup (2026-10-30, item 4): the pure log hooks (fade trace, GetPlayerController and the
    // IsPlayerPlayable logger) are installed only with diag_hooks=1; hooks that also fix something stay on (the late scenario hooks
    // find the museum actor and the memory end, the loading check holds v3)
    {
        char ini[2048];
        g_diag_hooks = read_small_file("CoopNative.ini", ini, sizeof ini) && strstr(ini, "diag_hooks=1");
        logf_("diag_hooks = %d", g_diag_hooks);
    }
    if (g_diag_hooks || g_seats_on) for (int i = 0; i < FADE_N; i++) if (g_diag_hooks || i == 1) install(g_fade_name[i], g_fade_addr[i], g_fade_expect[i], g_fade_det[i], (void **)&g_fade_orig[i]);
    for (int i = 0; i < SYNC_N; i++) install(g_sync_name[i], g_sync_addr[i], g_sync_expect[i], g_sync_det[i], (void **)&g_sync_orig[i]);
    install("InCharge", ADDR_IN_CHARGE,
            "\xE9\xDB\xEE\x94\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_in_charge, (void **)&g_orig_in_charge);
    install("LevelCheck", ADDR_LEVEL_CHECK,
            "\xE9\x0B\x6B\xD6\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_level_check, (void **)&g_orig_level_check);
    install("RequestEventImpl", ADDR_REQUEST_EVENT_IMPL,
            "\xE9\x1B\xA6\x76\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_request_event, (void **)&g_orig_request_event);
    install("RequestSkipEventImpl", ADDR_SKIP_EVENT_IMPL,
            "\xE9\xEB\x2C\x9A\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_skip_event, (void **)&g_orig_skip_event);
    for (int i = 0; i < BRANCH_N; i++) install(g_branch_name[i], g_branch_addr[i], g_branch_expect[i], g_branch_det[i], (void **)&g_branch_orig[i]);
    install("CheckGameProgressImpl", ADDR_CHECK_PROGRESS_IMPL,
            "\xE9\x0B\x1F\x55\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_check_progress, (void **)&g_orig_check_progress);
    install("GameEngineTick", ADDR_GAME_ENGINE_TICK,
            "\x48\x89\xE0\x44\x88\x40\x18\x55\x53\x57\x41\x54\x41\x56\x48\x8D", (void *)detour_engine_tick, (void **)&g_orig_engine_tick);
    install("AppearLockAcquire", 0x1404448B0ULL,
            "\xE9\x3B\x5C\x93\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_lock_acquire, (void **)&g_orig_lock_acquire);
    install("AppearLockRelease", 0x140448D40ULL,
            "\xE9\x1B\xCF\x93\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_lock_release, (void **)&g_orig_lock_release);
    install("PlayMemoryResidueImpl", 0x14090B120ULL,
            "\xE9\xAB\x7B\x76\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_play_memory, (void **)&g_orig_play_memory);
    install("AssertFatal", 0x140C3EEC0ULL,
            "\xE9\x5B\xAE\x8B\x08\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_assert_fatal, (void **)&g_orig_assert_fatal);
    install("AppearFinish", 0x1405B07B0ULL,
            "\xE9\x1B\x39\xD9\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_appear_finish, (void **)&g_orig_appear_finish);
    install("LoadingInProgressCheck", 0x1407ACD30ULL,
            "\xE9\xDB\xA0\x56\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_busy, (void **)&g_orig_busy);
    if (g_diag_hooks) install("GetPlayerController", ADDR_GET_PLAYER_CONTROLLER,
            "\xE9\x2B\xCE\xE3\x0C\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_get_player_controller, (void **)&g_orig_get_player_controller);
    install("GetPlayerCharacter", ADDR_GET_PLAYER_CHAR,
            "\xE9\x8B\xD1\xE3\x0C\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_get_player_char, (void **)&g_orig_get_player_char);
    install("LevelUp", ADDR_LEVEL_UP,
            "\xE9\xBB\xF0\x90\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_level_up, (void **)&g_orig_level_up);
    install("GetOnlineOtherPlayerNum", ADDR_EXEC_OTHER_PLAYER_NUM,
            "\xE9\xCB\x52\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_other_player_num, (void **)&g_orig_other_player_num);
    install("IsCreateSession", ADDR_EXEC_IS_CREATE_SESSION,
            "\xE9\xFB\x70\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_is_create_session, (void **)&g_orig_is_create_session);
    install("SpawnToCheckPointImpl", ADDR_SPAWN_TO_CHECKPOINT_IMPL,
            "\xE9\xAB\x73\x91\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_spawn_impl, (void **)&g_orig_spawn_impl);
    install("AreaNotify", ADDR_AREA_NOTIFY,
            "\xE9\x0B\xF3\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_area_notify, (void **)&g_orig_area_notify);
    install("ShowSessionMessage", ADDR_SHOW_SESSION_MESSAGE,
            "\xE9\xAB\xA9\x66\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_show_msg, (void **)&g_orig_show_msg);
    install("RequestPlayerSpawnToCheckPoint", ADDR_EXEC_SPAWN_TO_CHECKPOINT,
            "\xE9\x1B\xAA\x3A\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_spawn_to_checkpoint, (void **)&g_orig_spawn_to_checkpoint);
    install("MulticastExecuteFlowDiagramWithCallback", ADDR_EXEC_FLOW_DIAGRAM,
            "\xE9\x9B\x61\x14\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_flow_diagram, (void **)&g_orig_flow_diagram);
    install("MulticastFinishBossBattle", ADDR_EXEC_FINISH_BOSS,
            "\xE9\xDB\x63\x14\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_finish_boss, (void **)&g_orig_finish_boss);
    install("Server_AddExp", ADDR_EXEC_SERVER_ADDEXP,
            "\xE9\x1B\xE1\xA0\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_server_addexp, (void **)&g_orig_server_addexp);
    install("MistleInput", ADDR_MISTLE_INPUT,
            "\xE9\x5B\x16\x36\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_mistle_input, (void **)&g_orig_mistle_input);
    install("CloseOnlineSession", ADDR_CLOSE_SESSION,
            "\xE9\x2B\x4D\x64\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_close_session, (void **)&g_orig_close_session);
    install("IsNeverRevive", ADDR_NEVER_REVIVE,
            "\xE9\x9B\x40\xC4\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_never_revive, (void **)&g_orig_never_revive);
    install("ExecuteDisappearExpression", ADDR_EXEC_DISAPPEAR,
            "\xE9\xBB\x1E\xB6\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_disappear, (void **)&g_orig_disappear);
    install("DeathProcess", ADDR_DEATH_PROCESS,
            "\xE9\x2B\x4B\xD2\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_death_process, (void **)&g_orig_death_process);
    install("TryExecuteDeath", ADDR_TRY_EXECUTE_DEATH,
            "\xE9\x9B\x59\xC7\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_try_death, (void **)&g_orig_try_death);
    install("SwitchToEndCoop", ADDR_SWITCH_END_COOP,
            "\xC6\x81\xB8\x0A\x00\x00\x01\x48\x63\x81\x90\x0D\x00\x00\x83\xF8", (void *)detour_switch_end_coop, (void **)&g_orig_switch_end_coop);
    // the Denuvo-moved .code region may become executable only after startup: retry every 2 s for 2 minutes
    int handler_ok = 0, tries = 0;
    LONG shown = -2;
    int dumps = 0;
    ULONGLONG last_hb = 0;
    {
        MH_STATUS es = MH_EnableHook(MH_ALL_HOOKS);
        g_hook_batch = 0;
        logf_("startup hooks enabled together -> %s", MH_StatusToString(es));
    }
    if (g_cl_result[0]) logf_("log collection: %s", g_cl_result);
    start_exit_package();
    for (unsigned tick = 0;; tick++) {
        clamp_lock_counters();
        Sleep(200);
        read_settings();
        run_commands();
        if (g_seats_on) head_read();
        if (g_fade_hold && GetTickCount64() - g_fade_hold_at > 60000) { g_fade_release_ctx = 0; InterlockedExchange(&g_fade_release_pending, 1); g_fade_hold_at = GetTickCount64(); }
        guest_memory_watch();
        {
            static int gm_open;
            if (!g_host_pc && g_memory_start_at && GetTickCount64() - g_memory_start_at < 900000) gm_open = 1;
            else if (gm_open) { gm_open = 0; write_guestmem(0); logf_("memory: guest memory window closed"); }
        }
        // memory end on the host (polish 2b): the museum actor is freed at the end; its vtable changes -> group teleport back
        {
            static uintptr_t mus_seen, mus_vt;
            uintptr_t m = g_museum_actor;
            if (m && m != mus_seen && readable(m, 8)) { mus_seen = m; mus_vt = *(uintptr_t *)m; }
            if (m && m == mus_seen && g_memory_at && (!readable(m, 8) || *(uintptr_t *)m != mus_vt)) {
                g_memory_at = 0; g_museum_actor = 0;
                if (g_keep_outro && g_group_teleport) {
                    logf_("memory end (museum actor gone): v5 off; guest follows the host back like a group teleport");
                    relay_append("memend");
                    write_teleport_marker("start memend");
                    InterlockedExchange(&g_tp_pending, 1);
                }
            }
        }
        // v5 (session 10, proven live 12:45:13 with tools/memwrite): during the memory the host's memory character sits unstarted
        // (PrimaryActorTick +0x28: registered +0x35 = 0) holding its +0xB83 appear lock, and the lock counter never reaches 0 (one more
        // +0xB83/+0xB84 holder left over). Clearing that character's +0xB83, the counters [0x14413C404] / [0x14413C40C] and setting
        // [0x14413C410] to the current frame made it start at once (tick registered, appear finished, Unfade 101, IsPlayerPlayable 1).
        // Automatic: 3 min after PlayMemoryResidue (keep_outro), if the host controller's pawn (+0x388) is still unstarted after 2 s
        // and no +0xB85 holder exists, do the same (at most every 2 s, logged).
        {
            static ULONGLONG v5_last;
            ULONGLONG now5 = GetTickCount64();
            uintptr_t hpc = g_host_pc, hp = 0;
            if (g_keep_outro && g_memory_at && now5 - g_memory_at > 2000 && now5 - g_memory_at < 180000 && now5 - v5_last > 2000 && hpc &&
                readable(hpc + 0x388, 8) && (hp = *(uintptr_t *)(hpc + 0x388)) && readable(hp + 0x28, 0x10) && readable(hp + 0xB80, 8) &&
                *(volatile uint8_t *)(hp + 0x35) == 0 && *(volatile int *)0x14413C408ULL <= 0 && *(volatile int *)0x14413C404ULL <= 3) {
                v5_last = now5;
                logf_("appear lock v5: host memory character 0x%llX unstarted (b83 %u, count %d, +0xB84 holders %d) -> lock reset",
                      (unsigned long long)hp, *(volatile uint8_t *)(hp + 0xB83), *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C40CULL);
                *(volatile uint8_t *)(hp + 0xB83) = 0;
                *(volatile int *)0x14413C404ULL = 0; clear_player_lock_flags();
                *(volatile int *)0x14413C40CULL = 0;
                *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
            }
        }
        // v6 (2026-11-06): the same stuck lock on arriving at Home Base with a guest: [404]=23, [40C]=22, [410]=-1 (for good), no appear finish
        // on the host's new character, a loading screen for ever (it worked once, by luck). Same reset, from 12 s after the teleport
        // (arrival takes about 11 s; the levels load under the lock) while the block stays "for good"; inside the 60 s teleport window.
        {
            static ULONGLONG v6_last; static int v6_n; static ULONGLONG v6_for;
            ULONGLONG now6 = GetTickCount64();
            ULONGLONG hb = g_hb_at;
            if (v6_for != hb) { v6_for = hb; v6_n = 0; }
            if (hb && now6 - hb > 12000 && now6 - hb < 75000 && now6 - v6_last > 2000 && v6_n < 8 &&
                *(volatile uint64_t *)0x14413C410ULL == ~0ULL && *(volatile int *)0x14413C404ULL > 0) {
                v6_last = now6; v6_n++;
                logf_("appear lock v6: stuck after the Home Base teleport (count %d, +0xB85 holders %d, +0xB84 holders %d, %d so far) -> lock reset",
                      *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C408ULL, *(volatile int *)0x14413C40CULL, v6_n);
                int held = clear_holder_flags();
                logf_("appear lock v6: %d characters freed", held);
                *(volatile int *)0x14413C404ULL = 0; clear_player_lock_flags();
                *(volatile int *)0x14413C408ULL = 0;
                *(volatile int *)0x14413C40CULL = 0;
                *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
            } else if (hb && v6_n > 0 && now6 - hb < 75000 && now6 - v6_last > 2000) {
                // characters that came in after the reset would hang the same way
                v6_last = now6;
                int held = clear_holder_flags();
                if (held) {
                    logf_("appear lock v6: %d more characters freed", held);
                    *(volatile int *)0x14413C404ULL = 0;
                    *(volatile int *)0x14413C408ULL = 0;
                    *(volatile int *)0x14413C40CULL = 0;
                    *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
                }
            }
        }
        // v5g (2026-10-31): the guest floated without control in the host's memory. Most likely his memory character hit the same
        // counter as ours (v5 above only resets the host's): tick not registered (+0x35 = 0), appear unfinished. During the memory
        // window, log his character's flags (gpawn from tpinfo) every 3 s and, if it stays unstarted 2 s after it appeared, do the
        // same reset on it (at most 3 times per memory).
        {
            static ULONGLONG g5_log, g5_seen_at, g5_mem;
            static uintptr_t g5_pawn;
            static int g5_count;
            ULONGLONG nowg = GetTickCount64();
            if (g5_mem != g_memory_at) { g5_mem = g_memory_at; g5_count = 0; g5_pawn = 0; }
            if (g_keep_outro && g_memory_at && nowg - g_memory_at < 900000) {
                char tb[600]; uintptr_t gp = 0;
                if (read_small_file("CoopNative.tpinfo", tb, sizeof tb)) {
                    char *q = strstr(tb, "gpawn ");
                    if (q) gp = (uintptr_t)strtoull(q + 6, NULL, 16);
                }
                if (gp != g5_pawn) { g5_pawn = gp; g5_seen_at = nowg; }
                if (gp && readable(gp + 0x28, 0x10) && readable(gp + 0xB80, 8)) {
                    uint8_t t35 = *(volatile uint8_t *)(gp + 0x35), t37 = *(volatile uint8_t *)(gp + 0x37), b83 = *(volatile uint8_t *)(gp + 0xB83);
                    if (nowg - g5_log > 3000) {
                        g5_log = nowg;
                        logf_("memory: guest character 0x%llX tick +0x35 %u +0x37 %u b83 %u (count %d, frame-block %s)", (unsigned long long)gp,
                              t35, t37, b83, *(volatile int *)0x14413C404ULL, *(volatile uint64_t *)0x14413C410ULL == ~0ULL ? "forever" : "no");
                    }
                    // (2026-10-31 08:20 test: his character on the host was started (+0x35 = 1) throughout; the reset fired once on a
                    //  momentary read during his character swap and pushed the counter to -1 -> logging only now)
                    if (0 && t35 == 0 && nowg - g5_seen_at > 2000 && g5_count < 3 && *(volatile int *)0x14413C408ULL <= 0) {
                        g5_count++; g5_seen_at = nowg;
                        logf_("appear lock v5g: guest memory character 0x%llX unstarted (b83 %u, count %d) -> lock reset (%d)", (unsigned long long)gp,
                              b83, *(volatile int *)0x14413C404ULL, g5_count);
                        *(volatile uint8_t *)(gp + 0xB83) = 0;
                        *(volatile int *)0x14413C404ULL = 0; clear_player_lock_flags();
                        *(volatile int *)0x14413C40CULL = 0;
                        *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
                    }
                }
            }
        }
        // v5 on the guest (2026-10-31 08:5x guest log: his memory character had tick=false, moveMode=0 on HIS PC the whole memory,
        // input not ignored; on the host it ran): his game holds his own memory character before AppBeginPlay, the same counter as
        // the host's. While the memory window is open (CoopNative.guestmem = 1, written by CoopProbe on the host's CoopMemoryStart),
        // check his own pawn (CoopNative.mypawn) every 200 ms: unstarted (+0x35 = 0) for 2 s -> the v5 reset (at most 3 per window).
        if (!g_host_pc) {
            static ULONGLONG gv5_log, gv5_since;
            static uintptr_t gv5_pawn;
            static int gv5_count, gv5_open;
            char gm[8] = "";
            int open = read_small_file("CoopNative.guestmem", gm, sizeof gm) && gm[0] == '1';
            if (open && !gv5_open) { gv5_count = 0; logf_("memory (guest): window open, watching our own memory character"); }
            gv5_open = open;
            uintptr_t mp = open ? read_my_pawn() : 0;
            ULONGLONG nowv = GetTickCount64();
            if (mp != gv5_pawn) { gv5_pawn = mp; gv5_since = nowv; }
            // the other player characters on this PC (the host's memory character floated here until the first skip, 2026-11-02):
            // same check, from CoopNative.pawns (all BP_Player_C, written by CoopProbe every 2 s); one reset per character
            if (open) {
                static uintptr_t other_reset[16];
                static ULONGLONG other_since[16];
                static uintptr_t other_addr[16];
                char pb[400];
                if (read_small_file("CoopNative.pawns", pb, sizeof pb)) {
                    char *q = pb;
                    while (*q) {
                        char *end; unsigned long long v = strtoull(q, &end, 16);
                        if (end == q) break;
                        q = end; while (*q == ' ') q++;
                        uintptr_t op = (uintptr_t)v;
                        if (!op || op == mp || !readable(op + 0x28, 0x10) || !readable(op + 0xB80, 8)) continue;
                        int slot = -1, free_slot = -1;
                        for (int k = 0; k < 16; k++) { if (other_addr[k] == op) slot = k; if (!other_addr[k] && free_slot < 0) free_slot = k; }
                        if (slot < 0) { if (free_slot < 0) continue; slot = free_slot; other_addr[slot] = op; other_since[slot] = nowv; other_reset[slot] = 0; }
                        // 2026-11-02: the host's character floated on this PC at the memory start; log every other character too
                        if (nowv - gv5_log < 250)
                            logf_("memory (guest): other character 0x%llX tick +0x35 %u +0x37 %u b83 %u appear-pending %u pc-bits 0x%02X",
                                  (unsigned long long)op, *(volatile uint8_t *)(op + 0x35), *(volatile uint8_t *)(op + 0x37),
                                  *(volatile uint8_t *)(op + 0xB83), readable(op + 0xC12, 1) ? *(volatile uint8_t *)(op + 0xC12) : 255,
                                  readable(op + 0x3C8, 1) ? *(volatile uint8_t *)(op + 0x3C8) : 255);
                        if (*(volatile uint8_t *)(op + 0x35) != 0) { other_since[slot] = nowv; continue; }
                        if (!other_reset[slot] && nowv - other_since[slot] > 2000 && *(volatile int *)0x14413C408ULL <= 0) {
                            other_reset[slot] = 1;
                            logf_("appear lock v5 (guest): other player character 0x%llX unstarted (b83 %u, count %d) -> lock reset",
                                  (unsigned long long)op, *(volatile uint8_t *)(op + 0xB83), *(volatile int *)0x14413C404ULL);
                            *(volatile uint8_t *)(op + 0xB83) = 0;
                            *(volatile int *)0x14413C404ULL = 0; clear_player_lock_flags();
                            *(volatile int *)0x14413C40CULL = 0;
                            *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
                        }
                    }
                }
                if (!open) for (int k = 0; k < 16; k++) other_addr[k] = 0;
            }
            if (mp && readable(mp + 0x28, 0x10) && readable(mp + 0xB80, 8)) {
                uint8_t t35 = *(volatile uint8_t *)(mp + 0x35), b83 = *(volatile uint8_t *)(mp + 0xB83);
                if (nowv - gv5_log > 3000) {
                    gv5_log = nowv;
                    logf_("memory (guest): our character 0x%llX tick +0x35 %u b83 %u (count %d, +0xB85 holders %d, frame-block %s)", (unsigned long long)mp,
                          t35, b83, *(volatile int *)0x14413C404ULL, *(volatile int *)0x14413C408ULL,
                          *(volatile uint64_t *)0x14413C410ULL == ~0ULL ? "forever" : "no");
                }
                if (t35 != 0) gv5_since = nowv;
                else if (nowv - gv5_since > 2000 && gv5_count < 3 && *(volatile int *)0x14413C408ULL <= 0) {
                    gv5_count++; gv5_since = nowv;
                    logf_("appear lock v5 (guest): our memory character 0x%llX unstarted (b83 %u, count %d) -> lock reset (%d)", (unsigned long long)mp,
                          b83, *(volatile int *)0x14413C404ULL, gv5_count);
                    *(volatile uint8_t *)(mp + 0xB83) = 0;
                    *(volatile int *)0x14413C404ULL = 0; clear_player_lock_flags();
                    *(volatile int *)0x14413C40CULL = 0;
                    *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
                }
            }
        }
        // v4 (session 10): from the memory start on (3 min, keep_outro), keep the appear lock from being "forever" while no +0xB85
        // holder exists: characters spawned for the host during the memory (the museum's, ours) missed their BeginPlay while it was
        // shut, and nothing retries it. Checked every 200 ms; a qword store is atomic.
        if (g_keep_outro && g_memory_at && GetTickCount64() - g_memory_at < 180000 &&
            *(volatile uint64_t *)0x14413C410ULL == ~0ULL && *(volatile int *)0x14413C408ULL <= 0) {
            *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
            static LONG v4_logs;
            if (++v4_logs <= 50) logf_("appear lock v4: 'forever' without a +0xB85 holder during the memory -> current frame (count %d)",
                                       *(volatile int *)0x14413C404ULL);
        }
        if (tick % 5) continue;   // the rest once per second
        tp_watch();
        // session 10: after any boss kill (solo too), for a solo baseline of the memory
        // (the late hooks also find the museum actor and the memory end: always installed; only the IsPlayerPlayable logger is diag)
        // item 10 (2026-10-30): a vestige restoration plays a memory without a boss kill: also install them at a memory start
        if ((g_bosskill_at || g_memory_at) && !g_late_installed && InterlockedExchange(&g_late_installed, 1) == 0) {
            logf_("late scenario trace: installing %d hooks (%s)", LATE_N, g_bosskill_at ? "after the boss kill" : "memory start");
            for (int i = 0; i < LATE_N; i++) install(g_late_name[i], g_late_addr[i], g_late_expect[i], g_late_det[i], (void **)&g_late_orig[i]);
            if (g_diag_hooks) install("MuseumUtilityActor:IsPlayerPlayable", ADDR_EXEC_PLAYER_PLAYABLE,
                    "\xE9\x1B\xA1\xCF\x07\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_playable, (void **)&g_orig_playable);
        }
        // museum field dump every 3 s for 3 minutes after it began (raw reads on the worker)
        if (g_museum_actor && GetTickCount64() - g_museum_at < 180000 && (tick / 5) % 3 == 0) {
            uintptr_t m = g_museum_actor;
            if (readable(m + 0x380, 0x90))
                logf_("museum 0x%llX: acceptSkip %u finished %u forced %u useEventSkip %u playerStart 0x%llX playerStartWeak %d flowDiagram 0x%llX",
                      (unsigned long long)m, *(uint8_t *)(m + 0x3D0), *(uint8_t *)(m + 0x3E8), *(uint8_t *)(m + 0x3EA), *(uint8_t *)(m + 0x400),
                      (unsigned long long)*(uintptr_t *)(m + 0x3D8), *(int *)(m + 0x3C0), (unsigned long long)*(uintptr_t *)(m + 0x408));
            else logf_("museum 0x%llX: unreadable", (unsigned long long)m);
        }

        {
            ULONGLONG hb = g_heartbeat, now = GetTickCount64();
            if (hb != last_hb) { last_hb = hb; dumps = 0; }
            ULONGLONG quiet = hb ? now - hb : 0;
            static const ULONGLONG at[3] = {8000, 20000, 40000};
            if (hb && dumps < 3 && quiet >= at[dumps]) { dumps++; dump_game_thread(quiet); }
        }
        if (!handler_ok && tries < 60 && (++tries % 2) == 1)
            handler_ok = install("SessionStateHandler", ADDR_SESSION_STATE_HANDLER,
                                 "\x40\x55\x53\x57\x41\x54\x41\x55\x41\x56\x48\x8D\x6C\x24\xD1\x48",
                                 (void *)detour_state_handler, (void **)&g_orig_state_handler) != 0;
        LONG n = InterlockedExchange(&g_calls, 0), st = g_last_state;
        if (st != shown) { logf_("GetRescueSignalState now %ld (%ld calls in the last second)", st, n); shown = st; }
        LONG ro = InterlockedExchange(&g_rest_overrides, 0);
        if (ro) logf_("rest_in_coop: answered IsOnlineMultiplay=false to the Mistle prompt %ld times in the last second", ro);
        LONG vo = InterlockedExchange(&g_vestige_overrides, 0);
        if (vo) logf_("vestige_menu: answered Idle to the Mistle menu %ld times in the last second", vo);
        LONG rr = InterlockedExchange(&g_reset_overrides, 0);
        if (rr) logf_("rest_in_coop: answered IsOnlineMultiplay=false to the enemy-reset callers %ld times in the last second", rr);
    }
}

// Automatic log collection (2026-10-31, owner; the Lies of P mod ships crash reporting). Everything stays on this PC:
// plugins\CoopLogs\current\ holds copies of UE4SS.log and the game's CodeVein.log, refreshed every 30 s while the game runs (the
// game and UE4SS overwrite their logs at the next start). At the next start, before CoopNative.log is reopened, the previous run
// is moved to CoopLogs\previous\ together with that CoopNative.log and any new crash report folder (Saved\Crashes), and zipped to
// CoopLogs\CoopLogs-<date>-<time>.zip (the newest 5 are kept). After a problem: start the game once, send the newest zip.
static void cl_path(char *out, size_t n, const char *rel) { snprintf(out, n, "%sCoopLogs\\%s", g_dir, rel); }
static void cl_copy_dir_files(const char *from, const char *to) {
    char pat[MAX_PATH]; snprintf(pat, sizeof pat, "%s\\*", from);
    WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        char a[MAX_PATH], b[MAX_PATH];
        snprintf(a, sizeof a, "%s\\%s", from, fd.cFileName); snprintf(b, sizeof b, "%s\\%s", to, fd.cFileName);
        CopyFileA(a, b, FALSE);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}
static void cl_clear_dir(const char *dir) {
    char pat[MAX_PATH]; snprintf(pat, sizeof pat, "%s\\*", dir);
    WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        char a[MAX_PATH]; snprintf(a, sizeof a, "%s\\%s", dir, fd.cFileName); DeleteFileA(a);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}
// the per-user local application data folder (known folder F1B32785-6FBA-4FCF-9D55-7B8E7F157091), where the game keeps Saved
static int cl_game_saved(char *out, size_t n, const char *rel) {
    static const GUID local_folder = {0xF1B32785, 0x6FBA, 0x4FCF, {0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91}};
    PWSTR w = NULL;
    if (SHGetKnownFolderPath(&local_folder, 0, NULL, &w) != S_OK || !w) { if (w) CoTaskMemFree(w); return 0; }
    char la[MAX_PATH];
    int k = WideCharToMultiByte(CP_ACP, 0, w, -1, la, sizeof la, NULL, NULL);
    CoTaskMemFree(w);
    if (k <= 0) return 0;
    snprintf(out, n, "%s\\CodeVein\\Saved\\%s", la, rel);
    return 1;
}
// worker, every 30 s
static void cl_snapshot(void) {
    char cur[MAX_PATH], a[MAX_PATH], b[MAX_PATH];
    cl_path(cur, sizeof cur, "current");
    CreateDirectoryA(cur, NULL);
    snprintf(a, sizeof a, "%s..\\ue4ss\\UE4SS.log", g_dir); snprintf(b, sizeof b, "%s\\UE4SS.log", cur); CopyFileA(a, b, FALSE);
    if (cl_game_saved(a, sizeof a, "Logs\\CodeVein.log")) { snprintf(b, sizeof b, "%s\\CodeVein.log", cur); CopyFileA(a, b, FALSE); }
}
// DllMain, before CoopNative.log is reopened (no logging possible yet; the result is logged by the worker)
static char g_cl_cmd[2048];   // the zip command, started by the worker (not under the loader lock in DllMain)
static void cl_start_zip(void) {
    if (!g_cl_cmd[0]) return;
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof si); si.cb = sizeof si; si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    if (CreateProcessA(NULL, g_cl_cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    else logf_("log collection: zip could not be started (%lu)", GetLastError());
    g_cl_cmd[0] = 0;
}
static void cl_collect_previous(void) {
    char root[MAX_PATH], cur[MAX_PATH], prev[MAX_PATH], a[MAX_PATH], b[MAX_PATH];
    snprintf(root, sizeof root, "%sCoopLogs", g_dir); CreateDirectoryA(root, NULL);
    cl_path(cur, sizeof cur, "current"); cl_path(prev, sizeof prev, "previous");
    snprintf(a, sizeof a, "%sCoopNative.log", g_dir);
    if (GetFileAttributesA(a) == INVALID_FILE_ATTRIBUTES) { snprintf(g_cl_result, sizeof g_cl_result, "no previous run"); return; }
    CreateDirectoryA(prev, NULL); cl_clear_dir(prev);
    { char pc[MAX_PATH]; snprintf(pc, sizeof pc, "%s\\crash", prev); cl_clear_dir(pc); RemoveDirectoryA(pc); }
    snprintf(b, sizeof b, "%s\\CoopNative.log", prev); CopyFileA(a, b, FALSE);
    cl_copy_dir_files(cur, prev);
    // newest crash report folder, if it is newer than the one collected last time
    char crashes[MAX_PATH], pat[MAX_PATH], last[MAX_PATH] = "", newest[MAX_PATH] = "";
    FILETIME best = {0, 0};
    if (cl_game_saved(crashes, sizeof crashes, "Crashes")) {
        snprintf(pat, sizeof pat, "%s\\*", crashes);
        WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pat, &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || fd.cFileName[0] == '.') continue;
                if (CompareFileTime(&fd.ftLastWriteTime, &best) > 0) { best = fd.ftLastWriteTime; snprintf(newest, sizeof newest, "%s", fd.cFileName); }
            } while (FindNextFileA(h, &fd));
            FindClose(h);
        }
        char lf[MAX_PATH]; cl_path(lf, sizeof lf, "last-crash.txt");
        FILE *f = _fsopen(lf, "r", _SH_DENYNO);
        if (f) { if (!fgets(last, sizeof last, f)) last[0] = 0; fclose(f); }
        if (newest[0] && strcmp(newest, last) != 0) {
            char from[MAX_PATH], to[MAX_PATH];
            snprintf(from, sizeof from, "%s\\%s", crashes, newest);
            snprintf(to, sizeof to, "%s\\crash", prev); CreateDirectoryA(to, NULL);
            cl_copy_dir_files(from, to);
            f = _fsopen(lf, "w", _SH_DENYNO); if (f) { fputs(newest, f); fclose(f); }
        } else newest[0] = 0;
    }
    SYSTEMTIME st; GetLocalTime(&st);
    char zip[MAX_PATH], *cmd = g_cl_cmd;
    snprintf(zip, sizeof zip, "%s\\CoopLogs-%04u%02u%02u-%02u%02u%02u.zip", root, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    // zip (and keep the newest 5) in a hidden PowerShell, so the game start does not wait for it
    // full path (2026-11-03: on the guest's PC "powershell.exe" alone gave error 2, file not found, from inside the game)
    char sysdir[MAX_PATH] = "C:\\Windows\\System32";
    GetSystemDirectoryA(sysdir, sizeof sysdir);
    snprintf(cmd, sizeof g_cl_cmd,
             "\"%s\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -WindowStyle Hidden -Command \"Compress-Archive -Path '%s\\*' -DestinationPath '%s' -Force; "
             "Get-ChildItem '%s\\CoopLogs-*.zip' | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Force\"",
             sysdir, prev, zip, root);
    snprintf(g_cl_result, sizeof g_cl_result, "previous run collected -> CoopLogs\\%s%s%s", strrchr(zip, '\\') + 1,
             newest[0] ? ", with crash report " : "", newest);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&g_log_lock);
        DWORD n = GetModuleFileNameA(inst, g_dir, MAX_PATH);
        while (n > 0 && g_dir[n - 1] != '\\') n--;
        g_dir[n] = 0;
        char path[MAX_PATH];
        snprintf(path, sizeof path, "%sCoopNative.log", g_dir);
        g_log = _fsopen(path, "w", _SH_DENYWR);
        logf_("CoopNative loaded (probes: GetRescueSignalState, SessionStateHandler; EndCooperativeMode veto and Mistle rest are off unless enabled)");
        {   // the kit number in every log (2026-11-04: nothing showed which kit the guest really ran)
            char kp[MAX_PATH + 32], kv[80] = "none";
            snprintf(kp, sizeof kp, "%sCoopKitVersion.txt", g_dir);
            FILE *kf = fopen(kp, "r");
            if (kf) { if (!fgets(kv, sizeof kv, kf)) strcpy(kv, "empty"); fclose(kf); }
            kv[strcspn(kv, "\r\n")] = 0;
            logf_("kit: %s", kv);
            snprintf(kp, sizeof kp, "%sCoopNative.ticked", g_dir);
            DeleteFileA(kp);   // a leftover from the last run must not release the mods early
        }
        HANDLE h = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (h) CloseHandle(h);
    }
    return TRUE;
}
