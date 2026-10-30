// CoopNative: native (C) hooks for the Code Vein co-op project, loaded by Ultimate ASI Loader (winmm.dll proxy).
// Probe stage: inline MinHook detours. GetRescueSignalState (exec thunk) logs state changes; the session state-machine
// handler logs every internal event with a backtrace and can veto event 0x1F (only when explicitly enabled, see below).
// A command file lets Lua ask for memory reads (vtable lookups) that UE4SS Lua cannot do itself.
// The exe has no ASLR (DYNAMIC_BASE off), so UFunction exec thunk addresses from the UE4SS object dump are fixed.
#include <windows.h>
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
static void detour_get_state(void *context, void *stack, void *result) {
    g_heartbeat = GetTickCount64(); g_game_tid = GetCurrentThreadId();
    if (g_replay_pending && context && context == g_vetoed_sm && InterlockedExchange(&g_replay_pending, 0)) {
        LONG kind = InterlockedExchange(&g_vetoed_kind, 0);
        g_vetoed_sm = NULL;
        logf_("replay: calling the vetoed %s for real", kind == 2 ? "EndCooperativeMode" : "SwitchToEndCoop");
        if (kind == 2) g_orig_end_coop(context); else g_orig_switch_end_coop(context);
    }
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
            else ((uiunfade_fn)ADDR_UI_REQUEST_UNFADE)((void *)c, (void *)c, 48, 0, 0.5f);
            logf_("tpfade: %s (context 0x%llX)", tf ? "teleport fade requested" : "unfade requested", (unsigned long long)c);
        } else if (tf >= 0) logf_("tpfade: no valid context");
    }
    if (g_levelup_pending && InterlockedExchange(&g_levelup_pending, 0)) run_levelup();
    if (g_syncall_pending && InterlockedExchange(&g_syncall_pending, 0)) run_syncall();
    if (g_lvlinfo_pending && InterlockedExchange(&g_lvlinfo_pending, 0)) run_lvlinfo();
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
static int g_skip_fields[16], g_skip_n;
static uint64_t detour_spawn_impl(void *self, int64_t field, int64_t point, void *d, void *e, void *f, void *g, void *h, void *i, void *j, void *k, void *l) {
    int skip = 0;
    int fid = (int)field, pid = (int)point;   // 32-bit ints in edx/r8d; the upper halves are not defined
    for (int i = 0; i < g_skip_n; i++) if (g_skip_fields[i] == fid) skip = 1;
    InterlockedExchange(&g_tp_skip, skip);
    logf_("teleport destination: FieldID %d, PointIndex %d%s", fid, pid, skip ? "  (teleport_skip_fields: vanilla behaviour)" : "");
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
    // option A (session 10): the outro keeps the game's own sync (outro_partner_override=0); from the memory start on (15 min:
    // memory, its scenes, the cutscene out of it) the checks are answered again, so neither game waits for the other's copy
    int memwin = g_memory_start_at && GetTickCount64() - g_memory_start_at < 900000;
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

// ---- small file channel next to the DLL: CoopNative.cmd (one-shot commands), .ini (settings), .flags (from Lua) ----
static char g_dir[MAX_PATH];

static int read_small_file(const char *name, char *buf, size_t size) {
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s%s", g_dir, name);
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
    if (!read_small_file("CoopNative.tpinfo", buf, sizeof buf)) return 0;
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

static void run_commands(void) {
    char buf[256];
    if (!read_small_file("CoopNative.cmd", buf, sizeof buf)) return;
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sCoopNative.cmd", g_dir);
    DeleteFileA(path);
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
    LONG gout = have_ini && strstr(buf, "guest_outro=1") != NULL;
    if (InterlockedExchange(&g_guest_outro, gout) != gout) logf_("setting guest_outro = %ld", gout);
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
    g_bosskill_at = GetTickCount64();
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
    // item 6b: the guest's rest asks the host for an enemy reset with Server_AddExp(-2601) (a value no real exp gain has); swallowed
    if (value == GUEST_REST_MAGIC) {
        g_guest_rest_req_at = GetTickCount64();
        logf_("guest rest request (Server_AddExp(%d) from component 0x%llX): enemy reset wanted", value, (unsigned long long)(uintptr_t)ctx);
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
static void gift_note(int i, void *c, void *st) {
    if (strstr(g_gift_name[i], "WaitForMemoryResidueFinished")) g_memory_actor = (uintptr_t)c;
    // session 10: the memory moves the host into its own area and waits for the guest, who never arrives (his game has no memory
    // ground, he falls). Treat the memory start like a host teleport: group teleport spawns the guest next to the host's memory
    // character once it is up (same "start"/"arrived" markers as a Mistle teleport).
    if (strstr(g_gift_name[i], "PlayMemoryResidue")) { g_memory_at = GetTickCount64(); g_memory_start_at = g_memory_at; }
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
static volatile uintptr_t g_museum_actor;
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
            write_teleport_marker("start");
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
#define FADE_DETOUR(i) static uint64_t fade_det_##i(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h) { \
    uintptr_t ret = (uintptr_t)__builtin_return_address(0); \
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

static DWORD WINAPI worker(LPVOID unused) {
    (void)unused;
    Sleep(2000);   // let the engine finish its own startup first
    MH_STATUS s = MH_Initialize();
    logf_("MH_Initialize -> %s", MH_StatusToString(s));
    if (s != MH_OK) return 0;
    g_hook_batch = 1;
    install("GetRescueSignalState", ADDR_EXEC_GET_RESCUE_SIGNAL_STATE,
            "\xE9\x1B\x56\xCB\x06\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_get_state, (void **)&g_orig_get_state);
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
    if (g_diag_hooks) for (int i = 0; i < FADE_N; i++) install(g_fade_name[i], g_fade_addr[i], g_fade_expect[i], g_fade_det[i], (void **)&g_fade_orig[i]);
    for (int i = 0; i < SYNC_N; i++) install(g_sync_name[i], g_sync_addr[i], g_sync_expect[i], g_sync_det[i], (void **)&g_sync_orig[i]);
    install("InCharge", ADDR_IN_CHARGE,
            "\xE9\xDB\xEE\x94\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_in_charge, (void **)&g_orig_in_charge);
    install("LevelCheck", ADDR_LEVEL_CHECK,
            "\xE9\x0B\x6B\xD6\x05\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC\xCC", (void *)detour_level_check, (void **)&g_orig_level_check);
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
    for (unsigned tick = 0;; tick++) {
        Sleep(200);
        read_settings();
        run_commands();
        guest_memory_watch();
        // memory end on the host (polish 2b): the museum actor is freed at the end; its vtable changes -> group teleport back
        {
            static uintptr_t mus_seen, mus_vt;
            uintptr_t m = g_museum_actor;
            if (m && m != mus_seen && readable(m, 8)) { mus_seen = m; mus_vt = *(uintptr_t *)m; }
            if (m && m == mus_seen && g_memory_at && (!readable(m, 8) || *(uintptr_t *)m != mus_vt)) {
                g_memory_at = 0; g_museum_actor = 0;
                if (g_keep_outro && g_group_teleport) {
                    logf_("memory end (museum actor gone): v5 off; guest follows the host back like a group teleport");
                    write_teleport_marker("start");
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
                *(volatile int *)0x14413C404ULL = 0;
                *(volatile int *)0x14413C40CULL = 0;
                *(volatile uint64_t *)0x14413C410ULL = *(volatile uint64_t *)0x144194140ULL;
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
        HANDLE h = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (h) CloseHandle(h);
    }
    return TRUE;
}
