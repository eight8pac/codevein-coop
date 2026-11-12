-- CoopProbe: fine-grained log of who ends a co-op session (host and guest run it).
-- Every 0.2 s it logs the session/connection/death state when it changes, with milliseconds, and it logs
-- the engine's leave/kick/travel calls. It writes a flag file for CoopNative and, only with spectate_cam=1, moves the camera.
local TAG = "[CoopProbe] "
local t0wall, t0clock = os.time(), os.clock()
local function stamp()
    local e = os.clock() - t0clock
    local s = t0wall + math.floor(e)
    return os.date("%H:%M:%S", s) .. string.format(".%03d", math.floor((e % 1) * 1000))
end
local function log(s) print(TAG .. stamp() .. " " .. tostring(s) .. "\n") end
local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) end
local function name(o) return try(function() return o:GetFName():ToString() end) or "?" end

local function stateLine()
    local sm = FindFirstOf("AppSessionManager")
    local gs = FindFirstOf("BP_AppGameState_C")
    if not (valid(sm) and valid(gs)) then return "no world" end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local players = {}
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) then
            local l = "ok"
            if try(function() return helper:IsDeath(p) end) or try(function() return helper:IsDying(p) end) then l = "dead"
            elseif try(function() return helper:IsDowned(p) end) then l = "downed" end
            players[#players + 1] = name(p) .. ":" .. l
        end
    end
    local conns = {}
    for _, c in ipairs(FindAllOf("NetConnection") or {}) do if valid(c) then conns[#conns + 1] = name(c) end end
    return string.format("role=%s multi=%s created=%s signal=%s boss=%s conns=[%s] players=[%s]",
        tostring(try(function() return gs.Role end)),
        tostring(try(function() return sm:IsOnlineMultiplay(gs) end)),
        tostring(try(function() return sm:IsCreateSession(gs) end)),
        tostring(try(function() return sm:GetRescueSignalState(gs) end)),
        tostring(try(function() return gs.BossAreaState end)),
        table.concat(conns, ","), table.concat(players, ","))
end

-- Spectate window for CoopNative's EndCooperativeMode veto: boss fight running, at least one player dead and one alive.
-- Same rule on host and guest (on the guest PC the dead one is the guest itself). Written to <Win64>\plugins\CoopNative.flags
-- ("1"/"0"); CoopNative only acts on it when its own ini enables the veto.
local WIN64 = debug.getinfo(1, "S").source:match("^@(.*)[/\\]ue4ss[/\\]Mods[/\\]") or "."
local FLAGS = WIN64 .. "\\plugins\\CoopNative.flags"
local INI = WIN64 .. "\\plugins\\CoopNative.ini"
local function iniHas(key)
    local f = io.open(INI, "r"); if not f then return false end
    local s = f:read("*a") or ""; f:close()
    return s:find(key, 1, true) ~= nil
end
function iniValue(key)
    local f = io.open(INI, "r"); if not f then return nil end
    local s = f:read("*a") or ""; f:close()
    return s:match(key .. "=([^\r\n]+)")
end
-- On the host every player has a PlayerController; ours is the local one.
local function localPC()
    for _, pc in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(pc) and try(function() return pc:IsLocalController() end) then return pc end
    end
    return nil
end
local lastWindow
-- A boss kill must close the window at once: the outro calls EndCooperativeMode ~2 s after MulticastGainRewards, and a veto
-- there stalls the host on a black screen (session 7). Closed for 60 s after the rewards.
local rewardsAt = -1000
bossReviveUntil, bossReviveDue, bossReviveDoneUntil = -1000, false, -1000
hbUntil, hbReady, hbGuestWait, hbTarget, hbHostHold, hbRelease = -1000, false, false, nil, false, nil   -- Home Base teleport with the session kept (hbWatch)
hbBrought, hbVolAt = false, -1000
tpUsage = nil   -- the host's fade choice for group teleports (CoopFadeMode): 64 = the join loading screen, 48 = the teleport fade
function tpUsageArg()
    local u = tpUsage or (iniHas("tp_loading=1") and 64 or nil)
    return u and (" " .. u) or ""
end
hbGuestFloor, hbBroughtAt = false, 0   -- kind 13 from the guest: his own floor check passed
hbLeave, hbLeaveIn, hbLeaveArrived, hbLeaveOk = false, false, false, nil                                 -- the same on the way out
pcall(function()
    RegisterHook("/Script/Extensions.BossAreaBase:MulticastGainRewards", function()
        rewardsAt = os.clock()
        local f = io.open(FLAGS, "w"); if f then f:write("0"); f:close() end
        lastWindow = false
        -- A player held by the veto never retries leaving, so the host's outro would wait for him forever: if our own
        -- character is dead, have CoopNative replay the vetoed end now (he goes home as in vanilla and rejoins later).
        local pc = localPC()
        local mine = valid(pc) and try(function() return pc.Pawn end) or nil
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local dead = not valid(mine) or try(function() return helper:IsDeath(mine) end)
        -- 2026-11-06 (owner): when the boss dies, everyone dead comes back in the room, so the normal end sequence can run (with the host
        -- dead it stood still, no "defeated" banner). No more going home; the host spawns everyone (bossKillRevive).
        bossReviveUntil = os.clock() + 8
        bossReviveDue = true
        log("boss rewards: spectate window forced closed" .. (dead and ", own character dead -> everyone dead comes back in the room" or ""))
    end)
end)
-- Group respawn (group_respawn=1): outside boss fights the window also opens when a guest has died for good while the host lives,
-- so his leave is vetoed anywhere; the host then brings him back (groupRespawn). The host's own death keeps the vanilla path.
local keepDyingOn = false
-- The character whose revive window ran out ("true death"): CoopNative writes it when its veto fires.
local function trueDeadAddr()
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.truedead", "r")
    if not f then return nil end
    local t = f:read("*a") or ""; f:close()
    local v = tonumber(t:match("%x+") or "", 16)
    return (v and v ~= 0) and v or nil, t:match("%x+%s+(%a)")
end
-- A marker left in the file from an earlier run made a join look like "pawn removed after a true death" and crashed the guest
-- (2026-10-28 10:30). Clear it at load, and accept "no pawn" only after we saw our own pawn truly die in this run.
do local f = io.open(WIN64 .. "\\plugins\\CoopNative.truedead", "w") if f then f:write("0"); f:close() end end
local sawOwnTrueDeath, lastWorldName = false, nil
local lastMineAddr, lastFallAt = nil, -1000
local TRUEDEAD_FILE = WIN64 .. "\\plugins\\CoopNative.truedead"
local function isTrueDead(helper, p)
    if try(function() return helper:IsDeath(p) end) then return true end
    if not keepDyingOn or not try(function() return helper:IsDying(p) end) then return false end
    local td = trueDeadAddr()
    return td ~= nil and td == try(function() return p:GetAddress() end)
end
-- Boss fights (owner 2026-11-06): nobody really dies while someone else lives. A real host death aborted the fight (no rewards, no banner,
-- a stalemate), so the final death is vetoed for everyone (CoopNative.protect) and the player stays dying and spectates. The veto's
-- marker (CoopNative.truedead) tells "down for good" from a normal dying player, whom Io or a partner can still revive.
local function isDownFinal(helper, p)
    if try(function() return helper:IsDeath(p) end) then return true end
    if not try(function() return helper:IsDying(p) end) then return false end
    local td = trueDeadAddr()
    return td ~= nil and td == try(function() return p:GetAddress() end)
end
local function fieldWindow(gs, helper)
    keepDyingOn = iniHas("keep_dying=1")
    if not iniHas("group_respawn=1") and not keepDyingOn then return false end
    local sm = FindFirstOf("AppSessionManager")
    if not (valid(sm) and try(function() return sm:IsOnlineMultiplay(gs) end)) then return false end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local mineName = valid(mine) and name(mine) or nil
    local isHost = try(function() return gs.Role end) == 3
    local deadOther, deadMine, aliveOther, aliveMine = false, false, false, false
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) then
            local d = isTrueDead(helper, p)
            local me = name(p) == mineName
            if d then if me then deadMine = true else deadOther = true end
            elseif me then aliveMine = true else aliveOther = true end
        end
    end
    -- 2026-11-06 (owner: host death must not end the session; outside a boss fight he just respawns as usual): the same veto for a
    -- dead host, on both PCs (each ends co-op on its own side). hostFieldDead keeps the host's camera out of spectating.
    local hostKeep = not iniHas("host_death_keep=0")
    if isHost then
        local was = hostFieldDead
        hostFieldDead = hostKeep and deadMine and aliveOther
        if hostFieldDead and not was then log("host death: dead in the field with a guest alive -> session kept, normal respawn") end
        return (deadOther and aliveMine) or hostFieldDead
    end
    -- On a guest PC: we died, the host lives. Only a real dead pawn counts: while joining there is no pawn yet, and vetoing then
    -- blocked the join (2026-10-28: guest stuck on a black screen after loading into the host's world). Exception: after a true
    -- death the host removes our pawn (keep_dying) and we keep spectating; our own true-death marker tells that apart from a join.
    -- a new world (left, kicked, travelled) ends any pending true death: forget it so the next join is not mistaken for one
    local world = name(gs)
    if world ~= lastWorldName then
        lastWorldName = world
        if sawOwnTrueDeath then
            sawOwnTrueDeath = false
            local f = io.open(TRUEDEAD_FILE, "w"); if f then f:write("0"); f:close() end
            log("keep dying: new world, pending true death forgotten")
        end
    end
    -- Fall deaths (session 9): the host decides them and removes our pawn at once, and our own game never vetoed a death, so
    -- there is no marker here. Our pawn vanishing in the same world within 10 s of falling fast counts as our true death (the host
    -- waits 1.5 s, then plays the dissolve for 2.5 s before removing the body).
    if keepDyingOn then
        if valid(mine) then
            local vz = try(function() return mine:GetVelocity().Z end)
            if type(vz) == "number" and vz < -1200 then lastFallAt = os.clock() end
            lastMineAddr = try(function() return mine:GetAddress() end)
        elseif lastMineAddr then
            if not sawOwnTrueDeath and os.clock() - lastFallAt < 10 and aliveOther then
                sawOwnTrueDeath = true
                local f = io.open(TRUEDEAD_FILE, "w"); if f then f:write(string.format("%X F", lastMineAddr)); f:close() end
                log("keep dying: our pawn was removed right after a fall -> true death, spectating")
            end
            lastMineAddr = nil
        end
    end
    if keepDyingOn and valid(mine) and deadMine then
        local td = trueDeadAddr()
        if td and td == try(function() return mine:GetAddress() end) then sawOwnTrueDeath = true end
    end
    if keepDyingOn and not valid(mine) and sawOwnTrueDeath and trueDeadAddr() then return aliveOther end
    if hostKeep and deadOther and aliveMine and not hostDeadSeen then hostDeadSeen = true; log("host death: the host is dead, we stay in the session") end
    if not deadOther then hostDeadSeen = false end
    return (deadMine and aliveOther) or (hostKeep and deadOther and aliveMine)
end
postBossUntil = -1000   -- set when the host's memory starts/ends (scene relay); no spectate window until then
local function spectateWindow()
    if os.clock() - rewardsAt < 60 then hostFieldDead = false; return false end
    -- 2026-11-02: after the memory his BossAreaState still said "fight running" (his story flags) and leftover memory characters
    -- counted as dead -> the spectate window opened: camera on the host, death filter and crisis music in the final cutscene
    if os.clock() < postBossUntil then return false end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) then return false end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if try(function() return gs.BossAreaState end) ~= 2 then return try(function() return fieldWindow(gs, helper) end) or false end
    hostFieldDead = false   -- in a boss fight a dead host spectates (R7)
    local dead, alive = false, false
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) then
            if isDownFinal(helper, p) then dead = true else alive = true end
        end
    end
    return dead and alive
end
local function writeWindow(w)
    if w == lastWindow then return end
    lastWindow = w
    local f = io.open(FLAGS, "w")
    if f then f:write(w and "1" or "0"); f:close() end
    log("spectate window " .. (w and "OPEN" or "closed") .. (f and "" or " (could not write " .. FLAGS .. ")"))
end

-- Spectate camera (session 7 experiment, only with spectate_cam=1 in plugins\CoopNative.ini). With the veto holding, the dead
-- player's own death sequence stops at its fade/loading screen (BP_FadeUIComponent) while still connected. In the spectate window,
-- if our own character is dead: lift the fade and point our camera at a living player. The view target is local to each PC.
local function spectateCamEnabled()
    local f = io.open(INI, "r"); if not f then return false end
    local s = f:read("*a") or ""; f:close()
    return s:find("spectate_cam=1", 1, true) ~= nil
end
local camTarget, census, spectateStart, keepHiddenWorld = nil, 0, nil, nil
-- Each step runs on its own and logs its first error (session 7: one silent error stopped the camera switch).
local errs = {}
local function step(what, f)
    local ok, e = pcall(f)
    if not ok and not errs[what] then errs[what] = true; log("spectate: " .. what .. " ERROR " .. tostring(e):sub(1, 160)) end
end
-- The unfade calls fail from Lua, so hide the death overlays themselves while spectating and restore them afterwards.
local OVERLAYS = { "WDT_FadeScreen_C", "WDT_EffectFadeScreen_C", "WDT_DeathParts_C" }
local hidden = {}   -- widget name -> {widget, original visibility}
local function hideOverlays()
    for _, cls in ipairs(OVERLAYS) do
        for _, w in ipairs(FindAllOf(cls) or {}) do
            if valid(w) then
                local n = name(w)
                if not hidden[n] then
                    hidden[n] = { w, try(function() return w:GetVisibility() end) or 3 }
                    log("spectate: hiding " .. n .. " (visibility was " .. tostring(hidden[n][2]) .. ")")
                end
                w:SetVisibility(1)   -- ESlateVisibility::Collapsed
            end
        end
    end
end
local camCleared = false
local function clearCameraFade(pc)
    local cm = pc.PlayerCameraManager
    if not valid(cm) then return end
    local a = cm.FadeAmount
    if type(a) == "number" and a > 0 then
        cm:StopCameraFade()
        if not camCleared then camCleared = true; log("spectate: camera fade " .. tostring(a) .. " cleared") end
    end
end
local function restoreOverlays()
    for n, e in pairs(hidden) do
        if valid(e[1]) then pcall(function() e[1]:SetVisibility(e[2]) end) end
        log("spectate: restored " .. n)
    end
    hidden = {}
end
-- Session 7: spectating works, but the dead player keeps his own low-health effects: a bloody screen filter (screen effects)
-- and the crisis heartbeat (ExcitingBgmManager). Remove the screen effects and switch the crisis mode off while spectating.
local bgmSaved, fxLogged = nil, false
local function quietDeathEffects()
    local n = 0
    for _, c in ipairs(FindAllOf("ScreenEffectManagerComponent") or {}) do
        if valid(c) and try(function() return c:IsActiveInstanceExists() end) ~= false then
            pcall(function() c:DestroyAllScreenEffects() end); n = n + 1
        end
    end
    if not fxLogged then fxLogged = true; log("spectate: cleared screen effects on " .. n .. " component(s)") end
    local bgm = FindFirstOf("ExcitingBgmManager")
    if valid(bgm) and not bgmSaved then
        bgmSaved = { bgm, bgm.bEnable, bgm.CrisisHealthRatio }
        bgm.CrisisHealthRatio = -1.0
        bgm.bEnable = false
        log("spectate: crisis BGM off (was enabled=" .. tostring(bgmSaved[2]) .. ", ratio=" .. tostring(bgmSaved[3]) .. ")")
    end
end
local function restoreDeathEffects()
    if bgmSaved and valid(bgmSaved[1]) then
        pcall(function() bgmSaved[1].CrisisHealthRatio = bgmSaved[3]; bgmSaved[1].bEnable = bgmSaved[2] end)
        log("spectate: crisis BGM restored")
    end
    bgmSaved, fxLogged = nil, false
end
-- Twice per spectate (at once, and 8 s later when the death fade has come): what is on screen (all user widgets with visibility), camera fade and view target.
local function screenCensus(pc)
    local parts = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        if valid(w) then
            local inVp = try(function() return w:IsInViewport() end)
            local vis = try(function() return w:GetVisibility() end)
            if inVp then parts[#parts + 1] = name(w) .. "=" .. tostring(vis) end
        end
    end
    local cm = try(function() return pc.PlayerCameraManager end)
    log("spectate census: fade=" .. tostring(try(function() return cm.FadeAmount end)) ..
        " viewtarget=" .. name(try(function() return pc:GetViewTarget() end)) ..
        " widgets in viewport: " .. table.concat(parts, " "))
end
-- After a group respawn the guest could not move (session 8): the death fade sets a temporary input mask that is cleared only when
-- the fade finishes, and we hide the fade instead. Clear the masks and ignore flags on our controller for a few seconds.
-- The respawn first hands the controller a PlayerSpawner (the appear sequence), then the real BP_Player_C: act only on the latter.
local unlockUntil, lastUnlock, unlockedPawn = 0, 0, nil
local function unlockInput()
    local now = os.clock()
    if now > unlockUntil or now - lastUnlock < 1 then return end
    lastUnlock = now
    local pc = localPC()
    if not valid(pc) then return end
    local mine = try(function() return pc.Pawn end)
    if not (valid(mine) and name(mine):find("BP_Player_C", 1, true)) then
        if unlockedPawn ~= "wait" then unlockedPawn = "wait"; log("spectate: waiting for our new character (controller holds " .. name(mine) .. ")") end
        return
    end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if unlockedPawn ~= name(mine) then pcall(function() pc:SetViewTargetWithBlend(mine, 0.3, 0, 0, false) end) end
    local a = pcall(function() pc:ClearAllTemporaryInputMask() end)
    local b = pcall(function() pc:ResetIgnoreInputFlags() end)
    local c = pcall(function() helper:EnableInputByPlayerController(mine) end)
    -- update 11 still left the guest without any input, menu included: the death screen puts the game in UI-only input mode with
    -- focus on its widget, which we hid instead of closing. Switch back to game input.
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local d = valid(wbl) and pcall(function() wbl:SetInputMode_GameOnly(pc) end)
    -- update 12 still no input: the death fade is reference counted (RequestDeathFade(Caller, Usage, UpCount) /
    -- RequestUnfade(Caller, Usage, DownCount, Time)); the stalled death flow never counts it down. End it ourselves, once per pawn.
    -- EN_FadeUsage (from the exe's enum table): AppearPC = 101, DeathPC = 102.
    -- Calling Default__FadeUIComponentIF:RequestUnfade(pc, 102/101, true, 0.3) from here crashed the guest's game (update 13,
    -- 2026-10-28 07:53): removed. Do not call the fade interface's statics on its default object.
    -- Every Blueprint uses only temporary input masks (bpgrep: SetTemporaryInputMask, no named masks), and the guest stayed locked
    -- even with masks cleared every second: the still-active death fade most likely keeps re-applying its mask. End the fade on the
    -- component instance itself with its own ExecuteUnfade(Time) (session 7 called it without Time and it failed).
    local e, f = "-", "-"
    if unlockedPawn ~= name(mine) then
        -- ExecuteUnfade returned false (update 15). The native trace showed the lock is released only after the component's own
        -- RequestUnfade (a virtual call on component + 0x120): have CoopNative make that call on the game thread.
        local fade = FindFirstOf("BP_FadeUIComponent_C")
        local addr = valid(fade) and try(function() return fade:GetAddress() end)
        if addr and not iniHas("keep_dying=1") then   -- with keep_dying no death fade ever starts: nothing to end
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
            if c then c:write(string.format("unfade %X\n", addr)); c:close(); e = string.format("unfade sent for 0x%X", addr) end
        else
            e = "no fade component"
        end
    end
    if unlockedPawn ~= name(mine) then
        unlockedPawn = name(mine)
        log("spectate: input unlock on " .. name(mine) .. ": masks " .. tostring(a) .. ", ignore flags " .. tostring(b) .. ", enable input " .. tostring(c) .. ", game input mode " .. tostring(d) .. ", ExecuteUnfade " .. e)
    end
end
local function spectateCam(window)
    if os.clock() < bossReviveUntil then   -- keep the view and overlays until the new character is there
        local pcr = localPC()
        local pr = valid(pcr) and try(function() return pcr.Pawn end) or nil
        local hr = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        if not valid(pr) or try(function() return hr:IsDeath(pr) end) then return end
    end
    -- 2026-11-06 (owner): spectating only in boss fights. In the field a dead player gets the normal death screen and respawns: the host
    -- by the game, a guest at the last Mistle either of them used (groupRespawn). Afterwards his death fade and input lock are lifted.
    local gsw = FindFirstOf("BP_AppGameState_C")
    if window and try(function() return gsw.BossAreaState end) ~= 2 then
        if try(function() return gsw.Role end) ~= 3 then fieldDied = true end   -- only the guest needs the fade and input lifted
        return
    end
    if not window and fieldDied then
        local pcw = localPC()
        local pw = valid(pcw) and try(function() return pcw.Pawn end) or nil
        local hw = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        if valid(pw) and name(pw):find("BP_Player_C", 1, true) and not try(function() return hw:IsDeath(pw) end) then
            fieldDied = false
            unlockUntil, unlockedPawn = os.clock() + 15, nil
            log("field death: back in the world as " .. name(pw) .. ", lifting the death fade and input lock")
        end
    end
    if not window then
        local pc = localPC()
        local mine = valid(pc) and try(function() return pc.Pawn end) or nil
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local respawned = valid(mine) and not try(function() return helper:IsDeath(mine) end)
        -- give the camera back to our own pawn (2026-10-28: a window that closed without a death left the view on the host)
        if camTarget and valid(pc) and valid(mine) and name(mine):find("BP_Player_C", 1, true) then
            pcall(function() pc:SetViewTargetWithBlend(mine, 0.3, 0, 0, false) end)
            log("spectate: camera back to " .. name(mine))
        end
        if next(hidden) and respawned and camTarget then
            keepHiddenWorld = name(FindFirstOf("BP_AppGameState_C"))
            unlockUntil, unlockedPawn = os.clock() + 15, nil
            log("spectate: respawned, death overlays stay hidden until the next map; unlocking input")
        elseif next(hidden) and not keepHiddenWorld then
            restoreOverlays()
        end
        if keepHiddenWorld and name(FindFirstOf("BP_AppGameState_C")) ~= keepHiddenWorld then
            restoreOverlays(); keepHiddenWorld = nil
        end
        if bgmSaved then restoreDeathEffects() end
        camTarget, census, spectateStart, camCleared, errs = nil, 0, nil, false, {}
        return
    end
    if not spectateCamEnabled() then return end
    local pc = localPC()
    if not valid(pc) then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local mine = try(function() return pc.Pawn end)
    local mineDead = not valid(mine) or isTrueDead(helper, mine)
    if not mineDead then return end
    local target
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and not (valid(mine) and name(p) == name(mine)) and not try(function() return helper:IsDeath(p) end) then target = p; break end
    end
    if not target then return end
    step("overlays", hideOverlays)
    step("camera fade", function() clearCameraFade(pc) end)
    step("death effects", quietDeathEffects)
    step("view target", function()
        local vt = try(function() return pc:GetViewTarget() end)
        if camTarget ~= name(target) or not valid(vt) or name(vt) ~= name(target) then
            pc:SetViewTargetWithBlend(target, 0.5, 0, 0, false)
            if camTarget ~= name(target) then log("spectate: camera -> " .. name(target)) end
            camTarget = name(target)
        end
    end)
    spectateStart = spectateStart or os.clock()
    if census == 0 or (census == 1 and os.clock() - spectateStart > 8) then
        census = census + 1; step("census", function() screenCensus(pc) end)
    end
end

-- Group rest (experiment, host only, group_rest=1 in plugins\CoopNative.ini): when the host rests at a Mistle (the
-- EnemyLevelResetByCheckPoint channel closes for ~1 s, seen in session 7), every living player in the host's world is healed to
-- full. Health is server-side, so the host's SetHealth reaches the guest's character. Ichor/Regen live in the guest's save: not yet.
local function groupRestEnabled()
    local f = io.open(INI, "r"); if not f then return false end
    local s = f:read("*a") or ""; f:close()
    return s:find("group_rest=1", 1, true) ~= nil
end
local ENEMYRESET = 8
local lastReset, groupRestErr
-- true once per host rest: the EnemyLevelResetByCheckPoint channel just closed (host only, not in boss fights)
local function restEdge()
    local sm = FindFirstOf("AppSessionManager")
    local gs = FindFirstOf("BP_AppGameState_C")
    if not (valid(sm) and valid(gs)) then return false end
    if try(function() return gs.Role end) ~= 3 then return false end           -- host (authority) only
    local open = try(function() return sm:ExpectsBeOpenRaw(ENEMYRESET) end)
    local closedNow = lastReset == true and open == false
    lastReset = open
    return closedNow and try(function() return gs.BossAreaState end) ~= 2
end
local function groupRest(rested)
    if not rested or not groupRestEnabled() then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local healed = {}
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and not try(function() return helper:IsDeath(p) end) then
            local max = try(function() return helper:GetMaxHealth(p) end)
            if type(max) == "number" and max > 0 then
                local ok = pcall(function() helper:SetHealth(p, max) end)
                healed[#healed + 1] = name(p) .. (ok and ("=" .. string.format("%.0f", max)) or " FAILED")
            end
        end
    end
    log("group rest: Mistle rest seen, healed " .. table.concat(healed, ", "))
end

-- Combat probe (R5 research, log only): "in combat" = a living enemy is in battle action and its action target is a player.
-- EnemyAIUtility takes either the enemy or its AI controller as "target"; both are tried. Logged only when the answer changes.
local lastCombat, lastCombatKey, combatErr, combatTick, respawnErr = nil, "", false, 0, false
local function combatProbe()
    combatTick = combatTick + 1
    if combatTick % 3 ~= 0 then return end   -- every 0.6 s
    local ai = StaticFindObject("/Script/Extensions.Default__EnemyAIUtility")
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if not (valid(ai) and valid(helper)) then return end
    local fighters = {}
    for _, e in ipairs(FindAllOf("EnemyCommonBase") or {}) do
        if valid(e) and not try(function() return helper:IsDeath(e) end) then
            local ctrl = try(function() return e.Controller end)
            local battle = try(function() return ai:GetIsBattleAction(e) end)
            if battle == nil and valid(ctrl) then battle = try(function() return ai:GetIsBattleAction(ctrl) end) end
            if battle then
                local t = try(function() return ai:GetActionTarget(e) end)
                if not valid(t) and valid(ctrl) then t = try(function() return ai:GetActionTarget(ctrl) end) end
                local tn = valid(t) and name(t) or "none"
                if tn:find("BP_Player_C", 1, true) then fighters[#fighters + 1] = name(e) .. "->" .. tn end
            end
        end
    end
    table.sort(fighters)
    local now = #fighters > 0
    local key = table.concat(fighters, ",")
    if now ~= lastCombat or (now and key ~= lastCombatKey) then
        log("COMBAT " .. (now and "yes" or "no") .. (now and (" [" .. key .. "]") or ""))
        lastCombat, lastCombatKey = now, key
    end
end

-- Group respawn (R5 v1, host side, group_respawn=1). A guest who died for good is held by the veto (fieldWindow). Decided at the
-- moment of death: in combat -> he spectates until the host rests at a Mistle; out of combat -> back after RESPAWN_DELAY s.
-- He comes back through CharacterHelper:RequestPlayerSpawn for his PlayerController, next to the host, as a respawn.
local RESPAWN_DELAY = 7   -- the length of the death screen
local downed = {}   -- dead guest pawn name -> {at = os.clock(), mode = "spectate"|"respawn"}
-- Boss killed with someone dead (owner 2026-11-06): the host spawns every dead player next to a living one, the host included.
function bossKillRevive()
    if not bossReviveDue then return end
    bossReviveDue = false
    if os.clock() < bossReviveDoneUntil then return end   -- the rewards hook arms it a second time for the same kill
    bossReviveDoneUntil = os.clock() + 15
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local alive
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and not try(function() return helper:IsDeath(p) end) and not try(function() return helper:IsDying(p) end) then alive = p end
    end
    if not valid(alive) then log("boss revive: nobody alive?"); return end
    local pcl = localPC()
    local ownPawn = valid(pcl) and try(function() return pcl.Pawn end) or nil
    local hostDown = not valid(ownPawn) or try(function() return helper:IsDeath(ownPawn) end) == true
    local loc, rot, right = alive:K2_GetActorLocation(), alive:K2_GetActorRotation(), alive:GetActorRightVector()
    local n = 0
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local p = valid(c) and try(function() return c.Pawn end) or nil
        if valid(p) and try(function() return helper:IsDying(p) end) and not try(function() return helper:IsDeath(p) end) then
            local max = try(function() return helper:GetMaxHealth(p) end)
            local ok = type(max) == "number" and max > 0 and pcall(function() helper:SetHealth(p, max) end)
            log("boss revive: " .. name(p) .. " stands up (health " .. tostring(max) .. ") -> " .. tostring(ok))
            n = n + 1
        elseif valid(c) and (not valid(p) or try(function() return helper:IsDeath(p) end)) then
            n = n + 1
            local at = { X = loc.X + right.X * 150 * n, Y = loc.Y + right.Y * 150 * n, Z = loc.Z + 5 }
            local r = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 }
            local ok, e = pcall(function() helper:RequestPlayerSpawn(alive, c, at, r, r, true, false) end)
            log("boss revive: " .. name(c) .. " next to " .. name(alive) .. " -> " .. (ok and "called" or ("ERROR " .. tostring(e):sub(1, 120))))
        end
    end
    log("boss revive: " .. n .. " player(s) brought back")
    -- only with the host down: alive, the game sends rewards and the end itself (review 11-06)
    if n > 0 and hostDown then bossForce = { at = os.clock() + 0.5, phase = 1, showAt = os.clock() + 1.5 } end
    pcall(function() local f = io.open(TRUEDEAD_FILE, "w"); if f then f:write("0"); f:close() end end)
    bossMark = nil
end
-- The game's own event for a boss area's enemy dying (owner: tie it to the game; test 07:59: it fires, also with the host down).
pcall(function()
    RegisterHook("/Script/Extensions.BossAreaBase:MulticastOnEnemyDead", function(ctx, e)
        local area = try(function() return ctx:get() end)
        local en = try(function() return e:get() end)
        local hlp = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local boss = valid(en) and try(function() return hlp:IsBoss(en) end)
        local last = valid(area) and try(function() return area:IsLastPhase() end)
        log("boss event: MulticastOnEnemyDead " .. (valid(en) and name(en) or "?") .. " boss=" .. tostring(boss) .. " lastPhase=" .. tostring(last))
        if boss and last ~= false then bossReviveUntil, bossReviveDue, bossArea = os.clock() + 8, true, area; recBossDue = true end
    end)
end)
pcall(function()
    RegisterHook("/Script/Extensions.BossAreaBase:OnAbortByPleyerCharacterDeath", function() log("boss event: OnAbortByPleyerCharacterDeath") end)
end)
-- 2026-11-06: Io kept trying to revive the dead host and stood still. A dead player in a boss fight gets the same "can never be
-- revived" answer as a true death (CoopNative.truedead, read by the IsNeverRevive hook). AI partners live on the host.
bossMark, bossMarkAt = nil, -1000
function bossDeadMark()
    if os.clock() - bossMarkAt < 1 then return end
    bossMarkAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local now
    if try(function() return gs.BossAreaState end) == 2 then
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
            if valid(p) and isDownFinal(helper, p) then now = try(function() return p:GetAddress() end) end
        end
    end
    if now == bossMark then return end
    bossMark = now
    local f = io.open(TRUEDEAD_FILE, "w")
    if f then f:write(now and string.format("%X B", now) or "0"); f:close() end
    log("boss fight: never-revive mark " .. (now and string.format("on %X", now) or "cleared"))
end
-- Where a guest who died in the field comes back (owner 2026-11-06): the last Mistle used by the host or a guest in this session.
lastMistle = nil
function noteMistle(pawn, who)
    local loc = valid(pawn) and try(function() return pawn:K2_GetActorLocation() end)
    if not loc then return end
    lastMistle = { X = loc.X, Y = loc.Y, Z = loc.Z, Yaw = try(function() return pawn:K2_GetActorRotation().Yaw end) or 0 }
    log(string.format("last Mistle: used by the %s at %.0f,%.0f,%.0f", who, loc.X, loc.Y, loc.Z))
    if fogQuiet then fogQuiet(90) end
end
local function respawnGuest(helper, deadPawn, hostPawn, withAppear, atMistle)
    local pc
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then pc = c end
    end
    if not valid(pc) then log("group respawn: no remote PlayerController"); return false end
    local loc = hostPawn:K2_GetActorLocation()
    local rot = hostPawn:K2_GetActorRotation()
    local right = hostPawn:GetActorRightVector()
    local at = { X = loc.X + right.X * 150, Y = loc.Y + right.Y * 150, Z = loc.Z + 5 }   -- (2026-11-06: +50 left him floating for a moment)
    local r = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 }
    if atMistle then at = { X = atMistle.X, Y = atMistle.Y, Z = atMistle.Z + 5 }; r.Yaw = atMistle.Yaw end
    -- InIsSkipAppear = true: without it the guest's controller first got a PlayerSpawner (appear sequence) and he could not move
    local ok, e = pcall(function() helper:RequestPlayerSpawn(hostPawn, pc, at, r, r, true, not withAppear) end)
    log("group respawn: RequestPlayerSpawn(" .. name(pc) .. ") " .. (atMistle and "at the last Mistle" or "next to the host") .. (withAppear and " with the appear effect" or "") ..
        " -> " .. (ok and "called" or ("ERROR " .. tostring(e):sub(1, 120))))
    return ok
end
local function groupRespawn(rested)
    if not iniHas("group_respawn=1") then return end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    if try(function() return gs.BossAreaState end) == 2 then downed = {}; return end
    local pc = localPC()
    local hostPawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if rested and valid(hostPawn) then noteMistle(hostPawn, "host") end
    local grf = io.open(WIN64 .. "\\plugins\\CoopNative.guestrest", "r")
    if grf then
        grf:close(); os.remove(WIN64 .. "\\plugins\\CoopNative.guestrest")
        for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
            if valid(c) and not try(function() return c:IsLocalController() end) then noteMistle(try(function() return c.Pawn end), "guest") end
        end
    end
    if not valid(hostPawn) or try(function() return helper:IsDeath(hostPawn) end) then downed = {}; return end
    if os.clock() < postBossUntil or os.clock() - rewardsAt < 60 then return end   -- the outro and memory bring him back themselves
    local seen = {}
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and name(p) ~= name(hostPawn) and try(function() return helper:IsDeath(p) end) then
            local n = name(p); seen[n] = true
            local d = downed[n]
            if not d then
                d = { at = os.clock(), mode = "respawn" }
                downed[n] = d
                log("group respawn: " .. n .. " died in the field -> respawns " .. (lastMistle and "at the last Mistle" or "next to the host (no Mistle used yet)") .. " after " .. RESPAWN_DELAY .. " s")
            end
            if os.clock() - d.at >= RESPAWN_DELAY and not d.done then d.done = true; respawnGuest(helper, p, hostPawn, true, lastMistle) end   -- one try per death
        end
    end
    for n in pairs(downed) do if not seen[n] then downed[n] = nil end end
end

-- R4 stage 1 (vestige_menu=1): the Mistle menu (WDT_CheckpointMenu) disables its memory/restoration pieces whenever
-- GetRescueSignalState(self) is not Idle, i.e. as soon as a distress signal is out. Answer Idle only when the asking
-- calling object is that menu; every other caller sees the real state. Restoring may still end the signal (vanilla shows
-- "ending the distress signal" and destroys the session before the memory); CoopSeamless re-signals afterwards.
-- A Lua hook on GetRescueSignalState froze the game when the distress signal was sent (2026-10-27 21:20), so the override lives in
-- CoopNative's native hook; Lua only hands over the menu's class address once ("menuclass <hex>" in CoopNative.cmd).
local menuClassSent = false
local function sendMenuClass()
    if menuClassSent or not iniHas("vestige_menu=1") then return end
    -- item 3 (2026-10-30): the class object exists as soon as the widget blueprint is loaded, before the first menu instance; look it
    -- up by path so the first Mistle menu is not greyed (it was handed over only after the first menu existed)
    local cls = StaticFindObject("/Game/UserInterface/CheckPointMenu/WDT_CheckpointMenu.WDT_CheckpointMenu_C")
    if not valid(cls) then
        local m = FindFirstOf("WDT_CheckpointMenu_C")
        cls = valid(m) and try(function() return m:GetClass() end) or nil
    end
    local addr = valid(cls) and try(function() return cls:GetAddress() end)
    if not addr then return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("menuclass %X\n", addr)); c:close(); menuClassSent = true end
    log(string.format("vestige menu: WDT_CheckpointMenu_C class at 0x%X sent to CoopNative", addr))
end

-- Vestige restoration with a session (vestige_keep=1, R4 stage 2): CoopNative answers "no session" to the restoration screen's
-- IsCreateSession / GetOnlineOtherPlayerNum; Lua hands over that screen's class once ("restclass <hex>"), like the menu class.
local restClassSent = false
local function sendRestoreClass()
    if restClassSent or not iniHas("vestige_keep=1") then return end
    local m = FindFirstOf("BP_BCRestorationUIComponent_C")
    local cls = valid(m) and try(function() return m:GetClass() end) or nil
    local addr = cls and try(function() return cls:GetAddress() end)
    if not addr then return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("restclass %X\n", addr)); c:close(); restClassSent = true end
    log(string.format("vestige restoration: BP_BCRestorationUIComponent_C class at 0x%X sent to CoopNative", addr))
end

-- Keep a guest dying instead of dead (keep_dying=1, both PCs, R5 v2). Patching the guest's death sequence after a respawn left him
-- without input (session 8), so CoopNative vetoes the final death for the characters listed in CoopNative.protect while the host
-- lives: on the host the guests' pawns (the host decides e.g. fall deaths, TryExecuteDeath), on the guest his own pawn (his game
-- decides an expired dying countdown itself, DeathProcess). The guest stays in the revivable dying state and his death sequence never
-- starts. On the host's next Mistle rest every dying guest is set to full health (first revive attempt).
local lastProtect, keepErr, teleportErr
local oldPawns = {}   -- {p, n, at}: dissolved pawns to remove after the respawn
local tdSeen, pendingRespawn = {}, false   -- tdSeen[addr] = {at, down}: first sighting of a true-death marker
local guestFallAt = {}                     -- host: guest pawn address -> last time it fell fast (os.clock)
local TRUEDEAD_PATH = WIN64 .. "\\plugins\\CoopNative.truedead"
-- The revive window running out dissolves the character (bIsDisappearExpression; the ExecuteDisappearExpression thunk was not the
-- path, session 8), and a guest revived after it stayed invisible on both PCs. Undo it on revival: switch the dissolve off (a
-- multicast from the host reaches both PCs) and make every skeletal mesh visible again; log the state before and after.
local function makeVisible(helper, p, who)
    local before = tostring(try(function() return p.bIsDisappearExpression end)) .. "/" .. tostring(try(function() return helper:IsVanish(p) end))
    local a = pcall(function() p:Multicast_SetEnableDisappearExpression(false) end)
    local b = pcall(function() p.bIsDisappearExpression = false end)
    local c = pcall(function() helper:SetAllSkeletalMeshVisibility(p, true) end)
    local after = tostring(try(function() return p.bIsDisappearExpression end)) .. "/" .. tostring(try(function() return helper:IsVanish(p) end))
    log("keep dying: " .. who .. " make " .. name(p) .. " visible: disappear/vanish " .. before .. " -> " .. after ..
        " (multicast " .. tostring(a) .. ", flag " .. tostring(b) .. ", meshes " .. tostring(c) .. ")")
end
-- Home Base with the session kept (2026-11-06, diagnostic). Home Base is streamed into MainGame like every stage (29 sublevels in its list), yet
-- at the 10-29 test the host arrived in empty space and fell: its levels came up only after the session had ended. This logs every Home
-- Base level twice a second for 45 s, holds the host in the air until the geometry is there, and forces the levels after 10 s if nothing moved.
hbLevels, hbAt, hbNext, hbForced, hbStart = nil, 0, 0, false, false
-- The game's Home Base mode (values read on the host at Home Base, 10-30): no weapon, no veil, no dash or attack. Each game sets it for its own
-- character; on a guest nobody does, so he kept weapon and veil over the Home Base animations.
function hbBaseInfo()
    return { FieldType = 1, HeadUpDisplayType = 1, LimitMoveType = 0, bCanDash = false, bCanAttack = false, bWeaponVisibility = false, bCanStep = false, UseItemType = 1,
             bCanFieldMenu = true, CameraType = 0, ClothType = 0, bToxicGuardMaskInnerVisibility = false, bToxicGuardMaskOuterVisibility = false, bJinkakuVisibility = false,
             CameraLightIntensity = 0, bNowAvatarCustomizing = false, bSpecialGimmickActive = false }
end
-- the guest's talk fix needs the name of the script function (see CoopNative)
talkSent, talkAt = false, -1000
function talkFnSend()
    if talkSent or os.clock() - talkAt < 5 then return end
    talkAt = os.clock()
    local f = StaticFindObject("/Game/Cinematics/Scenario/Common/Blueprints/Base/BP_ScenarioStarter.BP_ScenarioStarter_C:ProcessInputButtonEvent")
    local a = valid(f) and try(function() return f:GetAddress() end)
    if not a then return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("talkfn %X\n", a)); c:close(); talkSent = true; log(string.format("talk: ProcessInputButtonEvent at %X sent to CoopNative", a)) end
end
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text == "CoopHBStart" then hbStart, hbGuestWait, hbTarget, hbEnterAt, hbPlacedAt = true, true, nil, os.clock(), nil; hbFlowAt = os.clock()
        elseif text == "CoopHBLeave" then hbLeaveIn, hbDest = true, nil; hbFlowAt = os.clock()
        elseif text == "CoopHBFree" then hbFreeAt = os.clock(); log("hb: the host let us go")
        elseif text and text:find("^CoopFadeMode:") then tpUsage = tonumber(text:match("(%d+)$"))
        elseif text and text:find("^CoopHBDest:") then
            local x, y, z = text:match("^CoopHBDest:([-%d.]+),([-%d.]+),([-%d.]+)")
            if z then hbDest = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }; log("hb: leaving, the host's target is " .. x .. " " .. y .. " " .. z) end
        elseif text and text:find("^CoopHBAt:") then
            local x, y, z = text:match("^CoopHBAt:([-%d.]+),([-%d.]+),([-%d.]+)")
            if z then hbTarget = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
        end
    end)
end)
-- 11-06 09:28: held on his PC he still fell (39036, then 37222...) and died: the host simulates his character, and its copy lost the ground when
-- the field streamed away there. So the host holds its copy in the air, from the teleport until he stands in Home Base.
-- 11-06 baseinfo: his character has the mode (weapon and veil off, like the host's), yet both stayed: a character reads it when it is made, his already
-- exists. These re-apply it. (Untested.)
function hbApplyLook(hlp, p)
    local a, ea = pcall(function() hlp:UpdateJinkakuVisibility(p) end)
    local b, eb = pcall(function() hlp:OnAnimNotifyStateChangeVisibilityOfWeapon(p, false, 0.0) end)
    -- 11-06: the face mask stayed on in the lounge. Home Base info has both mask flags off, the same call for them as for the veil.
    local c, ec = pcall(function() hlp:SetToxicGuardMaskVisibility(p, false); hlp:SetToxicGuardMaskInnerVisibility(p, false); hlp:SetToxicGuardMaskOuterVisibility(p, false) end)
    log("hb: veil, weapon and mask re-applied on " .. name(p) .. " -> " .. (a and "ok" or tostring(ea):sub(1, 80)) .. ", " .. (b and "ok" or tostring(eb):sub(1, 80)) .. ", " .. (c and "ok" or tostring(ec):sub(1, 80)))
end
function hbInBase()
    local fm = FindFirstOf("AppFieldManager")
    return valid(fm) and try(function() return fm:IsInHideout(fm) end) == true
end
-- Leaving Home Base, 11-06 22:34: the teleport driver had nothing to wait for and the game asked for no stage level in 44 s, with both of us at the target and LSV_Base01
-- still wanted: the volumes did not react to where we stand. Why is open, so this finds the volumes around us (CoopNative "vols"), logs their state, clears a disabled one,
-- and after 3 s more asks for their levels itself, as the volume would.
hbAskNext, hbAskPending, hbAskVols, hbAskClearedAt, hbAskLevels, hbAllLevels, hbVolMap = 0, false, nil, nil, nil, {}, {}
hbDest, hbDestNext, hbLeaveGood, hbArrivedAt, hbFadeOn, hbAfterUntil, hbAfterNext = nil, 0, false, nil, false, 0, 0
function hbAskReset()
    hbAskNext, hbAskPending, hbAskVols, hbAskClearedAt, hbAskLevels, hbAllLevels, hbVolMap = 0, false, nil, nil, nil, {}, {}
    hbDestNext, hbLeaveGood, hbArrivedAt, hbFadeOn, hbToldHost, hbGuestStage = 0, false, nil, false, false, false
    hbLeaveOld = nil
end
-- 11-07 08:55: the running driver was never seen in the 3.9 s before arrival, so the target is known at arrival at the earliest. The host sends it to the guests then: he loads the
-- stage in Home Base, behind his fade, and his new character comes only when the host's stage is shown (08:55: spawned while 60 levels streamed, host crashed 3 s later).
function hbSendDest(mine)
    local l = valid(mine) and try(function() return mine:K2_GetActorLocation() end)
    if not l then return end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            pcall(function() c:ClientMessage(string.format("CoopHBDest:%.1f,%.1f,%.1f", l.X, l.Y, l.Z), FName("None"), 0) end)
        end
    end
end
-- black until both are there: our own fade (teleport usage 48), from the Mistle on, as the guest's. The game lifts its own (usage 101) at arrival, and it must: 11-07 09:30 with that
-- unfade kept back (CoopNative "fadehold", not used any more) no level was asked for on either PC, the forced flags did not hold, and both fell after the 45 s.
function hbFade(on, pawn)
    local a = valid(pawn) and try(function() return pawn:GetAddress() end)
    if not a then return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("tpfade %X %d%s\n", a, on and 1 or 0, tpUsageArg())); c:close() end
    hbFadeOn = on
    log("hb: leaving, screen " .. (on and "stays black until the stage and the guests are here" or "back"))
end
-- 11-09 20:00: the guest was released into the Duomo with all 24 stage levels shown for 2.5 s, fell 3 m (no floor on his PC yet) into a kill zone and died.
-- "Levels shown" is not "floor there": ask the character's own movement for the floor under it (K2_FindFloor) before the hold ends.
hbFloorErr, hbFloorLogAt = nil, 0
function hbFloorOk(p, now, since)
    local cm = valid(p) and try(function() return p.CharacterMovement end) or nil
    local loc = valid(p) and try(function() return p:K2_GetActorLocation() end) or nil
    if not valid(cm) or not loc then return true end
    local waited = now - (since or now)
    if hbFloorErr then return waited >= 8 end
    local res = {}
    local ok, e = pcall(function() cm:K2_FindFloor(loc, res) end)
    local hit, walk, dist = res.bBlockingHit, res.bWalkableFloor, res.FloorDist
    if not ok or hit == nil then
        hbFloorErr = ok and "no result fields" or tostring(e):sub(1, 100)
        log("hb: floor check unavailable (" .. hbFloorErr .. "): waiting 8 s instead")
        return waited >= 8
    end
    if now - hbFloorLogAt > 1 then
        hbFloorLogAt = now
        log(string.format("hb: floor under %s: hit %s walkable %s dist %s (waited %.1f s)", name(p), tostring(hit), tostring(walk), tostring(dist), waited))
    end
    if hit == true and walk == true and type(dist) == "number" and dist < 200 then return true end
    return waited >= 40   -- never hold for ever
end
-- Fall rescue (11-09): whatever the checks say, a character that drops 15 m below the place it was held at within a minute after the release has fallen through the world:
-- it is put back there and held again until the floor check passes (3 times at most per window).
hbHoldPos, hbRescueUntil, hbRescues, hbHoldPawn, hbRescueAt = nil, 0, 0, nil, -1000
hbEntryFade, hbEntryOffAt, hbEntryUsed = false, nil, false
function hbRescueTick()
    local now = os.clock()
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) or not name(mine):find("BP_Player", 1, true) then return end
    local lp = try(function() return mine:K2_GetActorLocation() end)
    if not lp then return end
    local cm = try(function() return mine.CharacterMovement end)
    local ma = try(function() return mine:GetAddress() end)
    if ma ~= hbHoldPawn then hbHoldPawn, hbHoldPos, hbRescues = ma, nil, 0 end   -- a new character: its own hold
    if now < hbUntil and valid(cm) and try(function() return cm.MovementMode end) == 5 and lp.Z > -1000 then
        -- held flying (by us, or by the host on a guest): where it is is where it is held; a hold seen in the window arms the rescue
        hbHoldPos = { X = lp.X, Y = lp.Y, Z = lp.Z }
        hbRescueUntil = math.max(hbRescueUntil, now + 20)
    end
    if not hbHoldPos or now >= hbRescueUntil or hbRescues >= 3 or now - hbRescueAt < 3 then return end
    local fallMode = valid(cm) and try(function() return cm.MovementMode end)
    local fallVz = try(function() return mine:GetVelocity().Z end) or 0
    if lp.Z < hbHoldPos.Z - 1500 and fallMode == 3 and fallVz < -1500 then
        hbRescueAt = now
        hbRescues = hbRescues + 1
        local rot = try(function() return mine:K2_GetActorRotation() end) or { Pitch = 0, Yaw = 0, Roll = 0 }
        local ok = pcall(function() mine:K2_TeleportTo({ X = hbHoldPos.X, Y = hbHoldPos.Y, Z = hbHoldPos.Z + 20 }, rot) end)
        if valid(cm) then
            pcall(function() cm:StopMovementImmediately() end)
            pcall(function() cm:SetMovementMode(5, 0) end)
        end
        hbReady, hbHover, hbUntil, hbAt = false, true, now + 30, now
        hbRescueUntil = now + 60
        if hbEntryUsed then
            hbEntryFade, hbEntryOffAt = true, nil
            hbFade(true, mine)
        end
        log(string.format("hb: FELL THROUGH (z %.0f, held at %.0f): back to the hold %s, held again (%d of 3)", lp.Z, hbHoldPos.Z, tostring(ok), hbRescues))
    end
end
-- what the characters do after the hold, 11-07: "stuck in the air" at ground height
function hbAfterLog()
    local now = os.clock()
    if now >= hbAfterUntil or now < hbAfterNext then return end
    hbAfterNext = now + 1
    local pc = localPC()
    local p = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(p) then return end
    local l = try(function() return p:K2_GetActorLocation() end)
    local v = try(function() return p:GetVelocity() end)
    log(string.format("hb: after the hold: %s at %s, mode %s, speed %s, move input ignored %s", name(p), l and string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) or "?",
        tostring(try(function() return p.CharacterMovement.MovementMode end)), v and string.format("%.0f", math.sqrt(v.X * v.X + v.Y * v.Y)) or "?",
        tostring(try(function() return pc:IsMoveInputIgnored() end))))
end
function hbAskSend(loc)
    os.remove(WIN64 .. "\\plugins\\CoopNative.volsout")
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.vols", "w")
    if not f then return end
    f:write(string.format("%.0f %.0f %.0f\n", loc.X, loc.Y, loc.Z))
    hbVolMap = {}
    for _, v in ipairs(FindAllOf("AppLevelStreamingVolume") or {}) do
        local a = valid(v) and try(function() return v:GetAddress() end)
        if a then hbVolMap[string.format("%X", a)] = v; f:write(string.format("%X\n", a)) end
    end
    f:close()
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write("vols\n"); c:close() end
    hbAskPending = true
end
function hbAskRead()
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.volsout", "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    if not s:find("done", 1, true) then return nil end
    local out = {}
    for a in s:gmatch("(%x+)%s") do
        local v = hbVolMap[a]
        if valid(v) and not name(v):find("Base", 1, true) then out[#out + 1] = v end
    end
    return out
end
function hbAskForce(want)
    if hbAskLevels then
        for _, l in ipairs(hbAskLevels) do if valid(l) then pcall(function() l.bShouldBeLoaded = true; l.bShouldBeVisible = true end) end end
        return
    end
    local names, nn = {}, 0
    for _, v in ipairs(hbAskVols) do
        pcall(function() v.StreamingLevelNames:ForEach(function(_, e)
            local s = e:get():ToString()
            names[s:match("[^/]+$") or s] = true
            nn = nn + 1
        end) end)
    end
    hbAskLevels = {}
    for _, e in ipairs(hbAllLevels) do
        if names[e.p:match("[^/]+$") or e.p] then hbAskLevels[#hbAskLevels + 1] = e.l end
    end
    log("hb: leaving, the game asked for " .. want .. " stage levels; asking for " .. #hbAskLevels .. " levels of " .. nn .. " names in " .. #hbAskVols .. " volumes ourselves")
    hbAskForce(want)
end
function hbLeaveAsk(now, want, mine)
    if hbAskLevels then hbAskForce(want); return end
    if hbAskVols then
        if want == 0 then hbAskForce(want) end
        return
    end
    if hbAskPending then
        local vols = hbAskRead()
        if not vols then return end
        hbAskPending = false
        if #vols == 0 then return end
        local fm = FindFirstOf("AppFieldManager")
        log("hb: leaving, field tracking " .. tostring(valid(fm) and try(function() return fm:IsFieldTrackingActive(fm) end)) .. ", in Home Base " .. tostring(hbInBase()))
        local parts, cleared = {}, 0
        for _, v in ipairs(vols) do
            local dis = try(function() return v.bDisabled end)
            parts[#parts + 1] = name(v) .. " disabled=" .. tostring(dis) .. " wants=" .. tostring(try(function() return v:IsEitherLevelShouldBeLoaded() end))
            if dis == true and pcall(function() v:SetForceDisable(false); v.bDisabled = false end) then cleared = cleared + 1 end
        end
        log("hb: leaving, volumes around us: " .. table.concat(parts, " | "):sub(1, 500) .. (cleared > 0 and (" -> " .. cleared .. " enabled") or ""))
        hbAskVols, hbAskClearedAt = vols, now
        return
    end
    if now < hbAskNext then return end
    hbAskNext = now + 1
    local loc = hbDest or (valid(mine) and try(function() return mine:K2_GetActorLocation() end))
    if loc then hbAskSend(loc) end
end
-- Leaving Home Base with a guest: the same hold as on the way in (11-06 14:32)
function hbLeaveStart()
    local guests = {}
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then guests[#guests + 1] = c end
    end
    if #guests == 0 then return end
    hbUntil, hbAt, hbNext, hbForced, hbReady, hbLevels = os.clock() + 45, os.clock(), 0, false, false, nil
    hbLeave, hbLeaveArrived, hbLeaveOk, hbHostHold, hbRelease = true, false, nil, true, nil
    hbHoldFrom = os.clock() + 1.2
    hbBrought, hbGuestFloor = false, false
    hbEntryFade, hbEntryOffAt, hbEntryUsed = false, nil, false
    hbAskReset()
    hbDest = nil
    local pcs = localPC()
    hbFade(true, valid(pcs) and try(function() return pcs.Pawn end) or nil)
    log("hb: leaving Home Base with " .. #guests .. " guest(s): held until the stage is there")
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    for _, c in ipairs(guests) do
        pcall(function() c:ClientMessage("CoopHBLeave", FName("None"), 0) end)
        local g = try(function() return c.Pawn end)
        if valid(g) and iniHas("hb_base_mode=1") then pcall(function() helper:ClearRestrictedActionInBaseInfoHost(g) end) end
    end
end
-- a guest under the floor cannot get out by himself (11-07: 80 units below us, stuck); the host's own height is the ground here
function hbLiftGuests()
    local pc = localPC()
    local me = valid(pc) and try(function() return pc.Pawn end) or nil
    local hp = valid(me) and try(function() return me:K2_GetActorLocation() end)
    if not hp then return end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end) or nil
        local gp = valid(g) and try(function() return g:K2_GetActorLocation() end)
        if gp and gp.Z < hp.Z - 40 then
            local to = { X = gp.X, Y = gp.Y, Z = hp.Z + 30 }
            local ok, moved = pcall(function() return g:K2_TeleportTo(to, try(function() return g:K2_GetActorRotation() end) or { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            log(string.format("hb: %s was %.0f under us, lifted -> %s %s", name(g), hp.Z - gp.Z, tostring(ok), tostring(moved)))
        end
    end
end
function hbGuestsHere()
    local pc = localPC()
    local me = valid(pc) and try(function() return pc.Pawn end) or nil
    local hp = valid(me) and try(function() return me:K2_GetActorLocation() end)
    if not hp then return true end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end) or nil
        local gp = valid(g) and try(function() return g:K2_GetActorLocation() end)
        if gp then
            local dx, dy, dz = gp.X - hp.X, gp.Y - hp.Y, gp.Z - hp.Z
            if dx * dx + dy * dy + dz * dz > 2000 * 2000 then
                local to = { X = hp.X + 150, Y = hp.Y, Z = hp.Z + 5 }
                local ok, moved = pcall(function() return g:K2_TeleportTo(to, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                hbRetryLogs = (hbRetryLogs or 0) + 1
                if hbRetryLogs <= 10 then log(string.format("hb: %s is still at z=%.0f, moving him again -> %s, answer %s", name(g), gp.Z, tostring(ok), tostring(moved))) end
                return false
            end
        end
    end
    return true
end
function hbHoldGuests(mode)
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end) or nil
        local gm = valid(g) and try(function() return g.CharacterMovement end) or nil
        if valid(gm) and try(function() return gm.MovementMode end) ~= mode then
            pcall(function() gm:StopMovementImmediately() end)
            pcall(function() gm:SetMovementMode(mode, 0) end)
        end
    end
end
-- every character for CoopNative's appear lock (see clear_holder_flags)
hbHoldersAt = -1000
function hbHolders()
    if os.clock() - hbHoldersAt < 2 then return end
    hbHoldersAt = os.clock()
    local list = {}
    for _, q in ipairs(FindAllOf("Character") or {}) do
        local a = valid(q) and try(function() return q:GetAddress() end)
        if a then list[#list + 1] = string.format("%X", a) end
    end
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.holders", "w")
    if f then f:write(table.concat(list, " ")); f:close() end
end
function hbWatch()
    pcall(hbAfterLog)
    local path = WIN64 .. "\\plugins\\CoopNative.hbwatch"
    local f = io.open(path, "r")
    if f or hbStart then
        if f then f:close(); os.remove(path) end
        hbStart = false
        hbUntil, hbAt, hbNext, hbForced, hbReady, hbLevels = os.clock() + 45, os.clock(), 0, false, false, nil
        hbLeave, hbLeaveArrived, hbLeaveOk = false, false, nil
        hbBrought, hbGuestFloor = false, false
        log("hb: teleport to Home Base with the session kept, watching the levels")
        if REC then recSchedule("hb") end
        if not f then
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
            if c then c:write("hbstart\n"); c:close() end
        end
        -- 11-06: his ground streams away with the host's departure; twice he was already falling when the host moved him, and then the move
        -- did not stop him (the 08:49 run just won that race). So he is held in the air from the very start.
        local gss = FindFirstOf("BP_AppGameState_C")
        if f and valid(gss) and try(function() return gss.Role end) == 3 then
            hbHostHold, hbRelease = true, nil
            hbHoldFrom = os.clock() + 1.2
            hbEntryFade, hbEntryOffAt, hbEntryUsed = true, nil, true
            local pce = localPC()
            hbFade(true, valid(pce) and try(function() return pce.Pawn end) or nil)
            for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(c) and not try(function() return c:IsLocalController() end) then pcall(function() c:ClientMessage("CoopHBStart", FName("None"), 0) end) end
            end
        end
    end
    if hbLeaveIn then
        hbLeaveIn = false
        hbUntil, hbAt, hbNext, hbForced, hbReady, hbLevels = os.clock() + 45, os.clock(), 0, false, false, nil
        hbLeave, hbLeaveArrived, hbLeaveOk, hbGuestWait, hbTarget = true, true, nil, false, nil
        hbAskReset()
        -- 11-07 12:18: his stage came while he still stood in Home Base, "not in Home Base" turned true there (the field follows the levels), he was let go, and fell
        -- through Home Base (its levels go with the host's), 40117 -> 34566, before his new character came: emptiness, fall damage. Ready only with the new character.
        local pco = localPC()
        local old = valid(pco) and try(function() return pco.Pawn end) or nil
        hbLeaveOld = valid(old) and try(function() return old:GetAddress() end) or nil
        log("hb: the host leaves Home Base, we hover until the stage is here")
        if iniHas("hb_base_mode=1") then
            local pcl = localPC()
            local me = valid(pcl) and try(function() return pcl.Pawn end) or nil
            local hlp = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
            if valid(me) then pcall(function() hlp:ClearRestrictedActionInBaseInfo(me) end) end
        end
    end
    local now = os.clock()
    if hbHostHold then
        if hbBrought and not hbGuestFloor then pcall(fsHostIn) end
        if hbBrought and (hbReady or now > hbUntil) and (hbGuestFloor or now - hbBroughtAt > 15) then
            if not hbGuestFloor then log("hb: the guest never said his floor is there (15 s): letting him go anyway") end
            hbBrought, hbRelease = false, now + 1
        end
        -- 11-06 13:58: the move answered "ok" but he stayed in the old area, was let go 2 s later and fell. He stays held until he is really here.
        if hbRelease and now >= hbRelease and now < hbUntil + 60 and not hbGuestsHere() then
            hbRelease = now + 1
            hbHoldGuests(5)
        elseif hbRelease and now >= hbRelease or now > hbUntil + 60 then
            local lm = hbLeave and 3 or 1
            if hbLeave then pcall(hbLiftGuests) end
            hbHostHold, hbRelease, hbLeave = false, nil, false
            hbHoldGuests(lm)
            log("hb: guests released, walking")
            for _, cf in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(cf) and not try(function() return cf:IsLocalController() end) then pcall(function() cf:ClientMessage("CoopHBFree", FName("None"), 0) end) end
            end
            if hbFadeOn then
                local pcf = localPC()
                hbFade(false, valid(pcf) and try(function() return pcf.Pawn end) or nil)
            end
        elseif now >= (hbHoldFrom or 0) then hbHoldGuests(5) end
    end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local cm = valid(mine) and try(function() return mine.CharacterMovement end) or nil
    if hbEntryFade and hbEntryOffAt and now >= hbEntryOffAt then
        hbEntryFade, hbEntryOffAt = false, nil
        hbFade(false, mine)
    end
    if now > hbUntil then
        if hbFadeOn then hbFade(false, mine) end
        if hbHover then
            hbHover = false
            if valid(cm) then pcall(function() cm:SetMovementMode(hbLeave and 3 or 1, 0) end) end
            log("hb: window over without the geometry -> walking again")
        end
        return
    end
    -- leaving: only held when we are at the target with nothing under us; a character that arrives on the floor stays out of this
    local mineAddr = valid(mine) and try(function() return mine:GetAddress() end)
    local oldChar = hbLeave and not hbHostHold and hbLeaveOld ~= nil and mineAddr == hbLeaveOld
    local hoverNow = not hbReady and (not hbLeave or oldChar or (hbLeaveArrived and not hbLeaveGood)) and os.clock() >= (hbFlowAt or -1000) + 1.2
    if hoverNow and valid(cm) and try(function() return cm.MovementMode end) ~= 5 then pcall(function() cm:SetMovementMode(5, 0) end); hbHover = true end
    if hbTarget and valid(mine) then   -- his own game moves him, until he is really there
        local gp = try(function() return mine:K2_GetActorLocation() end)
        if gp then
            local dx, dy, dz = gp.X - hbTarget.X, gp.Y - hbTarget.Y, gp.Z - hbTarget.Z
            if dx * dx + dy * dy + dz * dz < 300 * 300 then
                log(string.format("hb: we are next to the host at z=%.0f", gp.Z))
                hbPlacedAt = now
                hbTarget, hbGuestWait = nil, false
            else
                local ok, moved = pcall(function() return mine:K2_TeleportTo(hbTarget, try(function() return mine:K2_GetActorRotation() end) or { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                hbMoveLogs = (hbMoveLogs or 0) + 1
                if hbMoveLogs <= 12 then log(string.format("hb: moving ourselves next to the host (z=%.0f -> %.0f) %s, answer %s", gp.Z, hbTarget.Z, tostring(ok), tostring(moved))) end
            end
        end
    end
    if now < hbNext then return end
    hbNext = now + 0.5
    pcall(hbHolders)
    if not hbLevels or #hbLevels == 0 then
        hbLevels = {}
        local total, samples = 0, {}
        for _, cls in ipairs({"LevelStreamingKismet", "LevelStreamingAlwaysLoaded", "LevelStreaming"}) do
            for _, l in ipairs(FindAllOf(cls) or {}) do
                if valid(l) then
                    total = total + 1
                    -- 11-06 08:34: PackageName:ToString found nothing; several ways, and raw samples in the log
                    local pkg = try(function() return l:GetWorldAssetPackageFName():ToString() end)
                    if type(pkg) ~= "string" then pkg = try(function() return l.PackageNameToLoad:ToString() end) end
                    if type(pkg) ~= "string" then pkg = try(function() return l.PackageName:ToString() end) end
                    if type(pkg) ~= "string" then pkg = "" end
                    if #samples < 4 then samples[#samples + 1] = name(l) .. "=" .. pkg:sub(-40) end
                    if hbLeave then
                        hbAllLevels[#hbAllLevels + 1] = { l = l, p = pkg }
                        -- leaving: the static mesh levels of any other area; the ones the game asks for decide
                        if pkg:find("/Environment/", 1, true) and pkg:find("_SM", 1, true) and not pkg:find("Base0", 1, true) then hbLevels[#hbLevels + 1] = { l = l, n = pkg:match("([^/]+)$") or pkg } end
                    elseif pkg:find("Base01_Hideout", 1, true) and pkg:find("Environment", 1, true) then hbLevels[#hbLevels + 1] = { l = l, n = pkg:match("Hideout_([%w_]+)$") or pkg:match("([^/]+)$") } end
                end
            end
        end
        log("hb: " .. #hbLevels .. " Home Base levels of " .. total .. " found; samples " .. table.concat(samples, " | "))
        local vols = {}
        for _, v in ipairs(FindAllOf("AppLevelStreamingVolume") or {}) do
            if valid(v) and name(v):find("Base", 1, true) then vols[#vols + 1] = name(v) .. " should=" .. tostring(try(function() return v:IsEitherLevelShouldBeLoaded() end)) .. " autoKeep=" .. tostring(try(function() return v.bAutoEnableFromFirstSpawnToQuitGame end)) end
        end
        log("hb: volumes " .. table.concat(vols, " | "):sub(1, 500))
    end
    local parts, loaded, visible, geo = {}, 0, 0, false
    local want, shown = 0, 0
    for _, e in ipairs(hbLevels) do
        local l = e.l
        if valid(l) then
            local sl = try(function() return l.bShouldBeLoaded end)
            local sv = try(function() return l.bShouldBeVisible end)
            local il = try(function() return l:IsLevelLoaded() end)
            local iv = try(function() return l:IsLevelVisible() end)
            if il then loaded = loaded + 1 end
            if iv then visible = visible + 1 end
            if iv and e.n == "SM" and not hbLeave then geo = true end   -- (the floor under the character decides below)
            if sl then want = want + 1; if iv then shown = shown + 1 end end
            if not hbLeave then parts[#parts + 1] = string.format("%s:%d%d%d%d", e.n, sl and 1 or 0, sv and 1 or 0, il and 1 or 0, iv and 1 or 0) end
        end
    end
    if geo and not hbLeave and not hbReady and not hbGuestWait then
        -- 11-09 20:26: "SM shown" is not "floor there" (here too): the host was let go at 15.8 s, nothing under him, and fell for good
        -- 20:36: "only partially loaded": every Home Base level shown, too (22 of 22 in the good runs)
        geo = visible >= #hbLevels and hbFloorOk(mine, now, hbAt)
    end
    if hbLeave then
        -- 11-06 14:32: the host "arrived" 3.9 s after leaving Home Base, with no stage there yet, fell, and the guest with him. Ready = the host is at the
        -- target and every level the game asked for has been shown for 1.5 s (the levels are asked for in steps).
        hbLeaveGood = want > 0 and shown == want
        -- 11-07: "the world wasn't fully loaded": the static meshes were, the other forced levels were not
        if hbLeaveGood and hbAskLevels then
            local notYet = 0
            for _, l in ipairs(hbAskLevels) do
                if valid(l) and try(function() return l.bShouldBeVisible end) and not try(function() return l:IsLevelVisible() end) then notYet = notYet + 1 end
            end
            if notYet > 0 then hbLeaveGood = false end
        end
        -- his stage must be there before his character: 11-07 he was spawned a moment too early, fell, was caught 80 units under the floor and stuck in it
        if hbLeaveGood and not hbHostHold and not hbToldHost then
            hbToldHost = fsToHost(11, 0)
            log("hb: leaving, our stage is here, told the host: " .. tostring(hbToldHost))
        end
        if hbLeaveArrived and not hbArrivedAt then
            hbArrivedAt = now
            if hbHostHold then hbSendDest(mine) end
        end
        if hbLeaveArrived and hbLeaveGood and not hbInBase() and not oldChar then
            hbLeaveOk = hbLeaveOk or now
            geo = now - hbLeaveOk >= 2.5 and hbFloorOk(mine, now, hbLeaveOk)
        else hbLeaveOk = nil end
        parts[1] = string.format("leaving: %d of %d stage levels shown", shown, want)
        if hbLeaveArrived or hbDest then pcall(hbLeaveAsk, now, want, mine) end
        if now - hbVolAt > 5 then
            hbVolAt = now
            local on = {}
            for _, v in ipairs(FindAllOf("AppLevelStreamingVolume") or {}) do
                if valid(v) and try(function() return v:IsEitherLevelShouldBeLoaded() end) then on[#on + 1] = name(v) end
            end
            log("hb: leaving, volumes that want their levels: " .. table.concat(on, " "):sub(1, 400))
        end
    end
    local loc = valid(mine) and try(function() return mine:K2_GetActorLocation() end)
    log(string.format("hb: %.1f s, %d loaded, %d visible (should load/should show/loaded/shown) %s | pawn %s z=%s", now - hbAt, loaded, visible, table.concat(parts, " "),
        valid(mine) and name(mine) or "none", loc and string.format("%.0f", loc.Z) or "?"))
    if geo and not hbReady and not hbGuestWait then
        hbReady = true
        hbHover = false
        if hbLeave then
            -- 11-07: straight to walking left them "stuck in the air" at ground height: arrived with no floor, the game never got a landing. Falling gives it one.
            if valid(cm) and try(function() return cm.MovementMode end) == 5 then pcall(function() cm:SetMovementMode(3, 0) end) end
            hbAfterUntil, hbAfterNext = now + 12, 0
            unlockUntil, unlockedPawn = now + 15, nil
        elseif valid(cm) then pcall(function() cm:SetMovementMode(1, 0) end) end
        hbRescueUntil = now + 20
        if hbEntryFade then hbEntryOffAt = now + 3 end   -- everything shown, a floor under us: the screen stays black 3 s more for the rest to come
        do
            local gsr = FindFirstOf("BP_AppGameState_C")
            if hbLeave and valid(gsr) and try(function() return gsr.Role end) ~= 3 then
                fsToHost(13, 0)
                log("hb: told the host our floor is there")
            end
        end
        log("hb: the geometry is there after " .. string.format("%.1f", now - hbAt) .. " s -> walking, the guests can follow")
        local gsb = FindFirstOf("BP_AppGameState_C")
        if not hbLeave and iniHas("hb_base_mode=1") and valid(mine) and valid(gsb) and try(function() return gsb.Role end) ~= 3 then
            local hlp = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
            local ok, e = pcall(function() hlp:SetRestrictedActionInBaseInfo(mine, hbBaseInfo()) end)
            log("hb: Home Base mode on our character -> " .. (ok and "ok" or ("ERROR " .. tostring(e):sub(1, 120))))
            hbApplyLook(hlp, mine)
        end
    end
    if not hbLeave and not hbReady and not hbGuestWait and not hbForced and now - hbAt > 7 then
        hbForced = true
        local n = 0
        for _, e in ipairs(hbLevels) do
            if valid(e.l) and pcall(function() e.l.bShouldBeLoaded = true; e.l.bShouldBeVisible = true end) then n = n + 1 end
        end
        log("hb: nothing after 7 s -> forcing " .. n .. " levels to load")
    end
end
-- Boss killed with the host down (owner 2026-11-06): the game skips MulticastGainRewards and MulticastFinishBossBattle then (logs: both fire
-- only with the host alive at the kill, 2.4 s apart), so call them in the same order. The host's spawned character stayed hidden on his
-- own screen and without input: make it visible and lift the input lock once it is there.
function bossForceTick()
    if not bossForce then return end
    local now = os.clock()
    if bossForce.showAt and now >= bossForce.showAt then
        bossForce.showAt = nil
        local pc = localPC()
        local mine = valid(pc) and try(function() return pc.Pawn end) or nil
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        if valid(mine) then makeVisible(helper, mine, "boss revive:") end
        unlockUntil, unlockedPawn = now + 15, nil
    end
    if bossForce.phase == 1 and now >= bossForce.at then
        bossForce.phase, bossForce.at = 2, now + 2.4
        if now - rewardsAt > 20 then
            local ok, e = pcall(function() bossArea:MulticastGainRewards() end)
            log("boss end: MulticastGainRewards called by us -> " .. (ok and "ok" or ("ERROR " .. tostring(e):sub(1, 120))))
        else log("boss end: the game sent the rewards itself") end
    elseif bossForce.phase == 2 and now >= bossForce.at then
        bossForce.phase = 3
        local ok, e = pcall(function() bossArea:MulticastFinishBossBattle(false) end)
        log("boss end: MulticastFinishBossBattle(false) called by us -> " .. (ok and "ok" or ("ERROR " .. tostring(e):sub(1, 120))))
    end
    if bossForce.phase == 3 and not bossForce.showAt then bossForce = nil end
end
-- Group teleport v1 (group_teleport=1, host; session 9). The host teleports through his Mistle menu as usual; CoopNative notes
-- RequestPlayerSpawnToCheckPoint in CoopNative.teleport. Once the host's new pawn is up (a new pawn, or 8 s at the latest), each
-- guest with a living pawn gets a fresh pawn next to the host (RequestPlayerSpawn with the appear effect, as the group respawn)
-- and his old pawn is removed 5 s later. A guest who is spectating stays so until the host's next rest.
local TELEPORT_PATH = WIN64 .. "\\plugins\\CoopNative.teleport"
do local f = io.open(TELEPORT_PATH, "r"); if f then f:close(); os.remove(TELEPORT_PATH) end end
local pendingTp = nil   -- {at, oldHost, newSeenAt}
-- Post-boss outro (session 9): hand CoopNative the DeferredTeleportDriver objects and the guests' pawns/controllers every 2 s
-- (CoopNative.tpinfo), so its tpdump/tpfree commands work while the host hangs and Lua does not run.
local lastTpInfo, tpInfoAt = nil, -1000
local tpTouchAt = -1000
local function sendTpInfo()
    if os.clock() - tpInfoAt < 2 then return end
    tpInfoAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    -- 2026-10-31: a guest must not have a tpinfo (an old one made his CoopNative act as host)
    if valid(gs) and try(function() return gs.Role end) ~= 3 then
        os.remove(WIN64 .. "\\plugins\\CoopNative.tpinfo"); lastTpInfo = nil
        local rf = io.open(WIN64 .. "\\plugins\\CoopNative.role", "w"); if rf then rf:write("guest"); rf:close() end
        return
    end
    if valid(gs) then os.remove(WIN64 .. "\\plugins\\CoopNative.role") end
    if not valid(gs) then return end
    -- CoopNative ignores a tpinfo older than 2 minutes: rewrite it every 30 s even without a change
    -- (2026-11-03: two freezes while loading came right after this rewrite; only needed with a guest connected)
    local remote = false
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then remote = true end
    end
    if remote and os.clock() - tpTouchAt > 30 then tpTouchAt = os.clock(); lastTpInfo = nil end
    local lines = {}
    for _, d in ipairs(FindAllOf("DeferredTeleportDriver") or {}) do
        local a = valid(d) and try(function() return d:GetAddress() end)
        if a then lines[#lines + 1] = string.format("driver %X", a) end
    end
    local mpc = localPC()
    local mp = valid(mpc) and try(function() return mpc.Pawn end) or nil
    for _, fc in ipairs(FindAllOf("BP_FadeUIComponent_C") or {}) do
        local own = valid(fc) and try(function() return fc:GetOwner() end)
        if valid(own) and valid(mpc) and name(own) == name(mpc) then
            local fa = try(function() return fc:GetAddress() end)
            if fa then lines[#lines + 1] = string.format("fade %X", fa) end
        end
    end
    for _, o in ipairs({ mpc, mp }) do
        local oa = valid(o) and try(function() return o:GetAddress() end)
        if oa then lines[#lines + 1] = string.format("host %X", oa) end
    end
    local mpa = valid(mp) and try(function() return mp:GetAddress() end)
    if mpa then lines[#lines + 1] = string.format("hpawn %X", mpa) end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            local a = try(function() return c:GetAddress() end)
            if a then lines[#lines + 1] = string.format("guest %X", a) end
            local p = try(function() return c.Pawn end)
            local pa = valid(p) and try(function() return p:GetAddress() end)
            if pa then lines[#lines + 1] = string.format("guest %X", pa); lines[#lines + 1] = string.format("gpawn %X", pa) end
            local ps = try(function() return c.PlayerState end)
            local psa = valid(ps) and try(function() return ps:GetAddress() end)
            if psa then lines[#lines + 1] = string.format("guest %X", psa) end
        end
    end
    local text = table.concat(lines, "\n")
    if text == lastTpInfo then return end
    lastTpInfo = text
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.tpinfo", "w"); if f then f:write(text); f:close() end
    log("tp info: " .. #lines .. " line(s) for CoopNative (" .. text:gsub("\n", ", ") .. ")")
end
local function groupTeleport()
    local f = io.open(TELEPORT_PATH, "r")
    if f then
        local what = f:read("*a") or ""; f:close(); os.remove(TELEPORT_PATH)
        if not iniHas("group_teleport=1") then
        elseif what:find("^start") then
            local pc0 = localPC()
            local m0 = valid(pc0) and try(function() return pc0.Pawn end) or nil
            -- 2026-11-02: after the memory the host lands in the final cutscene; a guest spawned next to it there fell and died (no
            -- ground at the cutscene spot). For the memory-end teleport ("start memend") the guests follow only once the host can
            -- move again (cutscene over: move input not ignored for 2 s), up to 3 minutes.
            pendingTp = { at = os.clock(), oldHost = valid(m0) and try(function() return m0:GetAddress() end) or nil, memend = what:find("memend") ~= nil }
            log("group teleport: host teleports, guests follow once the host has arrived")
            if fogQuiet then fogQuiet(90) end
            if hbInBase() then hbLeaveStart() end
        recTeleportDue = true
        lastMistle = nil   -- the last rest may be in another area now: until the next rest he comes back next to the host
            -- item 8 v2: host -> guest message (PlayerController:ClientMessage is a client RPC): the guest fades now, at the start
            for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(c) and not try(function() return c:IsLocalController() end) then
                    pcall(function() c:ClientMessage("CoopFadeMode:" .. (iniHas("tp_loading=1") and "64" or "48"), FName("None"), 0) end)
                    if not pendingTp.memend then pcall(tpMontage, try(function() return c.Pawn end), "start", "group teleport") end
                    local okm = pcall(function() c:ClientMessage("CoopTeleportFade", FName("None"), 0) end)
                    log("group teleport: fade message to " .. name(c) .. " " .. tostring(okm))
                end
            end
        elseif what:find("^arrived") and pendingTp then
            pendingTp.arrivedAt = os.clock()
            hbLeaveArrived = true
            log("group teleport: host's characters re-spawned at the target")
        end
    end
    pcall(tpaHostTick)
    if not pendingTp then return end
    local limit = pendingTp.memend and 300 or 60
    if os.clock() - pendingTp.at > limit then
        if pendingTp.memend and not pendingTp.finishedAt then
            log("group teleport: no finished report within " .. limit .. " s -> bringing the guests anyway")
            pendingTp.finishedAt = os.clock() - 2
        elseif not pendingTp.memend then
            log("group teleport: host did not arrive within " .. limit .. " s, given up"); pendingTp = nil; return
        end
    end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) or try(function() return helper:IsDeath(mine) end) or try(function() return helper:IsDying(mine) end) then return end
    local addr = try(function() return mine:GetAddress() end)
    -- arrived: CoopNative saw the characters re-spawn, and the host's pawn is a new one (the address alone changed during loading)
    local arrived = pendingTp.arrivedAt and addr and addr ~= pendingTp.oldHost
    if not arrived then return end
    pendingTp.newSeenAt = pendingTp.newSeenAt or os.clock()
    if os.clock() - pendingTp.newSeenAt < 3 then return end   -- let the host's area finish loading
    -- Home Base and leaving it: not before the levels are there, or he falls (and a new character while levels stream is the likely cause of the 11-07 08:55 crash)
    if os.clock() < hbUntil and not hbReady then return end
    if hbLeave and not hbGuestStage and os.clock() - pendingTp.newSeenAt < 25 then return end
    if pendingTp.memend then
        -- 2026-11-05: "can move" came 2 s into the final cutscene (it does not block move input): the guest spawned into the host's
        -- cutscene with the join message. The game's own report of the finished scene is the real end.
        if not pendingTp.finishedAt or os.clock() - pendingTp.finishedAt < 2 then return end
        log("group teleport: the final cutscene finished -> bringing the guests")
        memendBring = true
    end
    pendingTp = nil
    -- Home Base (2026-11-06): RequestPlayerSpawn gave his new character a teleport driver that hung for good (state 7, no level to wait for: the
    -- host had already loaded everything), with the host behind a loading screen. Move his existing character instead, as the memory
    -- follow does: no driver. His PC loads Home Base itself; he hovers until his geometry is there (CoopHB -> hbWatch on his side).
    if os.clock() < hbUntil and not hbLeave then
        local hp2 = try(function() return mine:K2_GetActorLocation() end)
        local hr2 = try(function() return mine:K2_GetActorRotation() end)
        local right2 = try(function() return mine:GetActorRightVector() end)
        for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
            local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end) or nil
            if valid(g) and hp2 and right2 then
                local to = { X = hp2.X + right2.X * 150, Y = hp2.Y + right2.Y * 150, Z = hp2.Z + 5 }
                pcall(function() c:ClientMessage(string.format("CoopHBAt:%.1f,%.1f,%.1f", to.X, to.Y, to.Z), FName("None"), 0) end)
                local ok, moved = pcall(function() return g:K2_TeleportTo(to, hr2 or { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                log("hb: " .. name(g) .. " moved next to the host (no new character) -> " .. tostring(ok) .. ", answer " .. tostring(moved))
                hbRelease = os.clock() + 2
                -- (11-06 09:10: with this the host stayed on a loading screen and the guest floated; off until understood)
                if iniHas("hb_base_mode=1") then
                    local okb, eb = pcall(function() helper:SetRestrictedActionInBaseInfoHost(g, hbBaseInfo()) end)
                    log("hb: Home Base mode on " .. name(g) .. " -> " .. (okb and "ok" or ("ERROR " .. tostring(eb):sub(1, 120))))
                    hbApplyLook(helper, g)
                end
            end
        end
        return
    end
    -- by remote controller: right after the teleport the host's old pawn still exists and was taken for a guest (spawned twice)
    local n = 0
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            local p = try(function() return c.Pawn end)
            local isPlayer = valid(p) and name(p):find("BP_Player_C", 1, true) ~= nil
            if isPlayer and not try(function() return helper:IsDeath(p) end) then
                -- leaving Home Base (owner 11-07): he went through the spawn effect twice; he is behind his fade there, which then lifts from black
                if respawnGuest(helper, p, mine, not hbLeave and not iniHas("tp_anim=1")) then
                    oldPawns[#oldPawns + 1] = { p = p, n = name(p), at = os.clock() }
                    n = n + 1
                end
            elseif not isPlayer and memendBring then
                -- 2026-11-05: at the end of the final cutscene his character was gone ("0 guests brought") and he stayed out of bounds until
                -- the host's rest: the spawn works from the controller alone, as at a rest
                log("group teleport: guest has no character -> spawning him next to the host")
                if respawnGuest(helper, nil, mine, true) then n = n + 1 end
            end
        end
    end
    log("group teleport: " .. n .. " guest(s) brought to the host")
    if n > 0 and iniHas("tp_anim=1") then
        tpaWatch = { at = os.clock(), old = {}, due = {} }
        for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
            local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end)
            local a = valid(g) and try(function() return g:GetAddress() end)
            if a then tpaWatch.old[a] = true end
        end
    end
    if hbLeave then hbBrought, hbBroughtAt, hbGuestFloor = true, os.clock(), false end
    memendBring = false
end
-- memory state on the host (set by the scene relay): memHostOn while the memory runs; memFollowAt = a host skip to follow;
-- memRespawnAt = a guest character removed during the memory, to be spawned again next to the host
local memHostOn, memFollowAt, memRespawnAt = false, nil, nil
local memWalkSince = nil
local function keepDying(rested)
    local list = {}
    local gs = FindFirstOf("BP_AppGameState_C")
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local sm = FindFirstOf("AppSessionManager")
    local isHost = valid(gs) and try(function() return gs.Role end) == 3
    local function alive(p) return valid(p) and not try(function() return helper:IsDeath(p) end) and not try(function() return helper:IsDying(p) end) end
    if not iniHas("boss_keep=0") and valid(gs) and try(function() return gs.BossAreaState end) == 2 and valid(sm) and try(function() return sm:IsOnlineMultiplay(gs) end) then
        local ps = {}
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do if valid(p) then ps[#ps + 1] = p end end
        for _, p in ipairs(ps) do
            local otherAlive = false
            for _, q in ipairs(ps) do if q ~= p and name(q) ~= name(p) and alive(q) then otherAlive = true end end
            local a = try(function() return p:GetAddress() end)
            if a and otherAlive then list[#list + 1] = string.format("%X", a) end
        end
    end
    if iniHas("keep_dying=1") and valid(gs) and valid(sm) and try(function() return sm:IsOnlineMultiplay(gs) end)
        and valid(mine) and name(mine):find("BP_Player_C", 1, true) then
        local others = {}
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
            if valid(p) and name(p) ~= name(mine) then others[#others + 1] = p end
        end
        if isHost then
            if alive(mine) then
                for _, p in ipairs(others) do
                    local a = try(function() return p:GetAddress() end)
                    if a then list[#list + 1] = string.format("%X", a) end
                    local vz = try(function() return p:GetVelocity().Z end)
                    if a and type(vz) == "number" and vz < -1200 then guestFallAt[a] = os.clock() end
                end
            end
        else
            local hostAlive, hostPawn = false, nil
            for _, p in ipairs(others) do if alive(p) then hostAlive, hostPawn = true, p end end
            local a = try(function() return mine:GetAddress() end)
            if hostAlive and a then list[#list + 1] = string.format("%X", a) end
            -- a new pawn after the host's respawn: clear our true-death marker
            local tdm = trueDeadAddr()
            if tdm and a and tdm ~= a and alive(mine) then
                sawOwnTrueDeath = false
                local f = io.open(TRUEDEAD_PATH, "w"); if f then f:write("0"); f:close() end
                log("keep dying: new pawn after a true death, marker cleared")
            end
            -- revived after a true death (the host rested): our game moves our own pawn, so teleport next to the host here
            local td = trueDeadAddr()
            if td and td == a and alive(mine) and valid(hostPawn) then
                local ok = pcall(function()
                    local loc = hostPawn:K2_GetActorLocation()
                    local rot = hostPawn:K2_GetActorRotation()
                    local right = hostPawn:GetActorRightVector()
                    mine:K2_TeleportTo({ X = loc.X + right.X * 150, Y = loc.Y + right.Y * 150, Z = loc.Z + 50 }, { Pitch = 0, Yaw = rot.Yaw, Roll = 0 })
                end)
                local f = io.open(WIN64 .. "\\plugins\\CoopNative.truedead", "w")
                if f then f:write("0"); f:close() end
                log("keep dying: revived after a true death -> teleport next to the host " .. (ok and "ok" or "FAILED"))
                makeVisible(helper, mine, "guest")
            end
        end
    end
    if isHost then
        pcall(fsHostIn)   -- the guest's "menu open" (kind 15) comes this way, also outside Home Base
        if hostGuestMenuAt and os.clock() - hostGuestMenuAt < 600 then
            for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
                local a = valid(p) and p ~= mine and try(function() return p:GetAddress() end)
                if a and a ~= try(function() return mine:GetAddress() end) then
                    local s = string.format("%X", a)
                    for i = #list, 1, -1 do if list[i] == s then table.remove(list, i) end end
                    table.insert(list, 1, s)
                end
            end
        end
    end
    if not isHost and guestMenuOpenAt and os.clock() - guestMenuOpenAt < 600 and valid(mine) then
        local a = try(function() return mine:GetAddress() end)
        if a then
            local s = string.format("%X", a)
            for i = #list, 1, -1 do if list[i] == s then table.remove(list, i) end end
            table.insert(list, 1, s)
        end
    end
    local line = #list > 0 and table.concat(list, " ") or "0"
    if line ~= lastProtect then
        local f = io.open(WIN64 .. "\\plugins\\CoopNative.protect", "w")
        if f then f:write(line); f:close() end
        lastProtect = line
        log("keep dying: protect " .. line)
    end
    -- remove dissolved pawns a few seconds after their replacement was spawned
    for i = #oldPawns, 1, -1 do
        local e = oldPawns[i]
        if os.clock() - e.at > 5 then
            if valid(e.p) then
                local ok = pcall(function() e.p:K2_DestroyActor() end)
                log("keep dying: removed the dissolved " .. e.n .. " " .. (ok and "ok" or "FAILED"))
            end
            table.remove(oldPawns, i)
        end
    end
    -- host: after a true death the dying pawn could still be revived by the partner (IsNeverRevive is not asked, session 8) and it
    -- has dissolved anyway: remove it 3 s after the true death; the guest spectates without a pawn until our next rest
    local td, tdSrc = trueDeadAddr()
    if not td then tdSeen = {} end
    if isHost and td and line ~= "0" then
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
            local a = valid(p) and name(p) ~= name(mine) and try(function() return p:GetAddress() end)
            if a and a == td then
                -- 2026-10-28 10:44: Io revived him 2 s after the true death and the removal (then 3 s) deleted his living, controlled
                -- pawn: his game crashed. Remove only a pawn that is still down, almost at once, and detach his controller first.
                local down = try(function() return helper:IsDying(p) end) or try(function() return helper:IsDeath(p) end)
                local st = tdSeen[a]
                if not st then st = { at = os.clock(), down = down }; tdSeen[a] = st end
                local function cancel(why)
                    tdSeen[a] = nil
                    local f = io.open(TRUEDEAD_PATH, "w"); if f then f:write("0"); f:close() end
                    log("keep dying: " .. name(p) .. " " .. why)
                end
                -- session 9: a death request while standing (source T) is an enemy hit (he goes down right after; his true death
                -- comes when the revive window runs out) or a fall (vanilla kills at once; the veto left him standing at the bottom)
                local fall = false
                if tdSrc == "T" then
                    -- a fall only if we saw him falling fast just before; a hit that takes longer to put him down waits
                    local fell = guestFallAt[a] and st.at - guestFallAt[a] < 4
                    -- a fall can also leave him down (session 9: Io revived him in a pit), so after a fast fall "down" is a fall
                    -- death too, at once; standing, wait 1.5 s as before
                    if down and not fell then cancel("went down after the hit; true death when his revive window runs out")
                    elseif fell and (down or st.dissolveAt or os.clock() - st.at > 1.5) then
                        -- owner, session 9: vanishing on impact looked wrong; play the game's dissolve first (both PCs), then remove
                        if not st.dissolveAt then
                            st.dissolveAt = os.clock()
                            -- (2026-10-30: Death:Multicast_MigrationToDeath(true) here changed nothing visible on the guest and
                            --  made his pawn count as revived -> no removal, no respawn at the host's rest; removed again)
                            local okd = pcall(function() p:Multicast_SetEnableDisappearExpression(true) end)
                            log("keep dying: fall death of " .. name(p) .. " -> dissolve " .. tostring(okd) .. ", body removed in 2.5 s")
                        elseif os.clock() - st.dissolveAt > 2.5 then fall = true end
                    elseif not fell and os.clock() - st.at > 10 then cancel("death request without going down or falling; ignored") end
                elseif not down then
                    cancel("was revived before the body was removed; true death cancelled")
                end
                if fall or (tdSrc ~= "T" and tdSeen[a] and down and st.down) then
                    if fall or os.clock() - st.at > 0.5 then
                        local un = false
                        for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                            if valid(c) and not try(function() return c:IsLocalController() end) and try(function() return name(c.Pawn) end) == name(p) then
                                un = pcall(function() c:UnPossess() end)
                            end
                        end
                        local ok = pcall(function() p:K2_DestroyActor() end)
                        log("keep dying: " .. (fall and "fall death" or "true death") .. " of " .. name(p) .. " -> unpossess " .. tostring(un) .. ", body removed " .. (ok and "ok" or "FAILED") .. "; back on the host's next rest")
                        pendingRespawn = true
                        -- 2026-11-03: during the memory a follow teleport landed him over no ground (the host was still moving to the
                        -- next part), he died and stayed "gone" until a rest: in the memory he is spawned next to the host again
                        if memHostOn then memRespawnAt = os.clock() + 3; log("keep dying: in the memory -> respawn next to the host in 3 s") end
                        tdSeen[a] = nil
                        local f = io.open(TRUEDEAD_PATH, "w"); if f then f:write("0"); f:close() end
                    end
                end
            end
        end
    end
    if rested and isHost and pendingRespawn and valid(mine) then
        pendingRespawn = false
        respawnGuest(helper, nil, mine, true)
        local f = io.open(TRUEDEAD_PATH, "w"); if f then f:write("0"); f:close() end
    end
    if not rested or not isHost or line == "0" then return end
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        -- a guest whose revive window ran out has dissolved (a material effect that the flags do not undo, session 8): give him a
        -- fresh pawn next to us with the game's appear sequence (owner's idea), like loading in; his death sequence never started
        -- (keep_dying), so the input lock that broke this route before should not come back
        if valid(p) and name(p) ~= name(mine) and td and td == try(function() return p:GetAddress() end) then
            respawnGuest(helper, p, mine, true)
            oldPawns[#oldPawns + 1] = { p = p, n = name(p), at = os.clock() }
            local f = io.open(TRUEDEAD_PATH, "w"); if f then f:write("0"); f:close() end
        elseif valid(p) and name(p) ~= name(mine) and try(function() return helper:IsDying(p) end) then
            local max = try(function() return helper:GetMaxHealth(p) end)
            local ok = type(max) == "number" and pcall(function() helper:SetHealth(p, max) end)
            local tp = pcall(function()
                local loc = mine:K2_GetActorLocation()
                local rot = mine:K2_GetActorRotation()
                local right = mine:GetActorRightVector()
                p:K2_TeleportTo({ X = loc.X + right.X * 150, Y = loc.Y + right.Y * 150, Z = loc.Z + 50 }, { Pitch = 0, Yaw = rot.Yaw, Roll = 0 })
            end)
            log("keep dying: host rested -> " .. name(p) .. " set to full health (" .. tostring(max) .. ") " .. (ok and "ok" or "FAILED") .. ", teleport " .. (tp and "ok" or "FAILED"))
            makeVisible(helper, p, "host")
        end
    end
end

-- Names for the native trace (trace_death=1): CoopNative logs only object/class addresses. Every 10 s log the addresses of the
-- objects that appear in a death (fade component, controllers, player pawns) and of their classes, when they change.
local lastWho = ""
local function whoIsWho()
    if not iniHas("trace_death=1") then return end
    local parts = {}
    for _, cls in ipairs({ "BP_FadeUIComponent_C", "ActionPlayerController_C", "BP_Player_C", "WDT_FadeScreen_C", "WDT_DeathParts_C" }) do
        for _, o in ipairs(FindAllOf(cls) or {}) do
            if valid(o) then
                local a = try(function() return o:GetAddress() end)
                local c = try(function() return o:GetClass():GetAddress() end)
                if a then parts[#parts + 1] = string.format("%s=0x%X(class 0x%X)", name(o), a, c or 0) end
            end
        end
    end
    local line = table.concat(parts, " ")
    if line ~= lastWho then lastWho = line; log("WHO " .. line) end
end
local whoTick = 0

-- R6 (guest rest): open the Mistle menu without the vanilla rest, which changes the Mistle actor and asserted on a guest
-- (CheckPointBase.cpp:850). Command file plugins\\CoopProbe.cmd, read every 0.2 s and deleted: "openmenu" (Open), "openmenu2"
-- (OpenTopMenu), "closemenu". Used first to validate on the host, solo.
local PROBE_CMD = WIN64 .. "\\plugins\\CoopProbe.cmd"
local function checkpointMenuClass()
    local path = "/Game/UserInterface/CheckPointMenu/WDT_CheckpointMenu.WDT_CheckpointMenu_C"
    local cls = StaticFindObject(path)
    if not valid(cls) then pcall(function() cls = LoadAsset(path) end) end
    return valid(cls) and cls or nil
end
local function openCheckpointMenu(variant)
    local cp = FindFirstOf("BP_CheckpointUIComponent_C")
    local cls = checkpointMenuClass()
    if not valid(cp) then log("menu: no BP_CheckpointUIComponent_C"); return false end
    local none = FName("None")
    local ok, r
    if variant == 2 then
        ok, r = pcall(function() return cp:OpenTopMenu(FName("CheckPointRootMenu"), cls, 0, true, none, none, 0, "", 0) end)
    else
        ok, r = pcall(function() return cp:Open(none, none, 0, none, cls) end)
    end
    log("menu: " .. (variant == 2 and "OpenTopMenu" or "Open") .. " on " .. name(cp) .. " (class " .. tostring(cls and name(cls)) .. ") -> " ..
        (ok and ("returned " .. tostring(r)) or ("ERROR " .. tostring(r):sub(1, 140))))
    return ok and r
end
-- Guest rest (guest_rest=1): CoopNative skipped the vanilla rest on our E press and wrote CoopNative.restreq; open our Mistle
-- menu and try to refill our health (the host owns it; logged whether it sticks).
local RESTREQ = WIN64 .. "\\plugins\\CoopNative.restreq"
local healCheck
local menuWatch, lastMenuState, menuClosedAt = false, nil, nil   -- declared before guestRestRequest sets it (a later local was a different variable)
-- Entries of the guest's Mistle menu that must not be used (owner, session 8): switching partners put him on a permanent loading
-- screen, and a teleport would pull him away from the host (group teleport with a vote comes later). Their widgets, in screen order:
-- PieceLevelup, PieceLernKetsugi, ..._C_2 storage, ..._C_3 teleport, ..._C_7 switch partner, ..._C_4 presents, PieceTutorialStart,
-- PieceQuitGame. Disabled for 3 s after the menu opens (the menu may set its entries while opening).
local GUEST_MENU_DISABLED = { ["WDT_CommonListTextPiece_C_7"] = "switch partner" }   -- teleport stays open for the later vote
local disableUntil, disabledLogged = 0, false
local function disableGuestMenuEntries()
    if os.clock() > disableUntil then return end
    for _, w in ipairs(FindAllOf("WDT_CommonListTextPiece_C") or {}) do
        local n = valid(w) and name(w)
        local full = n and GUEST_MENU_DISABLED[n] and try(function() return w:GetFullName() end) or ""
        if full:find("Transient", 1, true) and full:find("WDT_CheckpointMenu_C", 1, true) then
            pcall(function() w:SetIsEnabled(false) end)
            if not disabledLogged then log("guest rest: menu entry " .. GUEST_MENU_DISABLED[n] .. " disabled"); disabledLogged = true end
        end
    end
end
-- Item 8 (2026-10-30): group teleport fade on the guest. When the host's character is replaced while it was alive (the host
-- teleported; his characters are re-spawned at the target) and the new one stands more than 30 m from the old spot (cutscenes and
-- the memory also re-spawn him, but close by) our screen gets the game's teleport fade, lifted once our own character
-- has been replaced too (group respawn next to the host), 1.5 s later, or after 25 s. CoopNative runs it on the game thread.
local tpfHost, tpfHostAlive, tpfMine, tpfOnAt, tpfMineAt = nil, false, nil, nil, nil
local tpfHostPos, tpfWaitFrom, tpfWaitAt = nil, nil, nil   -- (unused since v2)
-- v2 (owner 21:1x: the fade came only after the jank, and once his screen went dark for 5 s while standing): the host sends
-- ClientMessage("CoopTeleportFade") at the start of its teleport; the distance trigger is gone
local tpfMessageAt = nil
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text == "CoopTeleportFade" then tpfMessageAt = os.clock() end
    end)
end)
local function tpfadeSend(ctx, on)
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if not c then return false end
    c:write(string.format("tpfade %X %d%s\n", ctx, on and 1 or 0, tpUsageArg())); c:close()
    return true
end
-- 2026-11-05: at the final cutscene his scene started on time, but under this fade, which lifted only when his new character stood
-- next to the host, 6 s later (owner: "not synced"). The game's own reports say when the scene starts: lift the fade when both are in.
tpfReady = {}
pcall(function()
    RegisterHook("/Script/Extensions.ScenarioPlayerComponent:MulticastSetReadyToPlay", function(ctx, b)
        local v = try(function() return b:get() end)
        if v ~= nil then tpfReady[v and "host" or "guest"] = true end
    end)
end)
local function guestTeleportFade()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) == 3 then return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local mineName = valid(mine) and name(mine) or nil
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local host
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and name(p) ~= mineName then host = p end
    end
    local hostName = valid(host) and name(host) or nil
    if tpfOnAt then
        if mineName and mineName ~= tpfMine and not tpfMineAt then tpfMineAt = os.clock() end
        local scene = (tpfReady.host and tpfReady.guest) or (hbReady and os.clock() < hbUntil)
        local leaving = hbLeave and os.clock() < hbUntil and not (hbReady and tpfMineAt and os.clock() - tpfMineAt > 1.5)
        local entering = hbEnterAt and os.clock() - hbEnterAt < 40 and not (hbReady and hbPlacedAt and os.clock() - hbPlacedAt > 1)
        if not entering then hbEnterAt = nil end
        leaving = leaving or entering
        local done = not leaving and (scene or (tpfMineAt and os.clock() - tpfMineAt > 1.5) or os.clock() - tpfOnAt > 25)
        local held = valid(mine) and try(function() return mine.CharacterMovement.MovementMode end) == 5
        if done and held and not (tpfReady.host and tpfReady.guest) and os.clock() - tpfOnAt < 40 then
            done = false
            if not tpfHeldLogged then tpfHeldLogged = true; log("teleport fade: still held in the air -> the screen stays covered until we are let go") end
        end
        if not done then tpfHeldLogged = tpfHeldLogged and held end
        local inFlow = hbFlowAt and math.abs(hbFlowAt - tpfOnAt) < 15
        if done and inFlow and not (hbFreeAt and hbFreeAt > hbFlowAt) and os.clock() - tpfOnAt < 40 then
            done = false
            if not tpfFreeLogged then tpfFreeLogged = true; log("teleport fade: waiting until the host lets us go") end
        end
        local ctx = valid(mine) and try(function() return mine:GetAddress() end)
        if not ctx and valid(pc) then ctx = try(function() return pc:GetAddress() end) end
        if done and ctx and tpfadeSend(ctx, false) then
            pcall(tpMontage, mine, "finish", "our screen comes back")
            log("teleport fade: lifted (" .. (scene and "both games ready, the scene starts" or (tpfMineAt and "our new character is next to the host" or "timeout")) .. ")")
            tpfOnAt, tpfMineAt = nil, nil
        end
    elseif tpfMessageAt then
        local ctx = valid(mine) and try(function() return mine:GetAddress() end)
        if os.clock() - tpfMessageAt > 5 then tpfMessageAt = nil
        elseif ctx and tpfadeSend(ctx, true) then
            log("teleport fade: host's message -> fade")
            pcall(tpMontage, mine, "start", "the host teleports")
            tpfOnAt, tpfMine, tpfMessageAt = os.clock(), mineName, nil
            tpfReady = {}
            tpfFreeLogged = nil
        end
    elseif false then
        if tpfHost and tpfHostAlive and hostName ~= tpfHost and tpfHostPos and not tpfWaitAt then
            tpfWaitFrom, tpfWaitAt = tpfHostPos, os.clock()
        end
        if tpfWaitAt then
            local pos = valid(host) and try(function() return host:K2_GetActorLocation() end)
            if pos then
                local dx, dy, dz = pos.X - tpfWaitFrom.X, pos.Y - tpfWaitFrom.Y, pos.Z - tpfWaitFrom.Z
                local far = dx * dx + dy * dy + dz * dz > 3000 * 3000
                local ctx = valid(mine) and try(function() return mine:GetAddress() end)
                if not far then tpfWaitAt = nil
                elseif ctx and tpfadeSend(ctx, true) then
                    log(string.format("teleport fade: host character replaced by %s %.0f m away -> fade", tostring(hostName),
                        math.sqrt(dx * dx + dy * dy + dz * dz) / 100))
                    tpfOnAt, tpfMine, tpfWaitAt = os.clock(), mineName, nil
                end
            elseif os.clock() - tpfWaitAt > 8 then tpfWaitAt = nil end
        end
    end
    tpfHost = hostName
    local hp = valid(host) and try(function() return host:K2_GetActorLocation() end)
    if hp then tpfHostPos = { X = hp.X, Y = hp.Y, Z = hp.Z } end
    tpfHostAlive = valid(host) and not try(function() return helper:IsDeath(host) end) and not try(function() return helper:IsDying(host) end)
end

-- Scene relay (2026-10-30, after the Lies of P study): CoopNative appends every RequestEvent / RequestSkipEvent to
-- CoopNative.relay. Host: each line goes to the guests as ClientMessage("CoopEvent:<class>|<actor>|<event>") / ("CoopSkip").
-- Guest: his own lines are remembered (an event his game already ran is not run again); with scene_relay=1 a received event is
-- run on the actor of the same class and name (placed level actors have the same names on both PCs) and a skip is pressed on his
-- skip prompt. Without scene_relay=1 he only logs what arrives.
local relayErr = false
-- 2026-11-02 (owner): a host skip inside the memory moves the host to the next memory part; the guest stayed behind. While the
-- memory runs, a host skip pulls every guest character next to the host (K2_TeleportTo, server side; 2.5 s and 5 s after it).
function baseOf(q)
    local bm = try(function() return q.BasedMovement end)
    local b = bm and try(function() return bm.MovementBase end)
    if not valid(b) then return "none" end
    local o = try(function() return b:GetOwner() end)
    return name(b) .. "@" .. (valid(o) and name(o) or "?")
end
memBaseLogUntil, memBaseLogAt = -1000, -1000
function memoryBaseLog()
    if os.clock() > memBaseLogUntil or os.clock() - memBaseLogAt < 3 then return end
    memBaseLogAt = os.clock()
    for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(q) then
            local loc = try(function() return q:K2_GetActorLocation() end)
            local cm = try(function() return q.CharacterMovement end)
            log(string.format("memory base: %s role=%s z=%s moveMode=%s base=%s", name(q), tostring(try(function() return q.Role end)),
                tostring(loc and math.floor(loc.Z)), tostring(valid(cm) and try(function() return cm.MovementMode end)), baseOf(q)))
        end
    end
end
local function memoryFollow()
    local pc = localPC()
    local host = valid(pc) and try(function() return pc.Pawn end) or nil
    local hcm = valid(host) and try(function() return host.CharacterMovement end)
    local walking = valid(hcm) and try(function() return hcm.MovementMode end) == 1
    -- 2026-11-03: pulling him over 2.5 s after a skip put him next to the host while the host was still moving to the next memory
    -- part (no ground there): he fell and died. Now the host must stand on ground for 2 s first (up to 20 s after the skip).
    if walking then memWalkSince = memWalkSince or os.clock() else memWalkSince = nil end
    -- (owner 2026-11-03: faster; 2 s -> 0.75 s. A landing over no ground is caught by the memory respawn above)
    local steady = memWalkSince and os.clock() - memWalkSince >= 0.75
    if memRespawnAt and os.clock() > memRespawnAt and steady and memHostOn then
        memRespawnAt = nil
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        if respawnGuest(helper, nil, host, false) then pendingRespawn = false end
    end
    if not memFollowAt then return end
    local dt = os.clock() - memFollowAt
    if dt > 20 then memFollowAt = nil; return end
    if not steady then return end
    local hp = try(function() return host:K2_GetActorLocation() end)
    local hr = try(function() return host:K2_GetActorRotation() end)
    if not hp then return end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local g = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end)
        local gp = valid(g) and try(function() return g:K2_GetActorLocation() end)
        if gp then
            local dx, dy, dz = gp.X - hp.X, gp.Y - hp.Y, gp.Z - hp.Z
            if dx * dx + dy * dy + dz * dz > 3000 * 3000 then   -- (10 m pulled him back while he walked nearby)
                local to = { X = hp.X + 150, Y = hp.Y + 150, Z = hp.Z + 50 }
                local ok = pcall(function() g:K2_TeleportTo(to, hr or { Pitch = 0, Yaw = 0, Roll = 0 }) end)
                log(string.format("memory follow: %s was %.0f m from the host (host on ground) -> teleported next to the host %s", name(g),
                    math.sqrt(dx * dx + dy * dy + dz * dz) / 100, tostring(ok)))
            end
        end
    end
    memFollowAt = nil
end
-- Special-mode reset (2026-11-02/03). After the memory his character kept FieldType 3 (memory mode: weapon hidden; his own
-- memory flow does not end normally) -> no weapon. Each player character is checked once, 4 s after it appears: outside Home
-- Base and outside the memory window every special mode (FCharacterRestrictedActionInBaseInfo) is cleared.
-- (The earlier veil-mesh logging and forced veil visibility are gone: the hidden veil was the brother's game setting, and forcing
--  it visible overrode that setting.)
veilSeen = {}
function veilWatch()
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        local n = valid(p) and name(p)
        if n and not veilSeen[n] then veilSeen[n] = os.clock()
        elseif n and veilSeen[n] ~= true and os.clock() - veilSeen[n] > 4 then
            veilSeen[n] = true
            local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
            local out = {}
            pcall(function() helper:GetRestrictedActionInBaseInfo(p, out) end)
            local info = out.OutInfo or out
            local ft = try(function() return info.FieldType end)
            local fm = FindFirstOf("AppFieldManager")
            local inBase = valid(fm) and try(function() return fm:IsInHideout(fm) end)
            local gmf = io.open(WIN64 .. "\\plugins\\CoopNative.guestmem", "r")
            local inMemory = gmf and ((gmf:read("*a") or ""):match("1") ~= nil) or false
            if gmf then gmf:close() end
            -- the window file exists only on the guest; on the host memHostOn = the host's memory runs (relay memstart..memend)
            if memHostOn then inMemory = true end
            if ft and ft ~= 0 and inBase ~= true and not inMemory then
                local gs = FindFirstOf("BP_AppGameState_C")
                local isHost = valid(gs) and try(function() return gs.Role end) == 3
                local mine = try(function() return localPC().Pawn end)
                local own = valid(mine) and name(mine) == n
                local a = own and pcall(function() helper:ClearRestrictedActionInBaseInfo(p) end)
                local b = isHost and pcall(function() helper:ClearRestrictedActionInBaseInfoHost(p) end)
                log("special mode: " .. n .. " had mode " .. tostring(ft) .. " in the field -> cleared (own " .. tostring(a) .. ", host " .. tostring(b) .. ")")
            end
        end
    end
end
-- 2026-11-05: the guest was only pulled along on a skip; when a scene in the memory ended by itself he stayed behind. The game's own
-- report of a finished scene starts the same follow.
pcall(function()
    RegisterHook("/Script/Extensions.ScenarioPlayerComponent:MulticastSetReadyToFinish", function(ctx, b)
        if try(function() return b:get() end) ~= true then return end   -- bHost: the guest's report must not count as the host's scene end
        if memHostOn then memFollowAt = os.clock() end
        if pendingTp and pendingTp.memend and not pendingTp.finishedAt then pendingTp.finishedAt = os.clock() end
    end)
end)
local RELAY_PATH = WIN64 .. "\\plugins\\CoopNative.relay"
os.remove(RELAY_PATH)
local relayAt, localEvents, relayIn = -1000, {}, {}
local function fnameText(idx, num)
    local ok, s = pcall(function() return FName(idx):ToString() end)
    if not ok or not s then return nil end
    if num and num > 0 then s = s .. "_" .. (num - 1) end
    return s
end
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text and (text == "CoopSkip" or text == "CoopMemoryStart" or text == "CoopMemoryEnd" or text:find("^CoopEvent:")) then relayIn[#relayIn + 1] = text end
    end)
end)
local function sceneRelay()
    if os.clock() - relayAt < 0.2 then return end
    relayAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    local isHost = valid(gs) and try(function() return gs.Role end) == 3
    local work = RELAY_PATH .. ".work"
    if os.rename(RELAY_PATH, work) then
        local f = io.open(work, "r")
        local lines = {}
        if f then for l in f:lines() do lines[#lines + 1] = l end; f:close() end
        os.remove(work)
        for _, l in ipairs(lines) do
            local msg
            if l == "skip" then msg = "CoopSkip"; if isHost and memHostOn then memFollowAt = os.clock() end
            elseif l == "memstart" then msg = "CoopMemoryStart"; memHostOn = true; memBaseLogUntil = os.clock() + 60
            elseif l == "memend" then msg = "CoopMemoryEnd"; memHostOn = false; memFollowAt = nil
            else
                local ni, nn, ci, ev = l:match("^event (%-?%d+) (%-?%d+) (%-?%d+) (.+)$")
                if ev then
                    local actor = fnameText(tonumber(ni), tonumber(nn)) or "?"
                    local cls = fnameText(tonumber(ci), 0) or "?"
                    msg = "CoopEvent:" .. cls .. "|" .. actor .. "|" .. ev
                    localEvents[ev] = os.clock()
                end
            end
            if msg and isHost then
                for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                    if valid(c) and not try(function() return c:IsLocalController() end) then
                        pcall(function() c:ClientMessage(msg, FName("None"), 0) end)
                    end
                end
                log("scene relay: sent " .. msg)
            elseif msg then
                log("scene relay: own " .. msg)
            end
        end
    end
    if isHost or #relayIn == 0 then relayIn = {}; return end
    local on = iniHas("scene_relay=1")
    for _, text in ipairs(relayIn) do
        if text == "CoopMemoryStart" or text == "CoopMemoryEnd" then
            postBossUntil = os.clock() + 300
            if text == "CoopMemoryStart" then memBaseLogUntil = os.clock() + 60 end
            -- 2026-10-31: his own memory never started (his game was still in its outro when the host's memory pulled him in), so
            -- the memory window comes from the host now: guestMemoryControl unlocks his input on every new character
            local mf = io.open(WIN64 .. "\\plugins\\CoopNative.guestmem", "w")
            if mf then mf:write(text == "CoopMemoryStart" and "1" or "0"); mf:close() end
            log("scene relay: host says " .. text)
        elseif text == "CoopSkip" then
            local comp = FindFirstOf("SkipEventUIComponent")
            if on and valid(comp) then local af = io.open(WIN64 .. "\\plugins\\CoopNative.allowskip", "w"); if af then af:write("1"); af:close() end end
            local ok = on and valid(comp) and pcall(function() comp:RequestSkipEvent() end)
            log("scene relay: host skipped -> " .. (on and ("skip " .. tostring(ok)) or "logged only (scene_relay off)"))
        else
            local cls, actorName, ev = text:match("^CoopEvent:([^|]*)|([^|]*)|(.+)$")
            local seen = ev and localEvents[ev] and os.clock() - localEvents[ev] < 20
            if not on or seen then
                log("scene relay: host event " .. tostring(ev) .. " on " .. tostring(actorName) .. (seen and " (already ran here)" or " (logged only)"))
            else
                local target
                for _, a in ipairs(FindAllOf(cls) or {}) do if valid(a) and name(a) == actorName then target = a end end
                local lib = StaticFindObject("/Script/Extensions.Default__ScenarioFunctionLibrary")
                local ok, err = false, "no actor " .. tostring(actorName)
                if valid(target) and valid(lib) then ok, err = pcall(function() lib:RequestEvent(target, ev) end) end
                localEvents[ev] = os.clock()
                log("scene relay: host event " .. ev .. " on " .. tostring(actorName) .. " -> " .. (ok and "run" or ("NOT run: " .. tostring(err):sub(1, 100))))
            end
        end
    end
    relayIn = {}
end

-- memory step (a): on the guest, tell CoopNative our own pawn (every 2 s, on change) so it can release our held memory flow once the
-- host brings us back after the memory
local lastMyPawn, myPawnAt = nil, -1000
local function writeMyPawn()
    if os.clock() - myPawnAt < 2 then return end
    myPawnAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) == 3 then return end
    local pc = localPC()
    local p = valid(pc) and try(function() return pc.Pawn end) or nil
    local a = valid(p) and try(function() return p:GetAddress() end) or nil
    if a and a ~= lastMyPawn then
        lastMyPawn = a
        local f = io.open(WIN64 .. "\\plugins\\CoopNative.mypawn", "w"); if f then f:write(string.format("%X", a)); f:close() end
    end    -- 2026-11-02: in the memory the HOST's character also floated on this PC until the first skip (it was not started here either);
    -- hand every player character to CoopNative (CoopNative.pawns), whose guest-side v5 checks them all during the memory
    local list = {}
    for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
        local qa = valid(q) and try(function() return q:GetAddress() end)
        if qa then list[#list + 1] = string.format("%X", qa) end
    end
    local pf = io.open(WIN64 .. "\\plugins\\CoopNative.pawns", "w"); if pf then pf:write(table.concat(list, " ")); pf:close() end
end
-- NPC census (2026-11-03): the guest saw story NPCs that should not be there (both saves identical). Both PCs log the NPC-like
-- characters that exist (not players; names with NPC/Npc/Talk/Scenario), with their network role (3 = created on this PC,
-- 1 = replicated from the host) and position: 20 s after joining / after our character changed (teleport, respawn), and
-- every 2 minutes in a session. No component walks (FindAllOf + GetOwner crashed UE4SS before).
npcAt, npcPawn, npcPawnAt = -1000, nil, nil
-- Visibility mirror (2026-11-03, census: the NPCs are the host's replicated actors with the same names on both PCs, but after the
-- boss the host hid BP_ScenarioChara_St09_Cyllene_14 / _Nicolas_92 and the guest still showed them; the fog wall came back on
-- the guest after a rest). The host sends the hidden state of story NPCs and mist/boss walls (by name) whenever it changes or a
-- guest joins: ClientMessage "CoopVis:<name>=<0|1>;..."; the guest applies SetActorHiddenInGame and the collision to the actor
-- with that name.
WALL_CLASSES = {"BP_MistWall_C", "BP_MistWall_St07_C"}
-- v2 (2026-11-03 test): bHidden was the wrong state. Mist walls are local level actors (role 0) whose state is bProcessEnable,
-- set with SetStateMistWall(bEnable, bForce); story NPCs (AScenarioCharacter) use bProgressVisibility / bShouldBeVisible, set
-- with SetProgressVisibility. The host sends those per name ("W" wall enabled, "V" NPC visible); the guest calls the same
-- setters. Io (ActionNPC, the companion) is left alone.
function visActors()
    local out = {}
    -- 11-06 recording: everywhere else both PCs match by themselves. Left over: side-quest NPCs in Home Base, whose host-side value never reaches his
    -- copy (no OnRep there), so his game showed both stages of the same woman. With vis_mirror=0 only those are mirrored.
    if VIS_OFF then
        local fm = FindFirstOf("AppFieldManager")
        if not (valid(fm) and try(function() return fm:IsInHideout(fm) end) == true) then return out end
    end
    for _, q in ipairs(FindAllOf("Character") or {}) do
        local n = valid(q) and name(q)
        -- (2026-11-03: Sophie is BP_SubQuestChara_08_002_SumikaDevil: side-quest characters are included too)
        if n and (n:find("SubQuestChara", 1, true) or (not VIS_OFF and n:find("ScenarioChara", 1, true))) then out[#out + 1] = {q, "V"} end
    end
    if VIS_OFF then return out end
    for _, c in ipairs(WALL_CLASSES) do
        for _, q in ipairs(FindAllOf(c) or {}) do if valid(q) then out[#out + 1] = {q, "W"} end end
    end
    return out
end
function visState(q, kind)
    if kind == "W" then return try(function() return q.bProcessEnable end) and "1" or "0" end
    local pv = try(function() return q.bProgressVisibility end)
    local hidden = try(function() return q.bHidden end)
    if pv == nil then return hidden and "0" or "1" end   -- classes without progress visibility
    -- (2026-11-03: Cyllene was off by progress on the guest but could be shown again through bHidden; count both)
    -- (11-06: bShouldBeVisible is left out: it belongs to the radar, set by distance)
    return (pv and not hidden) and "1" or "0"
end
visSent, visAt, visGuests = {}, -1000, 0
function visMirrorHost()
    if os.clock() - visAt < 1 then return end   -- (owner: the NPCs/walls changed late; 3 s -> 1 s)
    visAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local guests = {}
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then guests[#guests + 1] = c end
    end
    if #guests == 0 then visGuests = 0; return end
    if #guests > visGuests then visSent = {} end   -- a new guest: send everything again
    visGuests = #guests
    local changed, cur = {}, {}
    for _, e in ipairs(visActors()) do
        local q, kind = e[1], e[2]
        local n = name(q)
        local s = kind .. visState(q, kind)
        if cur[n] ~= kind .. "1" then cur[n] = s end   -- two actors can share a name: on wins
    end
    for n, s in pairs(cur) do
        if visSent[n] ~= s then visSent[n] = s; changed[#changed + 1] = n .. "=" .. s end
    end
    for i = 1, #changed, 15 do
        local msg = "CoopVis:" .. table.concat(changed, ";", i, math.min(i + 14, #changed))
        for _, c in ipairs(guests) do pcall(function() c:ClientMessage(msg, FName("None"), 0) end) end
        log("visibility mirror: sent " .. msg:sub(1, 200))
    end
end
visIn, visWanted, visDone = {}, {}, {}
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text and text:find("^CoopVis:") then visIn[#visIn + 1] = text:sub(9) end
        if text and text:find("^CoopRec") then recIn[#recIn + 1] = text end
        if text and text:find("^CoopFS:piano:") then pcall(pnIn, text)
        elseif text and text:find("^CoopFS:") then fsIn[#fsIn + 1] = text end
    end)
end)
-- the guest keeps the host's last state per name and re-applies it every 3 s (his own logic switched the wall back on before)
visApplyAt = -1000
function visMirrorGuest()
    for _, m in ipairs(visIn) do
        for n, s in m:gmatch("([^;=]+)=([WV][01])") do visWanted[n] = s end
    end
    local fresh = #visIn > 0
    visIn = {}
    if not fresh and os.clock() - visApplyAt < 1 then return end
    visApplyAt = os.clock()
    if next(visWanted) == nil then return end
    local applied = {}
    for _, e in ipairs(visActors()) do
        local q, kind = e[1], e[2]
        local n = name(q)
        local want = visWanted[n]
        if want and want:sub(1, 1) == kind then
            local on = want:sub(2, 2) == "1"
            local key = n .. "/" .. want
            if visState(q, kind) ~= (on and "1" or "0") or (kind == "W" and not visDone[key]) then
                visDone[key] = true
                if kind == "W" then
                    -- (102 test: bProcessEnable went false on the guest but the fog stayed: the effect fades in the wall's tick,
                    -- which may not run there) -> tick on, plus the wall's own activate/deactivate and effect functions
                    pcall(function() q:SetActorTickEnabled(true) end)
                    pcall(function() q:SetStateMistWall(on, true) end)
                    if on then pcall(function() q:OnActivate(true) end); pcall(function() q:ConstructEffect() end)
                    else pcall(function() q:OnDeactivate(true) end); pcall(function() q:DestructEffect() end) end
                else
                    pcall(function() q:SetProgressVisibility(on) end)
                    pcall(function() q:SetActorHiddenInGame(not on) end)
                end
                applied[#applied + 1] = n .. (on and " on" or " off")
            end
        end
    end
    if #applied > 0 then log("visibility mirror: " .. table.concat(applied, ", ")) end
end
-- Recording round (11-06, rec=1 in CoopNative.ini): one rich log on both PCs instead of many small tests. Log only, except that vis_mirror=0
-- switches the visibility mirror off so that the game's own behaviour shows. recEvent runs on the host and tells every guest, so both
-- take their snapshots at the same moment; the message carries the host's clock, which also lines up the two logs.
-- "rec npc" lines here; "rec raw" lines with the fields Lua cannot read come from CoopNative for the same addresses.
REC = iniHas("rec=1")
VIS_OFF = iniHas("vis_mirror=0")
REC_PLAN = { join = {3, 15, 30}, boss = {3, 20}, teleport = {15, 30}, hb = {6, 14, 22, 32, 40, 60, 90}, mark = {0}, force = {3, 10, 20} }
REC_DUMP = { join = 20, boss = 25, teleport = 32, hb = 24, mark = 1 }
recDue, recIn, recPeriodAt, recGuests, recGuestsAt = {}, {}, 0, 0, 0
recBossDue, recTeleportDue, recForce, recLayouts = false, false, nil, nil
function recCmd(s)
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(s .. "\n"); c:close() end
end
function recSchedule(why)
    local now, last = os.clock(), 0
    for _, s in ipairs(REC_PLAN[why] or {}) do
        recDue[#recDue + 1] = { at = now + s, why = why .. "+" .. s }
        if s > last then last = s end
    end
    if REC_DUMP[why] then recDue[#recDue + 1] = { at = now + REC_DUMP[why], why = why .. "+" .. REC_DUMP[why], dump = true } end
    if why ~= "hb" then recCmd("recwin " .. (last + 15)) end
end
function recEvent(why)
    if not REC then return end
    log("rec event " .. why .. " at host clock " .. stamp())
    recSchedule(why)
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            pcall(function() c:ClientMessage("CoopRecEvt:" .. why .. ":" .. stamp(), FName("None"), 0) end)
        end
    end
end
function recCensus(why)
    local set, lines = {}, {}
    for _, q in ipairs(FindAllOf("Character") or {}) do
        local n = valid(q) and name(q)
        if n and (n:find("ScenarioChara", 1, true) or n:find("SubQuestChara", 1, true) or n:find("BP_Player", 1, true) or n:find("NPC", 1, true)) then
            local a = try(function() return q:GetAddress() end)
            local full = try(function() return q:GetFullName() end) or ""
            local m = try(function() return q.Mesh end)
            local mesh = valid(m)
            local loc = try(function() return q:K2_GetActorLocation() end)
            if a then set[#set + 1] = string.format("%X", a) end
            lines[#lines + 1] = string.format("%X %s lvl=%s role=%s pv=%s sv=%s hid=%s meshHid=%s meshVis=%s sq=%s at %s", a or 0, n,
                full:match("/([%w_]+)%.[%w_]+:PersistentLevel") or "?", tostring(try(function() return q.Role end)),
                tostring(try(function() return q.bProgressVisibility end)), tostring(try(function() return q.bShouldBeVisible end)),
                tostring(try(function() return q.bHidden end)), tostring(mesh and try(function() return m.bHiddenInGame end)),
                tostring(mesh and try(function() return m.bVisible end)), tostring(try(function() return q.SubQuestState end)),
                loc and string.format("%d,%d,%d", math.floor(loc.X), math.floor(loc.Y), math.floor(loc.Z)) or "?")
        end
    end
    table.sort(lines)
    log("rec census (" .. why .. "): " .. #lines .. " characters")
    for _, l in ipairs(lines) do log("rec npc " .. l) end
    if not recLayouts or why == "hb+6" then
        recLayouts = {}
        for _, l in ipairs(FindAllOf("LevelStreamingKismet") or {}) do
            local pkg = valid(l) and try(function() return l:GetWorldAssetPackageFName():ToString() end)
            if type(pkg) == "string" and pkg:find("ScenarioLayout", 1, true) then recLayouts[#recLayouts + 1] = { l = l, n = pkg:match("([^/]+)$") or pkg } end
        end
        log("rec census: " .. #recLayouts .. " layout levels known")
    end
    local lv = {}
    for _, e in ipairs(recLayouts) do
        local il = valid(e.l) and try(function() return e.l:IsLevelLoaded() end)
        local iv = valid(e.l) and try(function() return e.l:IsLevelVisible() end)
        if il or iv then lv[#lv + 1] = e.n .. (iv and ":shown" or ":loaded") end
    end
    table.sort(lv)
    log("rec layouts: " .. table.concat(lv, " "))
    local ld = {}
    for _, l in ipairs(FindAllOf("ScenarioProgressLoader") or {}) do
        if valid(l) then
            ld[#ld + 1] = name(l) .. "=" .. tostring(try(function() return l.ProgressName:ToString() end)) .. " skip=" .. tostring(try(function() return l.bSkipLoadProgress end))
        end
    end
    log("rec loaders: " .. table.concat(ld, " | "))
    local wl = {}
    for _, c in ipairs(WALL_CLASSES) do
        for _, w in ipairs(FindAllOf(c) or {}) do
            if valid(w) and try(function() return w.bProcessEnable end) then wl[#wl + 1] = name(w) end
        end
    end
    table.sort(wl)
    log("rec walls on: " .. table.concat(wl, " "))
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.recset", "w")
    if f then f:write(table.concat(set, " ")); f:close(); recCmd("reccensus") end
end
function recTick()
    if not REC then return end
    if FLAVOR then pcall(flavorTick) end
    local gs = FindFirstOf("BP_AppGameState_C")
    local host = valid(gs) and try(function() return gs.Role end) == 3
    local now = os.clock()
    if not host then
        for _, m in ipairs(recIn) do
            local why, at = m:match("^CoopRecEvt:([%w_]+):(.+)$")
            if why then
                log("rec event " .. why .. " from the host: host clock " .. at .. ", here " .. stamp())
                recSchedule(why)
            end
            local nm = m:match("^CoopRecForce:(.+)$")
            if nm then recForce = nm end
        end
    end
    recIn = {}
    if host and now - recGuestsAt > 2 then
        recGuestsAt = now
        local n = 0
        for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
            if valid(c) and not try(function() return c:IsLocalController() end) then n = n + 1 end
        end
        if n > recGuests then recEvent("join") end
        recGuests = n
    end
    if host and recBossDue then recBossDue = false; recEvent("boss") end
    if host and recTeleportDue then recTeleportDue = false; recEvent("teleport") end
    if recForce then
        -- the design's layout correction, through the game's own slot: the loader takes ForcedProgressName instead of SelectMap
        local nm = recForce
        recForce = nil
        for _, l in ipairs(FindAllOf("ScenarioProgressLoader") or {}) do
            if valid(l) and name(l):find("Base0", 1, true) then
                local was = try(function() return l.ProgressName:ToString() end)
                local okS, eS = pcall(function() l.ForcedProgressName = FName(nm) end)
                local got = try(function() return l.ForcedProgressName:ToString() end)
                local okR, eR = pcall(function() l:ReloadProgress() end)
                log("rec force: " .. name(l) .. " was " .. tostring(was) .. ", forced " .. tostring(got) .. " set " .. (okS and "ok" or tostring(eS):sub(1, 100)) ..
                    ", reload " .. (okR and "ok" or tostring(eR):sub(1, 100)))
            end
        end
    end
    if now - recPeriodAt > 60 then recPeriodAt = now; recCensus("periodic"); return end
    for i = #recDue, 1, -1 do
        local e = recDue[i]
        if now >= e.at then
            table.remove(recDue, i)
            if e.dump then
                local f = io.open(WIN64 .. "\\plugins\\CoopProgress.dump", "w")
                if f then f:write(e.why); f:close() end
            else
                recCensus(e.why)
            end
            return
        end
    end
end
-- (11-06: the recording's Lua hooks on LoadStreamLevel and ScenarioStarter:Start* are gone. UE4SS's hook dispatcher, UE4SS.dll +0x4A47A0, walks
-- FFrame::OutParms of the calling Blueprint frame; called from some NPC scripts that list has a bad link: endless loop (host 14:00, guest 12:47) or
-- access violation (host 14:13). So nothing Blueprints call on a conversation may be hooked from Lua.)
-- Flavor recording (11-06, solo in Home Base): what changes when someone sits, plays the piano or uses the jukebox, for the relay to the other PC.
-- Polling only: no hooks on anything Blueprints call (see the OutParms note above).
flavorAt, flavorJukeAt, flavorKey, flavorState, flavorJuke, flavorPianoOn, flavorPianoKey, flavorPianoLogs = 0, 0, nil, nil, nil, false, nil, 0
flavorYaw, flavorPitch, flavorHeadLogs = 0, 0, 0
FLAVOR = iniHas("rec_flavor=1")
PIANO_KEYS = {"IsDecideDown", "IsDirection_DownDown", "IsDirection_LeftDown", "IsDirection_RightDown", "IsDirection_UpDown", "IsFaceLeftDown", "IsFaceTopDown",
              "IsTrigger_L1Down", "IsTrigger_L2Down", "IsTrigger_L3Down", "IsTrigger_R1Down", "IsTrigger_R2Down", "IsTrigger_R3Down"}
function flavorPianoPoll()
    local cam = FindFirstOf("BP_SittingPianoChair_Camera_C")
    if not valid(cam) then return end
    local down = {}
    for _, k in ipairs(PIANO_KEYS) do
        if try(function() return cam[k] end) == true then down[#down + 1] = k:gsub("^Is", ""):gsub("Down$", "") end
    end
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local m = valid(pawn) and try(function() return pawn.Mesh end) or nil
    local anim = valid(m) and try(function() return m:GetAnimInstance() end) or nil
    local key = table.concat(down, "+") .. " play=" .. tostring(valid(anim) and try(function() return anim.IsPianoPlay end)) .. "/" ..
        tostring(valid(anim) and try(function() return anim.IsPianoPlay2 end)) .. " switcher=" .. tostring(try(function() return cam.Switcher end))
    if key ~= flavorPianoKey then
        flavorPianoKey = key
        flavorPianoLogs = flavorPianoLogs + 1
        if flavorPianoLogs <= 500 then log("rec piano: " .. key) end
    end
end
function flavorTick()
    local now = os.clock()
    if now - flavorAt < 0.2 then return end
    flavorAt = now
    if not hbInBase() then flavorPianoOn = false; return end
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(pawn) then return end
    local m = try(function() return pawn.Mesh end)
    local anim = valid(m) and try(function() return m:GetAnimInstance() end) or nil
    local cls = (valid(anim) and name(anim) or "none"):gsub("_%d+$", "")
    local vt = try(function() return pc:GetViewTarget() end)
    local view = valid(vt) and name(vt) or "none"
    flavorPianoOn = cls:find("PianoChair", 1, true) ~= nil   -- (the view target stays the player while sitting)
    local key = cls .. " | " .. view
    if key ~= flavorKey then
        flavorKey = key
        local loc = try(function() return pawn:K2_GetActorLocation() end)
        local rot = try(function() return pawn:K2_GetActorRotation() end)
        local va = valid(vt) and try(function() return vt:GetAddress() end)
        log(string.format("rec sit: anim %s, view %s (%s), pawn %s at %s yaw %s, hidden %s, move mode %s", cls, view, va and string.format("%X", va) or "?", name(pawn),
            loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?", rot and string.format("%.1f", rot.Yaw) or "?",
            tostring(try(function() return pawn.bHidden end)), tostring(try(function() return pawn.CharacterMovement.MovementMode end))))
    end
    if cls:find("Sitting", 1, true) then
        local st = string.format("start=%s loop=%s end=%s state=%s pressX=%s stay=%s/%s/%s", tostring(try(function() return anim.isSittingStart end)), tostring(try(function() return anim.isSittingLoop end)),
            tostring(try(function() return anim.isSittingEnd end)), tostring(try(function() return anim._stateName:ToString() end)), tostring(try(function() return anim.PressX end)),
            tostring(try(function() return anim._isSittingStayDefault end)), tostring(try(function() return anim._isSittingStay1 end)), tostring(try(function() return anim._isSittingStay2 end)))
        if st ~= flavorState then flavorState = st; log("rec sit state: " .. st) end
        -- head following the camera (owner: on E): the sitting animation blueprints have these
        local dy, dp = try(function() return anim.DirectionYaw end), try(function() return anim.DirectionPitch end)
        local d1 = try(function() return anim.DirectionYaw_type1 end)
        if type(dy) == "number" and type(dp) == "number" and (math.abs(dy - flavorYaw) > 4 or math.abs(dp - flavorPitch) > 4) then
            flavorYaw, flavorPitch, flavorHeadLogs = dy, dp, flavorHeadLogs + 1
            if flavorHeadLogs <= 200 then log(string.format("rec head: yaw %.1f pitch %.1f type1 %s", dy, dp, tostring(d1))) end
        end
    end
    if now - flavorJukeAt > 0.5 then
        flavorJukeAt = now
        local parts = {}
        for _, j in ipairs(FindAllOf("BP_FieldTrigger_Jukebox_C") or {}) do
            if valid(j) then
                parts[#parts + 1] = string.format("%s play index %s, select %s, played %s, should play %s, machine %s", name(j), tostring(try(function() return j.PlayIndex end)), tostring(try(function() return j.SelectIndex end)),
                    tostring(try(function() return j.bPlayed end)), tostring(try(function() return j.bShouldPlay end)), tostring(try(function() return j.MachineType end)))
            end
        end
        table.sort(parts)
        local s = table.concat(parts, " | ")
        if s ~= flavorJuke then flavorJuke = s; log("rec jukebox: " .. s) end
    end
end
function npcCensus(reason)
    if REC then return end
    local list, other, others = {}, 0, nil
    for _, q in ipairs(FindAllOf("Character") or {}) do
        local n = valid(q) and name(q)
        if n and not n:find("BP_Player_C", 1, true) then
            if n:find("NPC") or n:find("Npc") or n:find("Talk") or n:find("Scenario") then
                local loc = try(function() return q:K2_GetActorLocation() end)
                list[#list + 1] = string.format("%s role=%s hidden=%s progressVisible=%s/%s at %s", n, tostring(try(function() return q.Role end)),
                    tostring(try(function() return q.bHidden end)), tostring(try(function() return q.bProgressVisibility end)),
                    tostring(try(function() return q.bShouldBeVisible end)),
                    loc and string.format("%d,%d,%d", math.floor(loc.X), math.floor(loc.Y), math.floor(loc.Z)) or "?")
            else other = other + 1; others = others or {}; others[#others + 1] = n .. "/" .. tostring(try(function() return q.Role end)) end
        end
    end
    for _, c in ipairs(WALL_CLASSES) do
        for _, q in ipairs(FindAllOf(c) or {}) do
            if valid(q) then
                list[#list + 1] = string.format("%s role=%s enabled=%s", name(q), tostring(try(function() return q.Role end)),
                    tostring(try(function() return q.bProcessEnable end)))
            end
        end
    end
    table.sort(list)
    log("npc census (" .. reason .. "): " .. #list .. " NPC-like/walls, " .. other .. " other characters")
    if others then table.sort(others); log("npc census: others: " .. table.concat(others, ", "):sub(1, 1500)) end
    for i = 1, math.min(#list, 40) do log("npc census:   " .. list[i]) end
end
function npcCensusTick()
    local gs = FindFirstOf("BP_AppGameState_C")
    local sm = FindFirstOf("AppSessionManager")
    local multi = valid(sm) and valid(gs) and try(function() return sm:IsOnlineMultiplay(gs) end)
    if not multi then npcPawn = nil; return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local mn = valid(mine) and name(mine) or nil
    if mn and mn ~= npcPawn then npcPawn, npcPawnAt = mn, os.clock() end
    if npcPawnAt and os.clock() - npcPawnAt > 20 then npcPawnAt = nil; npcAt = os.clock(); npcCensus("20 s after " .. tostring(mn) .. " appeared") end
    if os.clock() - npcAt > 120 then npcAt = os.clock(); npcCensus("periodic") end
end

-- Memory control (2026-10-31): the guest floated without control in the host's memory. While CoopNative marks the memory window
-- (CoopNative.guestmem = 1, written at his PlayMemoryResidue), every new character of ours (the memory teleport respawns him) gets
-- the input unlock used after a respawn (temporary input masks, ignore-input flags, game-only input mode), and its state is logged
-- every 3 s for a minute: begun play, tick enabled, movement mode, move input ignored.
local memCtlPawn, memCtlAt, memCtlLog = nil, nil, -1000
-- 2026-11-02 (owner's idea, refined): the host's character floated on this PC at the memory start. Its position arrives, but the
-- character does not run here: its tick is off (guest log 20:04: "other character ... tick +0x35 0"), so no animation, gravity or
-- ground. For 90 s after the memory window opens, every player character whose tick is off gets its tick switched back on (actor,
-- body mesh, movement component), the step the game's own character start would have done; each one is logged once.
memWinAt, floatFixed, floatCheckAt, floatZ = nil, {}, -1000, nil
function memoryFloatFix()
    if not memWinAt or os.clock() - memWinAt > 90 or os.clock() - floatCheckAt < 1 then return end
    floatCheckAt = os.clock()
    for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
        local qn = valid(q) and name(q)
        -- 2026-11-02 floor logs: the host's memory character stood at the right height (z 100, like ours) but in falling mode
        -- (3) with no floor here (its base, StaticMeshActor_15, did not resolve on this PC; ours stands on that same floor):
        -- remote characters (role 1) falling at an unchanged height are put into walking mode (1); position keeps coming from the host
        if qn and try(function() return q.Role end) == 1 then
            local cm = try(function() return q.CharacterMovement end)
            local loc = try(function() return q:K2_GetActorLocation() end)
            if valid(cm) and loc and try(function() return cm.MovementMode end) == 3 then
                floatZ = floatZ or {}
                local last = floatZ[qn]
                floatZ[qn] = loc.Z
                if last and math.abs(last - loc.Z) < 5 then
                    local ok = pcall(function() cm:SetMovementMode(1, 0) end)
                    if not floatFixed[qn .. "/walk"] then
                        floatFixed[qn .. "/walk"] = true
                        log(string.format("memory float fix: %s was falling at a steady height (z %d) -> walking %s", qn, math.floor(loc.Z), tostring(ok)))
                    end
                end
            end
        end
        if qn and try(function() return q:IsActorTickEnabled() end) == false then
            local a = pcall(function() q:SetActorTickEnabled(true) end)
            local m = try(function() return q.Mesh end)
            local b = valid(m) and pcall(function() m:SetComponentTickEnabled(true) end)
            local cm = try(function() return q.CharacterMovement end)
            local c = valid(cm) and pcall(function() cm:SetComponentTickEnabled(true) end)
            if not floatFixed[qn] then
                floatFixed[qn] = true
                log(string.format("memory float fix: %s had its tick off -> actor %s, mesh %s, movement %s; now tick=%s", qn, tostring(a),
                    tostring(b), tostring(c), tostring(try(function() return q:IsActorTickEnabled() end))))
            end
        end
    end
end
local function guestMemoryControl()
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.guestmem", "r"); if not f then return end
    local on = (f:read("*a") or ""):match("1") ~= nil; f:close()
    if on and not memWinAt then
        memWinAt, floatFixed = os.clock(), {}
        myPawnAt = -1000   -- hand CoopNative the full character list right now, not up to 2 s later
        pcall(writeMyPawn)
    elseif not on then memWinAt = nil end
    pcall(memoryFloatFix)
    if not on then memCtlPawn = nil; return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return end
    if name(mine) ~= memCtlPawn then
        memCtlPawn, memCtlAt = name(mine), os.clock()
        unlockUntil, unlockedPawn = os.clock() + 20, nil
        log("memory control: our character is " .. memCtlPawn .. " -> input unlock for 20 s")
    end
    if memCtlAt and os.clock() - memCtlAt < 60 and os.clock() - memCtlLog > 3 then
        memCtlLog = os.clock()
        -- 2026-11-02: the host's character floated on this PC at the memory start: log every player character here
        for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
            if valid(q) and name(q) ~= memCtlPawn then
                local qm = try(function() return q.CharacterMovement end)
                local loc = try(function() return q:K2_GetActorLocation() end)
                log(string.format("memory control: other %s tick=%s moveMode=%s z=%s role=%s", name(q),
                    tostring(try(function() return q:IsActorTickEnabled() end)), tostring(valid(qm) and try(function() return qm.MovementMode end)),
                    tostring(loc and math.floor(loc.Z)), tostring(try(function() return q.Role end))))
            end
        end
        local cm = try(function() return mine.CharacterMovement end)
        log(string.format("memory control: %s begunPlay=%s tick=%s moveMode=%s moveIgnored=%s", memCtlPawn,
            tostring(try(function() return mine:HasActorBegunPlay() end)), tostring(try(function() return mine:IsActorTickEnabled() end)),
            tostring(valid(cm) and try(function() return cm.MovementMode end)), tostring(try(function() return pc:IsMoveInputIgnored() end))))
    end
end

-- Memory spectating (session 10, step c): while the host's memory runs (CoopNative.guestmem = 1, written by CoopNative when our own
-- memory copy is blocked) our camera follows the host's character and our own pawn is hidden (it floats there without control).
-- When it ends (0) the camera goes back to our pawn and it is shown again.
local GUESTMEM_PATH = WIN64 .. "\\plugins\\CoopNative.guestmem"
do local f = io.open(GUESTMEM_PATH, "w"); if f then f:write("0"); f:close() end end
local memSpectating, memHiddenPawn, memSpecAt = false, nil, -1000
local function guestMemorySpectate()
    if not iniHas("guest_memory_block=1") then return end   -- (2026-10-31: the window now means "unlock", see guestMemoryControl)
    if os.clock() - memSpecAt < 1 then return end
    memSpecAt = os.clock()
    local f = io.open(GUESTMEM_PATH, "r"); if not f then return end
    local on = (f:read("*a") or ""):match("1") ~= nil; f:close()
    local pc = localPC()
    if not valid(pc) then return end
    local mine = try(function() return pc.Pawn end)
    if on then
        local target
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
            if valid(p) and not (valid(mine) and name(p) == name(mine)) and not try(function() return p.bHidden end) then target = p end
        end
        if valid(target) then
            local vt = try(function() return pc:GetViewTarget() end)
            if not valid(vt) or name(vt) ~= name(target) then
                pcall(function() pc:SetViewTargetWithBlend(target, 0.5, 0, 0, false) end)
                log("memory spectate: camera -> " .. name(target))
            end
        end
        if valid(mine) and memHiddenPawn ~= name(mine) then
            local ok = pcall(function() mine:SetActorHiddenInGame(true) end)
            memHiddenPawn = name(mine)
            log("memory spectate: own pawn " .. name(mine) .. " hidden " .. tostring(ok))
        end
        memSpectating = true
    elseif memSpectating then
        memSpectating = false
        if valid(mine) then
            pcall(function() mine:SetActorHiddenInGame(false) end)
            pcall(function() pc:SetViewTargetWithBlend(mine, 0.3, 0, 0, false) end)
        end
        log("memory spectate: ended, camera back to " .. (valid(mine) and name(mine) or "?"))
        memHiddenPawn = nil
    end
end
-- 2026-10-30 (guest crashes 20:51 and 21:24 at the Mistle, inside UE4SS, null+0x18): looping over every HumanContextComponent and
-- asking each for its owner hit half-destroyed components of characters replaced by a teleport/respawn. Take our own component
-- straight from our character (BP_Player.HumanContext) instead.
local function ownHumanContext()
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return nil end
    local c = try(function() return mine.HumanContext end)
    return valid(c) and c or nil
end
-- tell CoopNative our own HumanContextComponent (for the direct level-up call), written when the menu opens
local function writeMyComponent()
    local c = ownHumanContext()
    if not c then return nil end
    local a = try(function() return c:GetAddress() end)
    local f = a and io.open(WIN64 .. "\\plugins\\CoopNative.mycomp", "w")
    if f then f:write(string.format("%X", a)); f:close(); log(string.format("guest rest: own HumanContextComponent 0x%X handed to CoopNative", a)) end
    return c
end
-- Home Base flavor sync (flavor_sync=1, 11-06): sitting, the head on a seat, the jukeboxes. The game does all of it on one PC only: a seat swaps the local
-- character's anim class and moves it; the seat's camera writes DirectionYaw/Pitch into that anim instance; a jukebox is a local sound with a requested
-- track (SelectIndex) and bShouldPlay. Polling only, no hooks. Host -> guest: ClientMessage "CoopFS:...". Guest -> host: numbers through Server_AddExp, below
-- -3000000: payload = kind * 2^24 + data; CoopNative hands them over in CoopNative.flavorin.
-- kinds: 1 seat, 2 x, 3 y, 4 z, 5 yaw, 6 head, 7 jukebox, 8 hello. The host moves its copy of him to the seat (the host simulates his character).
FS_ON = iniHas("flavor_sync=1")
FS_BASE, FS_KIND = 3000000, 16777216
FS_DIR = "/Game/Cinematics/Scenario/Base01_Hideout/Others/SittingEvent/"
FS_ANIMS = {"base_chair/ABP_ScenarioChara_SittingChair", "base_chair/ABP_ScenarioChara_SittingChair02", "base_chair/ABP_ScenarioChara_SittingChair03",
            "Base_Sofa/ABP_ScenarioChara_SittingSofa", "Base_Sofa/ABP_ScenarioChara_SittingSofa02", "Base_Sofa/ABP_ScenarioChara_SittingSofa03",
            "Base_MiaChair/ABP_ScenarioChara_SittingMiaChair", "Base_MiaChair/ABP_ScenarioChara_SittingMiaChair02", "Base_Bed/ABP_ScenarioChara_SittingBed",
            "Base_PianoChair/ABP_ScenarioChara_SittingPianoChair", "Base_GardenChair/ABP_ScenarioChara_SittingGardenChair", "Base_GardenChair/ABP_ScenarioChara_SittingGardenChair02"}
FS_INDEX = {}
for i, p in ipairs(FS_ANIMS) do FS_INDEX[p:match("([^/]+)$") .. "_C"] = i end
fsIn, fsAt, fsBaseAt, fsInBase, fsJukeAt, fsHello, fsComp, fsErr = {}, 0, 0, false, 0, false, nil, false
fsMine = { idx = 0, since = 0, sent = true }
fsRem = { idx = 0 }
fsHeadY, fsHeadP, fsHeadX, fsHeadLogs, fsHeadInLogs = 0, 0, false, 0, 0
fsJukeSeen = {}
-- Seats for guests (guest_seats=1, see CoopNative): which triggers and seat cameras CoopNative may treat specially, and which character is ours. While sitting the
-- controller holds the seat's camera (host and guest), so the character is the last BP_Player we had, not pc.Pawn.
FS_SEATS = iniHas("guest_seats=1")
fsSeatOn, fsSeatNew, fsTrigOff, fsHeadOn = {}, 0, {}, false
fsMyChar, fsSeatsAt, fsSeatsSince, fsSeatsSent, fsKitSent = nil, -1000, 0, nil, false
function fsSeatsWrite(text, what)
    if text == fsSeatsSent then return end
    fsSeatsSent = text
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.seats", "w")
    if f then f:write(text); f:close() end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write("seats\n"); c:close() end
    log("flavor: seats list for CoopNative: " .. what)
end
-- 11-07: item triggers (seats are) are hidden with no collision on a client (host: hidden false, collision 1; he: hidden true, 0). Setting that by hand brought no overlap (31 units
-- away: overlapping false), nor did calling OnComponentBeginOverlap ourselves. FieldTriggerBase:SetGimmickVisibility is the game's own switch for all of it (0x1406FC510).
fsSeatObjs, fsSeatLogs, fsSeatPeekAt, fsSeatHostLogged, fsSeatSeen, fsSeatIn = {}, 0, 0, false, {}, nil
FS_SEAT_RANGE = 130
function fsSeatState(q)
    local ba = try(function() return q.BindingArea end)
    local prof = valid(ba) and try(function() return ba:GetCollisionProfileName():ToString() end)
    return string.format("hidden %s, gimmick %s, area collision %s, profile %s, radius %s scaled %s, range %s", tostring(try(function() return q.bHidden end)),
        tostring(try(function() return q.bGimmickVisibility end)), tostring(valid(ba) and try(function() return ba:GetCollisionEnabled() end)), tostring(prof),
        tostring(valid(ba) and try(function() return ba.SphereRadius end)), tostring(valid(ba) and try(function() return ba:GetScaledSphereRadius() end)),
        tostring(try(function() return q.BindingRange end)))
end
function fsSeatPeek(now)
    if now < fsSeatPeekAt or not valid(fsMyChar) or fsMine.idx > 0 then return end
    fsSeatPeekAt = now + 0.5
    local at = try(function() return fsMyChar:K2_GetActorLocation() end)
    if not at then return end
    for _, q in ipairs(fsSeatObjs) do
        local l = valid(q) and try(function() return q:K2_GetActorLocation() end)
        if l then
            local dx, dy, dz = l.X - at.X, l.Y - at.Y, l.Z - at.Z
            if dx * dx + dy * dy + dz * dz < FS_SEAT_RANGE * FS_SEAT_RANGE then
                local ba = try(function() return q.BindingArea end)
                local over = valid(ba) and try(function() return ba:IsOverlappingActor(fsMyChar) end)
                local tcl = StaticFindObject("/Script/Extensions.FieldTriggerActionComponent")
                local c = valid(tcl) and try(function() return fsMyChar:GetComponentByClass(tcl) end)
                local tg = valid(c) and try(function() return c:GetTargetFieldTrigger() end)
                local key = name(q) .. tostring(over) .. (valid(tg) and name(tg) or "none")
                if not fsSeatSeen[key] then
                    fsSeatSeen[key] = true
                    log(string.format("flavor: near %s (%.0f away): overlapping %s, target %s, button %s, active %s; %s", name(q), math.sqrt(dx * dx + dy * dy + dz * dz), tostring(over),
                        valid(tg) and name(tg) or "none", tostring(valid(c) and try(function() return c:ExistActionButton() end)),
                        tostring(try(function() return q:IsActionButtonActive(fsMyChar) end)), fsSeatState(q)))
                end
            end
        end
    end
end
function fsSeatsTick(host, now)
    if not FS_SEATS then return end
    pcall(fsSeatPeek, now)
    if fsSeatsSince == 0 then fsSeatsSince = now end
    if now - fsSeatsAt < (now - fsSeatsSince < 30 and 2 or 10) then return end   -- (fsSeatPeek above has its own pace)
    fsSeatsAt = now
    local me = valid(fsMyChar) and try(function() return fsMyChar:GetAddress() end) or 0
    local cams, btns = {}, {}
    for _, q in ipairs(FindAllOf("Character") or {}) do
        if valid(q) and name(q):find("^BP_Sitting") then
            local a = try(function() return q:GetAddress() end)
            if a then cams[#cams + 1] = string.format("%X", a) end
        end
    end
    if not host then
        for _, q in ipairs(FindAllOf("FieldTriggerBase") or {}) do
            local n = valid(q) and name(q) or ""
            if n:find("Sitting", 1, true) or n:find("Jukebox", 1, true) or n:find("JukeBox", 1, true) or n:find("NextGoalItem", 1, true) then
                local a = try(function() return q:GetAddress() end)
                if a then btns[#btns + 1] = string.format("%X", a) end
                -- owner 11-09: the story bulletin board; its text comes from the story state of whoever reads it
                if a and n:find("NextGoalItem", 1, true) and not fsSeatOn[a] then
                    fsSeatOn[a] = true
                    local before = fsSeatState(q)
                    local okv, ev = pcall(function() q:SetGimmickVisibility(true) end)
                    pcall(function() q.bGimmickVisibility = true end)
                    local ba = try(function() return q.BindingArea end)
                    if valid(ba) then
                        pcall(function() ba:SetCollisionProfileName(FName("OverlapAllDynamic")) end)
                        pcall(function() ba:SetCollisionEnabled(1) end)
                    end
                    log("flavor: story board " .. n .. " was: " .. before .. "; SetGimmickVisibility " .. (okv and "ok" or tostring(ev):sub(1, 100)) .. "; now: " .. fsSeatState(q))
                    fsSeatObjs[#fsSeatObjs + 1] = q
                end
                -- 11-06 22:3x: his jukebox prompt came on, no seat's did, and the button check never ran for a seat. BP_FieldTriggerMessage switches its overlap on in
                -- OnProgressFlagUpdated, and the game calls that on the server only.
                if a and n:find("FieldTriggerMessage_Sitting", 1, true) and not fsSeatOn[a] then
                    fsSeatOn[a] = pcall(function() q:SetMessageTriggerActive(true) end) and true or false
                    fsSeatNew = fsSeatNew + 1
                    local before = fsSeatState(q)
                    local okv, ev = pcall(function() q:SetGimmickVisibility(true) end)
                    pcall(function() q.bGimmickVisibility = true end)   -- 12:16: still false after the call on his PC
                    -- on the host: area collision 1, profile OverlapAllDynamic, radius 1: the prompt comes when the capsule touches that point (40 away: yes, 81 away: no)
                    local ba = try(function() return q.BindingArea end)
                    if valid(ba) then
                        pcall(function() ba:SetCollisionProfileName(FName("OverlapAllDynamic")) end)
                        pcall(function() ba:SetCollisionEnabled(1) end)
                    end
                    fsSeatLogs = fsSeatLogs + 1
                    if fsSeatLogs <= 2 then log("flavor: seat " .. n .. " was: " .. before .. "; SetGimmickVisibility " .. (okv and "ok" or tostring(ev):sub(1, 100)) .. "; now: " .. fsSeatState(q)) end
                    fsSeatObjs[#fsSeatObjs + 1] = q
                end
            end
        end
    end
    if fsSeatNew > 0 then log("flavor: " .. fsSeatNew .. " seats turned on for us"); fsSeatNew = 0 end
    if host and not fsSeatHostLogged then
        for _, q in ipairs(FindAllOf("FieldTriggerBase") or {}) do
            if valid(q) and name(q):find("FieldTriggerMessage_Sitting", 1, true) then
                if not fsSeatHostLogged then log("flavor: seat on the host: " .. name(q) .. " " .. fsSeatState(q)) end
                fsSeatHostLogged = true
                fsSeatObjs[#fsSeatObjs + 1] = q
            end
        end
    end
    -- the prompt on the wrong screen (11-06): each character's FieldTriggerActionComponent elects triggers, on every PC, and a jukebox opens its menu when elected. The copy
    -- of the other player has no business electing anything here.
    local tcl = StaticFindObject("/Script/Extensions.FieldTriggerActionComponent")
    for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
        local a = valid(q) and try(function() return q:GetAddress() end)
        if a and a ~= me and not fsTrigOff[a] then
            local c = valid(tcl) and try(function() return q:GetComponentByClass(tcl) end)
            if valid(c) then
                fsTrigOff[a] = true
                local ok = pcall(function() c:SetComponentTickEnabled(false) end)
                log("flavor: trigger choice off for the other player's " .. name(q) .. " -> " .. tostring(ok))
            end
        end
    end
    table.sort(cams); table.sort(btns)
    local pcw = localPC()
    local pca = valid(pcw) and try(function() return pcw:GetAddress() end) or 0
    fsSeatsWrite(string.format("me %X\npc %X\ncam %s\nbtn %s\n", me, pca, table.concat(cams, " "), table.concat(btns, " ")), #cams .. " cameras, " .. #btns .. " triggers")
end
-- 11-07 12:27: he sat (button hook) but the seat's Possess(camera) is BlueprintAuthorityOnly and never ran on his PC, so the camera with the stand-up input was never his
-- and he could not get up. We hand him the nearest seat camera ourselves (CoopNative "seatcam": ClientRestart on his controller), and back to his character when
-- the seat lets him go (its Possess back is skipped the same way). ClearBindFieldTrigger, which the camera does on GetPlayerPawn(0), is done on his character.
fsCamAt, fsCamTries, fsCamLook, fsCamLogUntil, fsCamLogAt = 0, 0, nil, 0, 0
function fsSeatCam(pawnTo)
    local pc = localPC()
    local a = valid(pc) and try(function() return pc:GetAddress() end)
    local b = valid(pawnTo) and try(function() return pawnTo:GetAddress() end)
    if not (a and b) then return false end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if not c then return false end
    c:write(string.format("seatcam %X %X\n", a, b)); c:close()
    log("flavor: our view goes to " .. name(pawnTo))
    return true
end
function fsNearestSeatCam()
    local at = valid(fsMyChar) and try(function() return fsMyChar:K2_GetActorLocation() end)
    if not at then return nil end
    local best, bd = nil, 1200 * 1200
    for _, q in ipairs(FindAllOf("Character") or {}) do
        if valid(q) and name(q):find("^BP_Sitting") then
            local l = try(function() return q:K2_GetActorLocation() end)
            if l then
                local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2
                if d < bd then best, bd = q, d end
            end
        end
    end
    return best
end
-- Owner 11-07 13:45: the seat camera for the guest is parked (no handover, no camera control; kits 170-173 tried it). Back to 169: he sits with his own view, and gets up
-- the way he would leave anything: moving, or the seat's Cancel keys (right mouse, Backspace, pad bottom; Escape stays the menu). Then the seat's getting-up animation,
-- and after 3 s what the seat's camera does on the host after its Possess: player animation, the movement values, Home Base mode, ClearBindFieldTrigger.
-- 11-07 20:5x (owner): after getting up he could not sit on that chair again, and he moonwalked (facing one way, walking another; normal on the host's screen).
-- The chair's trigger box, at the sit, sets RotationRate (0,0,0) and the trigger's MessageType false (its button now means "leave": ProcessInputButtonEvent sets
-- Leaving<X>, which the seat's camera watches). The camera, at the stand, sets RotationRate (0,1300,0), Leaving<X> false, MessageType true. His camera never runs.
fsGStand, fsGSeatLogged, fsMySeat, fsGSeatFix = nil, false, nil, nil
function fsNearestSeat(at, maxd)
    local best, bd, bn = nil, maxd * maxd, nil
    for _, q in ipairs(FindAllOf("FieldTriggerBase") or {}) do
        local n = valid(q) and name(q) or ""
        if n:find("FieldTriggerMessage_Sitting", 1, true) then
            local ba = try(function() return q.BindingArea end)
            local l = (valid(ba) and try(function() return ba:K2_GetComponentLocation() end)) or try(function() return q:K2_GetActorLocation() end)
            if l then
                local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + ((l.Z - at.Z) * 0.5) ^ 2
                if d < bd then best, bd, bn = q, d, n end
            end
        end
    end
    return best, best and math.sqrt(bd) or nil, bn
end
function fsSeatTrigRestore(q, why)
    if not valid(q) then return false end
    local set = {}
    pcall(function()
        q:GetClass():ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            if n:find("^Leaving") or n:find("^Sitting") then set[#set + 1] = n end
        end)
    end)
    if #set == 0 then set = { "LeavingChair", "SittingChair", "LeavingSofa", "SittingSofa" } end
    for _, n in ipairs(set) do pcall(function() q[n] = false end) end
    local ok = pcall(function() q.MessageType = true end)
    local oks = pcall(function() q:SetState(1) end)
    log("flavor: seat " .. name(q) .. " back to 'sit' (" .. why .. "): MessageType " .. tostring(ok) .. ", state Active " .. tostring(oks) .. " (now " ..
        tostring(try(function() return q.State end)) .. "), cleared " .. table.concat(set, "/"))
    return ok
end
function fsGuestSeatTick(host, now, pc, idx)
    if host or not FS_SEATS then return end
    -- once more 2 s after getting up: the trigger box's own 3 s Delay after a sit sets MessageType false again if he got up quickly
    if fsGSeatFix and now >= fsGSeatFix.at then
        local q = fsGSeatFix.q
        fsGSeatFix = nil
        if idx == 0 then pcall(fsSeatTrigRestore, q, "again, 2 s later") end
    end
    if idx == 0 then fsGStand, fsGSeatLogged = nil, false; return end
    if not fsMine.sent or not valid(fsMyChar) then return end
    if fsGStand then
        if now >= fsGStand.done and not fsGStand.finished then
            fsGStand.finished = true
            local hlp = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
            local m = try(function() return fsMyChar.Mesh end)
            local cls = fsStandClass(fsMyChar)
            local ok = valid(m) and valid(cls) and pcall(function() m:SetAnimInstanceClass(cls) end)
            local gm = try(function() return fsMyChar.CharacterMovement end)
            if valid(gm) then
                pcall(function() gm.MaxCustomMovementSpeed = 600; gm.MaxWalkSpeed = 600; gm.MaxWalkSpeedCrouched = 300; gm.MaxAcceleration = 2048 end)
                pcall(function() gm:SetMovementMode(1, 0) end)
            end
            if iniHas("hb_base_mode=1") then pcall(function() hlp:SetRestrictedActionInBaseInfo(fsMyChar, hbBaseInfo()) end) end
            pcall(function() hlp:ClearBindFieldTrigger(fsMyChar) end)
            local okr = valid(gm) and pcall(function() gm.RotationRate = { Pitch = 0, Yaw = 1300, Roll = 0 } end)
            log("flavor: up from the seat -> player animation " .. tostring(ok) .. ", turning back " .. tostring(okr))
            if fsMySeat then
                pcall(fsSeatTrigRestore, fsMySeat, "we are up")
                fsGSeatFix = { q = fsMySeat, at = now + 2 }
            else log("flavor: up from the seat, but which seat it was is not known") end
        end
        return
    end
    local function axis(n) return try(function() return fsMyChar:GetInputAxisValue(FName(n)) end) end
    local function key(n) return try(function() return pc:IsInputKeyDown({ KeyName = FName(n) }) end) == true end
    local f, r = axis("MoveForward"), axis("MoveRight")
    if not fsGSeatLogged then
        fsGSeatLogged = true
        log("flavor: seated on our own view; move axes readable: " .. tostring(type(f) == "number") .. ", right mouse readable: " ..
            tostring(try(function() return pc:IsInputKeyDown({ KeyName = FName("RightMouseButton") }) end) ~= nil))
    end
    local move = (type(f) == "number" and math.abs(f) > 0.3) or (type(r) == "number" and math.abs(r) > 0.3)
    if move or key("RightMouseButton") or key("BackSpace") or key("Gamepad_FaceButton_Bottom") then
        local anim = try(function() return fsMyChar.Mesh:GetAnimInstance() end)
        local okA = valid(anim) and pcall(function() anim.isSittingEnd = true end)
        fsGStand = { done = now + 3 }
        if not fsMine.standing then
            fsMine.standing, fsMine.standAt = true, now
            fsToHost(10, 0)
        end
        log("flavor: we are standing up (" .. (move and "moved" or "cancel key") .. "), animation " .. tostring(okA))
    end
end
function fsKitNumber()
    local f = io.open(WIN64 .. "\\plugins\\CoopKitVersion.txt", "r")
    if not f then return 0 end
    local s = f:read("*a") or ""
    f:close()
    return tonumber(s:match("update%-(%d+)")) or 0
end
function fsClassOf(i)
    local p = FS_ANIMS[i]
    if not p then return nil end
    local leaf = p:match("([^/]+)$")
    local path = FS_DIR .. p .. "." .. leaf .. "_C"
    local c = StaticFindObject(path)
    if not valid(c) then
        pcall(function() LoadAsset(FS_DIR .. p .. "." .. leaf) end)
        c = StaticFindObject(path)
    end
    return c
end
function fsStandClass(pawn)
    local hlp = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local male = try(function() return hlp:IsMaleByAppearance(pawn) end)
    local leaf = male and "ABP_PlayerMale" or "ABP_PlayerFemale"
    return StaticFindObject("/Game/character/BodyBase/Male/" .. leaf .. "." .. leaf .. "_C")
end
function fsGuests()
    local out = {}
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then out[#out + 1] = c end
    end
    return out
end
function fsOther(host)
    if host then
        local g = fsGuests()[1]
        return g and try(function() return g.Pawn end) or nil
    end
    local pc = localPC()
    local mine = valid(fsMyChar) and fsMyChar or (valid(pc) and try(function() return pc.Pawn end) or nil)
    local ma = valid(mine) and try(function() return mine:GetAddress() end)
    for _, q in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(q) and try(function() return q:GetAddress() end) ~= ma and try(function() return q.Role end) ~= 3 then return q end
    end
    return nil
end
fsCompPawn = nil
function fsToHost(kind, data)
    do
        local pcc = localPC()
        local cur = valid(pcc) and try(function() return pcc.Pawn end) or nil
        if valid(cur) and name(cur):find("BP_Player", 1, true) then
            local ca = try(function() return cur:GetAddress() end)
            if ca and ca ~= fsCompPawn then
                if fsCompPawn then log(string.format("flavor: our character changed (0x%X -> 0x%X): fetching its component for the host messages", fsCompPawn, ca)) end
                fsComp, fsCompPawn = nil, ca
            end
        end
    end
    if not valid(fsComp) then
        local ok, c = pcall(writeMyComponent)
        fsComp = ok and c or nil
    end
    if valid(fsComp) then return (pcall(function() fsComp:Server_AddExp(-(FS_BASE + kind * FS_KIND + data)) end)) end
    return false
end
function fsToGuests(text)
    for _, c in ipairs(fsGuests()) do pcall(function() c:ClientMessage(text, FName("None"), 0) end) end
end
function fsHeadWrite(anim, pt, y)
    if not anim and not fsHeadOn then return end
    fsHeadOn = anim ~= nil
    local a = anim and try(function() return anim:GetAddress() end) or 0
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.head", "w")
    if f then f:write(string.format("%X %d %d\n", a, pt or 0, y or 0)); f:close() end
end
function fsApplyStand(host)
    fsRem.standing = true
    local p = fsOther(host)
    local m = valid(p) and try(function() return p.Mesh end) or nil
    local cls = (fsRem.idx or 0) > 0 and fsClassOf(fsRem.idx) or nil
    -- the same two steps as the seat's camera: a fresh instance, then the end flag
    if valid(m) and valid(cls) then pcall(function() m:SetAnimInstanceClass(cls) end) end
    local anim = valid(m) and try(function() return m:GetAnimInstance() end) or nil
    if not valid(anim) then return end
    local ok = pcall(function() anim.isSittingEnd = true end)
    fsHeadWrite(nil)
    log("flavor: other player stands up " .. tostring(ok))
end
function fsApplySit(host, idx)
    -- no word of him getting up: play it now and let him go after it
    if idx == 0 and (fsRem.idx or 0) > 0 and not fsRem.standing then
        fsApplyStand(host)
        fsRem.swapAt, fsRem.swapHost = os.clock() + 3, host
        return
    end
    fsRem.idx, fsRem.standing = idx, false
    if idx == 0 then fsHeadWrite(nil) end
    local p = fsOther(host)
    local m = valid(p) and try(function() return p.Mesh end) or nil
    if not valid(m) then log("flavor: no character for the other player's seat " .. idx); return end
    -- 11-07: seen on his screen 50 units above the sofa. The seat takes the character out of collision on the sitter's PC only; on the other one it stays a walking capsule.
    if idx == 0 then
        pcall(function() p:SetActorEnableCollision(true) end)
        local gm0 = try(function() return p.CharacterMovement end)
        if valid(gm0) then pcall(function() gm0:SetMovementMode(1, 0) end) end
        fsRem.x, fsRem.y, fsRem.z = nil, nil, nil
    end
    local cls = idx > 0 and fsClassOf(idx) or fsStandClass(p)
    if not valid(cls) then log("flavor: animation class for seat " .. idx .. " not found"); return end
    local ok, e = pcall(function() m:SetAnimInstanceClass(cls) end)
    if idx > 0 then
        local anim = try(function() return m:GetAnimInstance() end)
        if valid(anim) then
            pcall(function() anim.isSittingLoop = true end)
            -- until his first numbers come: looking straight ahead, not where our own camera looks
            fsHeadWrite(anim, 0, math.floor(try(function() return p:K2_GetActorRotation().Yaw end) or 0))
        end
        if fsRem.x and fsRem.y and fsRem.z then
            -- the host simulates his character: without this he stays where he stood, here and after the next correction on his PC too
            local to, rot = { X = fsRem.x, Y = fsRem.y, Z = fsRem.z }, { Pitch = 0, Yaw = fsRem.yaw or 0, Roll = 0 }
            local gm = try(function() return p.CharacterMovement end)
            if valid(gm) then
                pcall(function() gm:StopMovementImmediately() end)
                pcall(function() gm:SetMovementMode(0, 0) end)
            end
            pcall(function() p:SetActorEnableCollision(false) end)
            local okm = pcall(function() p:K2_SetActorLocationAndRotation(to, rot, false, {}, true) end)
            if not okm then pcall(function() p:K2_TeleportTo(to, rot) end) end
            local at = try(function() return p:K2_GetActorLocation() end)
            log(string.format("flavor: the other player sits at %d,%d,%d, his copy here at %s", fsRem.x, fsRem.y, fsRem.z, at and string.format("%.0f,%.0f,%.0f", at.X, at.Y, at.Z) or "?"))
        end
    end
    log("flavor: other player's seat -> " .. idx .. " " .. (ok and "ok" or tostring(e):sub(1, 100)))
end
function fsApplyHead(host, y, pt, px)
    if fsRem.idx == 0 then return end
    local p = fsOther(host)
    local m = valid(p) and try(function() return p.Mesh end) or nil
    local anim = valid(m) and try(function() return m:GetAnimInstance() end) or nil
    if not valid(anim) then return end
    fsHeadWrite(anim, pt, y)
    pcall(function() anim.PressX = px end)
    fsHeadInLogs = fsHeadInLogs + 1
    if fsHeadInLogs <= 6 then log(string.format("flavor: head in: yaw %d pitch %d press %s", y, pt, tostring(px))) end
end
function fsJukes()
    local out = {}
    for _, j in ipairs(FindAllOf("BP_FieldTrigger_Jukebox_C") or {}) do if valid(j) then out[#out + 1] = { n = name(j), j = j } end end
    table.sort(out, function(a, b) return a.n < b.n end)
    return out
end
function fsApplyJuke(id, idx, on)
    local e = fsJukes()[id]
    if not e then return end
    fsJukeSeen[id] = idx .. ":" .. tostring(on)
    pcall(function() e.j.SelectIndex = idx end)
    local ok, er = pcall(function() if on then e.j:RequestPlay() else e.j:RequestStop() end end)
    log("flavor: jukebox " .. e.n .. " -> track " .. idx .. ", " .. (on and "on" or "off") .. " " .. (ok and "ok" or tostring(er):sub(1, 100)))
end
function fsHostIn()
    local path = WIN64 .. "\\plugins\\CoopNative.flavorin"
    local f = io.open(path, "r")
    if not f then return end
    local text = f:read("*a") or ""
    f:close(); os.remove(path)
    for line in text:gmatch("[^\r\n]+") do
        local v = tonumber(line)
        if v then
            local kind, data = v // FS_KIND, v % FS_KIND
            if kind == 1 then fsApplySit(true, data)
            elseif kind == 2 then fsRem.x = data - 8388608
            elseif kind == 3 then fsRem.y = data - 8388608
            elseif kind == 4 then fsRem.z = data - 8388608
            elseif kind == 5 then fsRem.yaw = data / 10 - 360
            elseif kind == 6 then
                local px = data >= 4194304
                if px then data = data - 4194304 end
                fsApplyHead(true, data // 2048 - 512, data % 2048 - 512, px)
            elseif kind == 10 then fsApplyStand(true)
            elseif kind == 15 then
                hostGuestMenuAt = data == 1 and os.clock() or nil
                log("level-up: the guest's Mistle menu is " .. (data == 1 and "open (his character goes first on our protect list for the level-up relay)" or "closed"))
            elseif kind == 13 then
                hbGuestFloor = true
                log("hb: the guest's floor is there")
            elseif kind == 11 then
                hbGuestStage = true
                log("hb: leaving, the guest's stage is there")
            elseif kind == 7 then fsApplyJuke(data // 4096, (data % 4096) // 2, data % 2 == 1)
            elseif kind == 9 then
                local ours = fsKitNumber()
                log("flavor: the guest runs kit " .. data .. ", we run " .. ours .. (data == ours and "" or "  *** DIFFERENT KITS ***"))
            elseif kind == 8 then
                log("flavor: the guest is in Home Base, sending our state")
                for id, e in ipairs(fsJukes()) do
                    local idx, on = try(function() return e.j.SelectIndex end), try(function() return e.j.bShouldPlay end)
                    if idx then fsToGuests(string.format("CoopFS:juke:%d:%d:%d", id, idx, on and 1 or 0)) end
                end
                if fsMine.idx > 0 then fsToGuests("CoopFS:sit:" .. fsMine.idx) end
            end
        end
    end
end
function fsGuestIn()
    for _, m in ipairs(fsIn) do
        local sx, sy, sz, syaw = m:match("^CoopFS:seatpos:(-?%d+):(-?%d+):(-?%d+):(-?%d+)$")
        if sx then fsRem.x, fsRem.y, fsRem.z, fsRem.yaw = tonumber(sx), tonumber(sy), tonumber(sz), tonumber(syaw) end
        local s = m:match("^CoopFS:sit:(%d+)$")
        if s then fsApplySit(false, tonumber(s)) end
        local y, pt, px = m:match("^CoopFS:head:(-?%d+):(-?%d+):(%d)$")
        if y then fsApplyHead(false, tonumber(y), tonumber(pt), px == "1") end
        if m == "CoopFS:stand" then fsApplyStand(false) end
        local id, idx, on = m:match("^CoopFS:juke:(%d+):(%d+):(%d)$")
        if id then fsApplyJuke(tonumber(id), tonumber(idx), on == "1") end
    end
end
-- Piano (11-07, see CoopNative "Piano"): the game plays a key only on the pianist's PC (PoseChise on his animation, SE_PIANO_KEY_* on the piano camera's AkComponent).
-- CoopNative hears our own notes (PostAkEvent hook) and plays the other player's on our piano camera, with the hand pose on our copy of him. Lua gives it the
-- objects (CoopNative.piano), sends our presses (CoopNative.pianoout) and hands over the host's ("CoopFS:piano:<ms/4 mod 2048>:<mask>", CoopNative.pianoin).
-- The guest -> host way is Server_AddExp kind 12 (t4 * 8192 + mask), which CoopNative on the host takes itself. The guest's piano camera never gets his input
-- (no possession), so for him CoopNative reads the keys of the 13 actions, from his own key mappings.
PN_SEAT = 10
PN_DIR = "/Game/Sound/Environment/Base01/PIANO/"
PN_NOTES = {"RE_D4", "MI_E4", "FA_F4", "SO_G4", "RA_A4", "SI_B4", "DO_C5", "RE_D5", "MI_E5", "FA_F5", "SO_G5", "RA_A5", "SI_B5"}
PN_ACTIONS = {"Trigger_L2", "Trigger_L1", "Direction_Left", "Direction_Up", "Direction_Right", "FaceButton_Left", "FaceButton_Top", "Decide", "Trigger_R1",
              "Trigger_R2", "Direction_Down", "Trigger_L3", "Trigger_R3"}
-- DefaultInput.ini, if the game has no mappings to read
PN_DEFAULT_KEYS = {{"Gamepad_LeftTrigger"}, {"Gamepad_LeftShoulder"}, {"Gamepad_DPad_Left", "Left"}, {"Gamepad_DPad_Up", "Up"}, {"Gamepad_DPad_Right", "Right"},
                   {"Gamepad_FaceButton_Left", "J"}, {"Gamepad_FaceButton_Top", "I"}, {"Gamepad_FaceButton_Right", "E", "Enter"}, {"Gamepad_RightShoulder"},
                   {"Gamepad_RightTrigger"}, {"Gamepad_DPad_Down", "Down"}, {"Gamepad_LeftThumbstick"}, {"Gamepad_RightThumbstick"}}
PN_ABP = FS_DIR .. "Base_PianoChair/ABP_ScenarioChara_SittingPianoChair.ABP_ScenarioChara_SittingPianoChair_C"
pnBase, pnTryAt, pnSent, pnSentId, pnRecOn, pnHost, pnKeys, pnSentN, pnErr = nil, 0, nil, 0, false, false, nil, 0, false
function pnPoseOffset(cls)
    local off
    pcall(function()
        cls:ForEachProperty(function(p)
            if p:GetFName():ToString() == "PoseChise" then off = p:GetOffset_Internal(); return true end
        end)
    end)
    if not off then
        local p = StaticFindObject(PN_ABP .. ":PoseChise")
        if valid(p) then off = try(function() return p:GetOffset_Internal() end) end
    end
    return off
end
function pnSetup()
    local cam = FindFirstOf("BP_SittingPianoChair_Camera_C")
    if not valid(cam) then return nil end
    local ak = try(function() return cam.Ak end)
    local akA = valid(ak) and try(function() return ak:GetAddress() end) or nil
    local ev = {}
    for i, n in ipairs(PN_NOTES) do
        local e = StaticFindObject(PN_DIR .. "SE_PIANO_KEY_" .. n .. "_Play.SE_PIANO_KEY_" .. n .. "_Play")
        ev[i] = valid(e) and try(function() return e:GetAddress() end) or nil
        if not ev[i] then log("piano: note " .. n .. " not loaded"); return nil end
    end
    local cls = StaticFindObject(PN_ABP)
    local clsA = valid(cls) and try(function() return cls:GetAddress() end) or nil
    local off = valid(cls) and pnPoseOffset(cls) or nil
    if not akA or not clsA then log("piano: no camera component (" .. tostring(akA) .. ") or animation class (" .. tostring(clsA) .. ")"); return nil end
    log(string.format("piano: found the piano (camera %s), 13 notes, hand pose at +0x%X", name(cam), off or 0))
    return { ak = akA, ev = ev, cls = clsA, off = off or 0 }
end
function pnKeyLines(pc)
    local want, lines, src = {}, {}, "defaults"
    for i, a in ipairs(PN_ACTIONS) do want[a] = i end
    local function scan(arr)
        local n = 0
        pcall(function()
            arr:ForEach(function(_, el)
                local m = el:get()
                local an = try(function() return m.ActionName:ToString() end)
                local kn = try(function() return m.Key.KeyName:ToString() end)
                local i = an and want[an]
                if i and kn and kn ~= "None" then lines[#lines + 1] = "key " .. (i - 1) .. " " .. kn; n = n + 1 end
            end)
        end)
        return n
    end
    local pi = valid(pc) and try(function() return pc.PlayerInput end) or nil
    if valid(pi) and scan(pi.ActionMappings) > 0 then src = "the player's mappings" end
    if #lines == 0 then
        local is = StaticFindObject("/Script/Engine.Default__InputSettings")
        if valid(is) and scan(is.ActionMappings) > 0 then src = "the input settings" end
    end
    if #lines == 0 then
        for i, ks in ipairs(PN_DEFAULT_KEYS) do for _, k in ipairs(ks) do lines[#lines + 1] = "key " .. (i - 1) .. " " .. k end end
    end
    local shown = {}
    for _, l in ipairs(lines) do
        local i, k = l:match("^key (%d+) (%S+)$")
        local a = PN_ACTIONS[tonumber(i) + 1]
        shown[a] = (shown[a] and shown[a] .. "/" or "") .. k
    end
    local s = {}
    for _, a in ipairs(PN_ACTIONS) do s[#s + 1] = a .. "=" .. (shown[a] or "-") end
    log("piano: our keys from " .. src .. ": " .. table.concat(s, " "))
    return lines
end
function pnWrite(lines, what)
    local text = table.concat(lines, "\n") .. "\n"
    if text == pnSent then return end
    pnSent = text
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.piano", "w")
    if f then f:write(text); f:close() end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write("piano\n"); c:close() end
    log("piano: " .. what)
end
function pnMaxOutId()
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.pianoout", "r")
    if not f then return 0 end
    local text = f:read("*a") or ""
    f:close()
    local mx = 0
    for id in text:gmatch("(%d+) %d+ %d+\n") do mx = math.max(mx, tonumber(id)) end
    return mx
end
-- Hands (11-09): the camera does more than PoseChise per press: Switcher alternates IsPianoPlay / IsPianoPlay2 = true (the animation's state machine enters the
-- playing state on it and clears the flag itself), OnSleep1 and SleepCancel keep it awake. CoopNative hands over every note it plays (CoopNative.pianofx).
pnFlip, pnFxN = false, 0
function pnPose(mask)
    local a, b
    for i = 0, 12 do
        if mask & (1 << i) ~= 0 then
            if not a then a = i elseif not b then b = i end
        end
    end
    if not a then return 0 end
    if not b then return a + 1 end
    local base = 13
    for i = 0, a - 1 do base = base + (12 - i) end
    return base + (b - a)
end
function pnHands(anim, mask, who)
    if not valid(anim) then return false end
    local pose = pnPose(mask)
    pnFlip = not pnFlip
    local okp = pcall(function() anim.PoseChise = pose end)
    local okf = pcall(function() if pnFlip then anim.IsPianoPlay = true else anim.IsPianoPlay2 = true end end)
    local oks = pcall(function() anim:SleepCancel() end)
    pnFxN = pnFxN + 1
    if pnFxN <= 12 or pnFxN % 40 == 0 then
        log(string.format("piano: hands %s: pose %d (%s), flag %s %s, SleepCancel %s | now play %s/%s pose %s", who, pose, tostring(okp), pnFlip and "IsPianoPlay" or "IsPianoPlay2", tostring(okf), tostring(oks),
            tostring(try(function() return anim.IsPianoPlay end)), tostring(try(function() return anim.IsPianoPlay2 end)), tostring(try(function() return anim.PoseChise end))))
    end
    return okp and okf
end
function pnFxTick(host, anim)
    local path = WIN64 .. "\\plugins\\CoopNative.pianofx"
    local take = path .. ".take"
    os.remove(take)
    if not os.rename(path, take) then return end
    local f = io.open(take, "r")
    if not f then return end
    local text = f:read("*a") or ""
    f:close()
    os.remove(take)
    local other
    for kind, mask in text:gmatch("(%a) (%d+)") do
        mask = tonumber(mask)
        if kind == "l" then
            pnHands(anim, mask, "ours")
        else
            if other == nil then
                local p = fsOther(host)
                local a = valid(p) and try(function() return p.Mesh:GetAnimInstance() end) or nil
                other = (valid(a) and name(a):find("SittingPianoChair", 1, true)) and a or false
            end
            if other then pnHands(other, mask, "the other player's") end
        end
    end
end
function pnTick(host, now, pc, anim, idx)
    pnHost = host
    if not pnBase then
        if now < pnTryAt then return end
        pnTryAt = now + 5
        pnBase = pnSetup()
        if not pnBase then return end
    end
    local mine = idx == PN_SEAT and not fsMine.standing
    local keys = mine and not host
    if mine or (fsRem.idx or 0) == PN_SEAT then
        local okx, ex = pcall(pnFxTick, host, anim)
        if not okx and not pnFxErr then pnFxErr = true; log("piano hands ERROR " .. tostring(ex):sub(1, 160)) end
    else
        os.remove(WIN64 .. "\\plugins\\CoopNative.pianofx")
    end
    if keys and not pnKeys then pnKeys = pnKeyLines(pc) end
    local ranim = 0
    if (fsRem.idx or 0) == PN_SEAT and not fsRem.standing then
        local p = fsOther(host)
        local a = valid(p) and try(function() return p.Mesh:GetAnimInstance() end) or nil
        if valid(a) and name(a):find("SittingPianoChair", 1, true) then ranim = try(function() return a:GetAddress() end) or 0 end
    end
    local manim = keys and valid(anim) and try(function() return anim:GetAddress() end) or 0
    if mine and not pnRecOn then pnSentId = pnMaxOutId() end
    pnRecOn = mine
    local L = { string.format("ak %X", pnBase.ak) }
    for i, a in ipairs(pnBase.ev) do L[#L + 1] = string.format("ev %d %X", i - 1, a) end
    L[#L + 1] = string.format("cls %X", pnBase.cls)
    L[#L + 1] = "off " .. pnBase.off
    L[#L + 1] = "rec " .. (mine and 1 or 0)
    L[#L + 1] = "keys " .. (keys and 1 or 0)
    L[#L + 1] = string.format("ranim %X", ranim)
    L[#L + 1] = string.format("manim %X", manim)
    if keys then for _, l in ipairs(pnKeys) do L[#L + 1] = l end end
    pnWrite(L, (mine and (keys and "we play (our keys read by CoopNative)" or "we play") or "we listen") .. (ranim ~= 0 and ", the other player is at the piano" or ""))
end
function pnClear()
    if pnSent then pnWrite({ "rec 0", "keys 0" }, "off (not in Home Base)") end
    pnBase, pnRecOn, pnSent, pnKeys, pnTryAt = nil, false, nil, nil, 0
end
function pnSendNew()
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.pianoout", "r")
    if not f then return end
    local text = f:read("*a") or ""
    f:close()
    local mx = 0
    for id in text:gmatch("(%d+) %d+ %d+\n") do mx = math.max(mx, tonumber(id)) end
    if mx < pnSentId then
        log("piano: press counter started over (" .. mx .. " < " .. pnSentId .. "): sending from the start")
        pnSentId = 0
    end
    for id, ms, mask in text:gmatch("(%d+) (%d+) (%d+)\n") do
        id = tonumber(id)
        if id > pnSentId then
            pnSentId = id
            local t4, m = (tonumber(ms) // 4) % 2048, tonumber(mask) % 8192
            if pnHost then fsToGuests(string.format("CoopFS:piano:%d:%d", t4, m)) else fsToHost(12, t4 * 8192 + m) end
            pnSentN = pnSentN + 1
            if pnSentN <= 10 or pnSentN % 50 == 0 then log("piano: press " .. id .. " sent (mask " .. m .. ", " .. pnSentN .. " so far)") end
        end
    end
end
-- Taken seats (owner 11-07: he could sit on the chair the other player was sitting on). While the other player sits (fsRem.idx > 0, until his "up" with seat 0,
-- so also during his getting-up animation) the seat trigger nearest to where his copy stood when he sat is closed on this PC (CoopNative "taken").
-- Picked once per sitting, from his position at the "sit" message (he stands at the trigger point then; the seat move comes 0.5 s later), retried each second
-- while none is found within 200.
fsTaken = { a = 0, idx = 0, tryAt = 0, sent = 0 }
function fsTakenSend(a, why)
    if a == fsTaken.sent then return end
    fsTaken.sent = a
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("taken %X\n", a)); c:close() end
    log("flavor: " .. why)
end
function fsTakenTick(host, now)
    local ri = fsRem.idx or 0
    if ri == 0 then
        fsTaken.a, fsTaken.idx = 0, 0
        fsTakenSend(0, "no seat taken by the other player")
        return
    end
    if fsTaken.idx == ri and (fsTaken.a ~= 0 or now < fsTaken.tryAt) then return end
    fsTaken.idx, fsTaken.tryAt = ri, now + 1
    local p = fsOther(host)
    local at = valid(p) and try(function() return p:K2_GetActorLocation() end) or nil
    if not at then return end
    local best, bd, bn = nil, 200 * 200, nil
    for _, q in ipairs(FindAllOf("FieldTriggerBase") or {}) do
        local n = valid(q) and name(q) or ""
        if n:find("FieldTriggerMessage_Sitting", 1, true) then
            -- the trigger point is the binding sphere (the prompt comes when the capsule touches it), not always the actor's root
            local ba = try(function() return q.BindingArea end)
            local l = (valid(ba) and try(function() return ba:K2_GetComponentLocation() end)) or try(function() return q:K2_GetActorLocation() end)
            if l then
                local d = (l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + ((l.Z - at.Z) * 0.5) ^ 2
                if d < bd then best, bd, bn = q, d, n end
            end
        end
    end
    if not best then return end
    fsTaken.a = try(function() return best:GetAddress() end) or 0
    if fsTaken.a ~= 0 then fsTakenSend(fsTaken.a, string.format("the other player sits at %s (%.0f away): closed for us", bn, math.sqrt(bd))) end
end
function pnIn(text)
    local t4, m = text:match("^CoopFS:piano:(%d+):(%d+)$")
    if not t4 then return end
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.pianoin", "a")
    if f then f:write("p " .. t4 .. " " .. m .. "\n"); f:close() end
end
function flavorSyncTick()
    if not FS_ON then return end
    local now = os.clock()
    if now - fsAt < 0.2 then return end
    fsAt = now
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) then return end
    local host = try(function() return gs.Role end) == 3
    if host then fsHostIn() else fsGuestIn() end
    fsIn = {}
    if fsRem.swapAt and now >= fsRem.swapAt then
        fsRem.swapAt = nil
        fsApplySit(fsRem.swapHost, 0)
    end
    if now - fsBaseAt > 1 then fsBaseAt = now; fsInBase = hbInBase() end
    if not fsInBase then
        if fsRem.idx ~= 0 then fsRem.idx = 0 end
        fsMine = { idx = 0, since = 0, sent = true }
        fsHello, fsJukeSeen = false, {}
        if fsSeatsSent then fsSeatsWrite("me 0\n", "cleared"); fsSeatsSent = nil end
        pcall(pnClear)
        if fsTaken.sent ~= 0 then pcall(fsTakenSend, 0, "no seat taken (not in Home Base)") end
        fsTaken.a, fsTaken.idx = 0, 0
        fsSeatsSince, fsMyChar = 0, nil
        fsSeatOn, fsTrigOff, fsSeatObjs, fsSeatSeen, fsSeatIn = {}, {}, {}, {}, nil
        fsRem.swapAt = nil
        fsHeadWrite(nil)
        return
    end
    if host and #fsGuests() == 0 then return end
    if not host and not fsHello then fsHello = true; fsToHost(8, 0) end
    if not host and not fsKitSent then fsKitSent = fsToHost(9, fsKitNumber()) end
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    if valid(pawn) and name(pawn):find("BP_Player", 1, true) then fsMyChar = pawn end
    pawn = fsMyChar
    if not valid(pawn) then return end
    fsSeatsTick(host, now)
    local m = try(function() return pawn.Mesh end)
    local anim = valid(m) and try(function() return m:GetAnimInstance() end) or nil
    if not valid(anim) then return end
    local idx = FS_INDEX[(name(anim):gsub("_%d+$", ""))] or 0
    pcall(fsGuestSeatTick, host, now, pc, idx)
    if idx ~= fsMine.idx then
        fsMine = { idx = idx, since = now, sent = idx == 0 }
        if idx == 0 then
            if host then fsToGuests("CoopFS:sit:0") else fsToHost(1, 0) end
            log("flavor: we stood up")
        else
            -- owner 11-07: the other screen should react to the press. The animation class changes the moment the seat takes us; the exact place comes 0.5 s later, with the sit again.
            if host then fsToGuests("CoopFS:sit:" .. idx) else fsToHost(1, idx) end
            log("flavor: we sit down, seat " .. idx)
            if not host then
                local at = try(function() return pawn:K2_GetActorLocation() end)
                local q, d, n = nil, nil, nil
                if at then q, d, n = fsNearestSeat(at, 250) end
                fsMySeat = q
                log("flavor: our seat is " .. tostring(n) .. (d and string.format(" (%.0f away)", d) or ""))
            end
        end
    end
    local okp, ep = pcall(pnTick, host, now, pc, anim, idx)
    if WSV and not trErr then
        local okq, eq = pcall(trigSurveyTick)
        if not okq then trErr = true; log("trigger survey ERROR " .. tostring(eq):sub(1, 160)) end
    end
    local okt, et = pcall(fsTakenTick, host, now)
    if not okt and not fsTakenErr then fsTakenErr = true; log("taken seats ERROR " .. tostring(et):sub(1, 160)) end
    if not okp and not pnErr then pnErr = true; log("piano ERROR " .. tostring(ep):sub(1, 160)) end
    if fsMine.idx > 0 and not fsMine.sent and now - fsMine.since >= 0.5 then   -- the seat move comes a moment after the animation
        fsMine.sent = true
        if host then
            local loc0 = try(function() return pawn:K2_GetActorLocation() end)
            local rot0 = try(function() return pawn:K2_GetActorRotation() end)
            if loc0 and rot0 then fsToGuests(string.format("CoopFS:seatpos:%d:%d:%d:%d", math.floor(loc0.X), math.floor(loc0.Y), math.floor(loc0.Z), math.floor(rot0.Yaw))) end
            fsToGuests("CoopFS:sit:" .. fsMine.idx)
        else
            local loc = try(function() return pawn:K2_GetActorLocation() end)
            local rot = try(function() return pawn:K2_GetActorRotation() end)
            if loc and rot then
                fsToHost(2, math.floor(loc.X) + 8388608)
                fsToHost(3, math.floor(loc.Y) + 8388608)
                fsToHost(4, math.floor(loc.Z) + 8388608)
                fsToHost(5, math.floor((rot.Yaw + 360) * 10))
            end
            fsToHost(1, fsMine.idx)
        end
        log("flavor: we sat down, seat " .. fsMine.idx)
        fsHeadY, fsHeadP = 100000, 100000
        os.remove(WIN64 .. "\\plugins\\CoopNative.stand")
    end
    if fsMine.idx > 0 and fsMine.sent then
        -- our camera, which is what the animation reads; 11-06 22:3x: DirectionYaw written from here was overwritten every frame
        local cmr = valid(pc) and try(function() return pc.PlayerCameraManager end) or nil
        local r = valid(cmr) and try(function() return cmr:GetCameraRotation() end) or nil
        local y, pt = r and try(function() return r.Yaw end), r and try(function() return r.Pitch end)
        local px = try(function() return anim.PressX end) == true
        if type(y) == "number" and type(pt) == "number" then
            y, pt = (y + 180) % 360 - 180, (pt + 180) % 360 - 180
            if math.abs(y - fsHeadY) > 2 or math.abs(pt - fsHeadP) > 2 or px ~= fsHeadX then
                fsHeadY, fsHeadP, fsHeadX = y, pt, px
                local yi, pi = math.floor(y), math.floor(pt)
                fsHeadLogs = fsHeadLogs + 1
                if fsHeadLogs <= 6 then log(string.format("flavor: head out: yaw %d pitch %d press %s", yi, pi, tostring(px))) end
                if host then fsToGuests(string.format("CoopFS:head:%d:%d:%d", yi, pi, px and 1 or 0))
                else fsToHost(6, (px and 4194304 or 0) + (yi + 512) * 2048 + pi + 512) end
            end
        end
        if type(y) ~= "number" and fsHeadLogs == 0 then
            fsHeadLogs = 1
            log("flavor: no camera numbers: manager " .. tostring(valid(cmr)) .. ", rotation " .. tostring(r))
        end
        local sf = not fsMine.standing and io.open(WIN64 .. "\\plugins\\CoopNative.stand", "r")
        if sf then sf:close(); os.remove(WIN64 .. "\\plugins\\CoopNative.stand") end
        if not fsMine.standing and (sf or try(function() return anim.isSittingEnd end) == true) then
            fsMine.standing, fsMine.standAt = true, now
            if host then fsToGuests("CoopFS:stand") else fsToHost(10, 0) end
            log("flavor: we are standing up")
        end
    end
    if now - fsJukeAt > 0.5 then
        fsJukeAt = now
        for id, e in ipairs(fsJukes()) do
            local jx, on = try(function() return e.j.SelectIndex end), try(function() return e.j.bShouldPlay end)
            if type(jx) == "number" then
                local key = jx .. ":" .. tostring(on == true)
                if fsJukeSeen[id] == nil then fsJukeSeen[id] = key
                elseif key ~= fsJukeSeen[id] then
                    fsJukeSeen[id] = key
                    if host then fsToGuests(string.format("CoopFS:juke:%d:%d:%d", id, jx, on and 1 or 0)) else fsToHost(7, id * 4096 + jx * 2 + (on and 1 or 0)) end
                    log("flavor: our jukebox " .. e.n .. " -> track " .. jx .. ", " .. (on and "on" or "off"))
                end
            end
        end
    end
end
local function guestRestRequest()
    local f = io.open(RESTREQ, "r"); if not f then return end
    f:close(); os.remove(RESTREQ)
    local okc, comp = pcall(writeMyComponent)
    -- item 6b (2026-10-30): ask the host for an enemy reset (its CoopNative takes Server_AddExp(-2601) as "the guest rested")
    if okc and valid(comp) then
        local oks = pcall(function() comp:Server_AddExp(-2601) end)
        log("guest rest: enemy reset asked from the host " .. tostring(oks))
    end
    local opened = openCheckpointMenu(1)
    disableUntil, disabledLogged = os.clock() + 3, false
    menuWatch = opened and true or false
    guestMenuOpenAt = opened and os.clock() or nil
    if opened then menuClosedAt = nil end
    if opened then pcall(fsToHost, 15, 1) end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if valid(mine) then
        local before = try(function() return helper:GetHealth(mine) end)
        local max = try(function() return helper:GetMaxHealth(mine) end)
        local ok = type(max) == "number" and pcall(function() helper:SetHealth(mine, max) end)
        healCheck = { p = mine, at = os.clock() }
        log("guest rest: menu " .. tostring(opened) .. ", health " .. tostring(before) .. " -> " .. tostring(max) .. " " .. (ok and "set" or "FAILED"))
    end
end
local function guestRestHealCheck()
    if not healCheck or os.clock() - healCheck.at < 3 then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    log("guest rest: health 3 s later " .. tostring(valid(healCheck.p) and try(function() return helper:GetHealth(healCheck.p) end)))
    healCheck = nil
end
-- Guest level-up: CoopNative noted a LevelUpPlayer(+N) on our side (it does not stick on a guest); ask the host to do it for our
-- character by sending Server_AddExp(0) once per level from our own HumanContextComponent.
local lvlWatch
local LEVELUP_FILE = WIN64 .. "\\plugins\\CoopNative.levelup"
local function guestLevelUpRelay()
    local f = io.open(LEVELUP_FILE, "r"); if not f then return end
    local n = tonumber((f:read("*a") or ""):match("%d+") or "0") or 0; f:close(); os.remove(LEVELUP_FILE)
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    local comp = ownHumanContext()
    local sent = 0
    if valid(comp) then
        for _ = 1, n do if pcall(function() comp:Server_AddExp(0) end) then sent = sent + 1 end end
    end
    log("guest level-up: +" .. n .. " asked the host (" .. sent .. " x Server_AddExp(0) from " .. (valid(comp) and name(comp) or "no component") .. ")")
    -- research (session 8): measure our component's level right away and over the next seconds (does it revert, and when?)
    if valid(comp) then lvlWatch = { a = try(function() return comp:GetAddress() end), at = os.clock(), step = 0 } end
end
-- Resync after the guest's Mistle menu (session 8): level, gifts and equipment are synced only once, at the join, per component
-- (ServerInitialDataSync; bIsInitialSynced). When his menu closes, clear the flags on his pawn and its components so the game sends
-- the initial sync again with his changed data; CoopNative logs the SYNC calls on both PCs.
local function resyncAfterMenu()
    if not menuWatch then return end
    local m = FindFirstOf("WDT_CheckpointMenu_C")
    -- IsMenuOpen stayed true after the menu was closed (update 35): use visibility, and log the state when it changes
    local st = valid(m) and (tostring(try(function() return m:IsMenuOpen() end)) .. "/" .. tostring(try(function() return m:IsMenuVisible() end)) ..
        "/" .. tostring(try(function() return m:GetVisibility() end))) or "gone"
    if st ~= lastMenuState then lastMenuState = st; log("guest rest: menu open/visible/visibility = " .. st) end
    local open = valid(m) and try(function() return m:IsMenuVisible() end)
    -- a submenu (level up etc.) hides the main menu: count as open while any checkpoint submenu is visible, and wait 2 s
    for _, cls in ipairs({ "WDT_LevelUpMenu_C", "WDT_KetsugiSkillReleaseMenu_C", "WDT_StorageMenu_C", "WDT_PresentBoxMenu_C", "WDT_TeleportMenu_C" }) do
        local sm = FindFirstOf(cls)
        if valid(sm) and try(function() return sm:IsMenuVisible() end) then open = true end
    end
    if open then menuClosedAt = nil; return end
    menuClosedAt = menuClosedAt or os.clock()
    if os.clock() - menuClosedAt < 2 then return end
    if guestMenuOpenAt and os.clock() - guestMenuOpenAt < 2.5 then menuClosedAt = nil; return end
    menuClosedAt = nil
    menuWatch = false
    guestMenuOpenAt = nil
    pcall(fsToHost, 15, 0)
    -- 11-06 22:21: the host's game had crashed, he was back in his own world and this resync still ran: the game's join-time sender never returned (realloc fatal error).
    -- Only with a host: the game state has role 1 on a guest and 3 when he is alone.
    local gsr = FindFirstOf("BP_AppGameState_C")
    if not valid(gsr) or tostring(try(function() return gsr.Role end)) ~= "1" then log("guest rest: no host any more, no resync"); return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return end
    local before = tostring(try(function() return mine.bIsInitialSynced end))
    local ok = pcall(function() mine.bIsInitialSynced = false end)
    -- only our own components (update 37 walked every AppActorComponent in the world and UE4SS crashed)
    local n = 0
    local cls = StaticFindObject("/Script/Extensions.AppActorComponent")
    local comps = valid(cls) and try(function() return mine:GetComponentsByClass(cls) end) or {}
    for _, c in ipairs(comps) do
        local cc = try(function() return c:get() end) or c
        if valid(cc) and pcall(function() cc.bIsInitialSynced = false end) then n = n + 1 end
    end
    log("guest rest: menu closed -> resync: character flag " .. before .. " -> false (" .. tostring(ok) .. "), " .. n .. " component flag(s) cleared")
    -- clearing the flags alone sends nothing (update 38): have CoopNative call the game's join-time sender on our pawn
    local addr = try(function() return mine:GetAddress() end)
    local f = addr and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if f then f:write(string.format("syncall %X\n", addr)); f:close() end
    log("guest rest: syncall " .. (f and "requested" or "FAILED"))
end
local LVL_STEPS = { 0, 1, 3, 6 }
local function guestLevelWatch()
    -- CoopNative writes CoopNative.lvlwatch after a redirected level-up: watch our own HumanContextComponent
    local wf = io.open(WIN64 .. "\\plugins\\CoopNative.lvlwatch", "r")
    if wf then
        wf:close(); os.remove(WIN64 .. "\\plugins\\CoopNative.lvlwatch")
        local pc = localPC()
        local mine = valid(pc) and try(function() return pc.Pawn end) or nil
        local c = ownHumanContext()
        if c then lvlWatch = { a = try(function() return c:GetAddress() end), at = os.clock(), step = 0 } end
    end
    if not lvlWatch or not lvlWatch.a then return end
    local due = LVL_STEPS[lvlWatch.step + 1]
    if not due then lvlWatch = nil; return end
    if os.clock() - lvlWatch.at < due then return end
    lvlWatch.step = lvlWatch.step + 1
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if f then f:write(string.format("lvlinfo %X\n", lvlWatch.a)); f:close() end
end
-- Test helper (host, test copy only; session 10 prep): "bosshp1" in CoopProbe.cmd sets the bosses of the running fight to 1
-- health, so the next hit kills them through the normal death path. Boss lookup after Rikka230's CoopDevTools: the boss areas
-- whose CurrentPhase is 1 or 2 and their Enemies; if none is listed, every living spawned boss (a second phase is not listed).
local function bossesInFight()
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local found, fighting = {}, false
    for _, a in ipairs(FindAllOf("BossAreaBase") or {}) do
        local phase = valid(a) and try(function() return a.CurrentPhase end)
        if phase == 1 or phase == 2 then
            fighting = true
            pcall(function()
                a.Enemies:ForEach(function(_, e)
                    local x = e:get()
                    if valid(x) and try(function() return helper:IsBoss(x) end) and not try(function() return helper:IsDeath(x) end) then
                        found[#found + 1] = x
                    end
                end)
            end)
        end
    end
    if fighting and #found == 0 then
        for _, x in ipairs(FindAllOf("EnemyCommonBase") or {}) do
            if valid(x) and try(function() return helper:IsBoss(x) end) and not try(function() return helper:IsDeath(x) end) then
                found[#found + 1] = x
            end
        end
    end
    return found, helper
end
-- Guest in the post-boss cutscene (guest_outro=1, guest; session 10): the boss intro reaches the guest through the boss area's
-- MulticastExecuteFlowDiagramWithCallback(PrePhase1Event); the post-boss cutscene (FinishEvent, type 3) never started on his side.
-- When CoopNative reports the boss battle's finish (CoopNative.outro = the area's address), call the multicast with type 3 on that
-- area here: on a client a multicast called locally runs locally, so his game starts the same cutscene as the host.
local OUTRO_PATH = WIN64 .. "\\plugins\\CoopNative.outro"
do local f = io.open(OUTRO_PATH, "r"); if f then f:close(); os.remove(OUTRO_PATH) end end
-- Boss door after the kill (2026-11-03, owner: on the guest the fog wall at the boss room entrance stayed after the boss died;
-- in single player it is gone). When the guest's outro starts (the boss is dead), remember that boss area; from then on, for the
-- rest of the game run, every boss wall (ABossWallBase: BlockWall +0x380 blocking volume, MistWall +0x388) within 120 m of that
-- area is switched off every 3 s: mist off (SetStateMistWall false, OnDeactivate, DestructEffect, hidden) and the blocking
-- volume without collision. His own logic switched walls back on before, hence the repetition.
deadBossAreas, bossWallAt = {}, -1000
function bossWallsOff()
    if #deadBossAreas == 0 or os.clock() - bossWallAt < 1 then return end
    bossWallAt = os.clock()
    for _, w in ipairs(FindAllOf("BossWallBase") or {}) do
        local wl = valid(w) and try(function() return w:K2_GetActorLocation() end)
        local near = false
        if wl then
            for _, a in ipairs(deadBossAreas) do
                local dx, dy, dz = wl.X - a.X, wl.Y - a.Y, wl.Z - a.Z
                if dx * dx + dy * dy + dz * dz < 12000 * 12000 then near = true end
            end
        end
        if near then
            local mist = try(function() return w.MistWall end)
            local block = try(function() return w.BlockWall end)
            local changed = false
            if valid(mist) and (try(function() return mist.bProcessEnable end) ~= false or not try(function() return mist.bHidden end)) then
                pcall(function() mist:SetActorTickEnabled(true) end)
                pcall(function() mist:SetStateMistWall(false, true) end)
                pcall(function() mist:OnDeactivate(true) end)
                pcall(function() mist:DestructEffect() end)
                pcall(function() mist:SetActorHiddenInGame(true) end)
                changed = true
            end
            if valid(block) and try(function() return block:GetActorEnableCollision() end) ~= false then
                pcall(function() block:SetActorEnableCollision(false) end)
                changed = true
            end
            if changed then log("boss door: " .. name(w) .. " off (mist " .. (valid(mist) and name(mist) or "-") .. ", block " .. (valid(block) and name(block) or "-") .. ")") end
        end
    end
end
local function guestOutro()
    local f = io.open(OUTRO_PATH, "r"); if not f then return end
    local t = f:read("*a") or ""; f:close(); os.remove(OUTRO_PATH)
    if not iniHas("guest_outro=1") then return end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) == 3 then return end   -- guests only
    local want = tonumber(t:match("%x+") or "", 16)
    for _, a in ipairs(FindAllOf("BossAreaBase") or {}) do
        if valid(a) and try(function() return a:GetAddress() end) == want then
            local ok, e = pcall(function() a:MulticastExecuteFlowDiagramWithCallback(3) end)
            local al = try(function() return a:K2_GetActorLocation() end)
            if al then deadBossAreas[#deadBossAreas + 1] = { X = al.X, Y = al.Y, Z = al.Z }; log("boss door: " .. name(a) .. " is done, its walls go off") end
            log("guest outro: " .. name(a) .. ":MulticastExecuteFlowDiagramWithCallback(FinishEvent) -> " .. (ok and "called" or ("ERROR " .. tostring(e):sub(1, 140))))
            return
        end
    end
    log("guest outro: boss area 0x" .. t .. " not found")
end
-- Test start position (owner, 2026-11-03): walking to the boss took long. test_mark=X,Y,Z in CoopNative.ini; with
-- test_mark_autotp=1 our character is moved there once per game run, 8 s after it first appears; "tp" in CoopProbe.cmd any time.
-- Blood code sync (2026-11-03, owner: after the boss the guest saw the "blood code acquired" message, but the code was not in
-- his list; the Get_<X>BC flag alone does not unlock it). The host watches its own acquired blood codes
-- (CharacterHelper:GetAcquiredBloodCodeList) and sends every new one by asset path (ClientMessage "CoopBC:<path>"); the guest
-- loads that asset and calls CharacterHelper:AcquireBloodCode(his character, article, forced, no indication).
bcKnown, bcAt, bcIn = nil, -1000, {}
-- entries may come wrapped (RemoteUnrealParam): unwrap with :get()
local function bcObj(v)
    if valid(v) then return v end
    local g = try(function() return v:get() end)
    if valid(g) then return g end
    return nil
end
local function bcPath(a)
    local full = try(function() return a:GetFullName() end)
    return full and full:match("^%S+%s+(.+)$") or full
end
function bloodCodeSyncHost()
    if os.clock() - bcAt < 2 then return end
    bcAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local ok, list = pcall(function() return helper:GetAcquiredBloodCodeList(mine) end)
    local now = {}
    -- (2026-11-03: nothing was logged; the result may be a Lua table or a TArray object, and the call may need an out table)
    if ok and type(list) == "table" then
        for _, v in pairs(list) do local a = bcObj(v); local pth = a and bcPath(a); if pth then now[pth] = true end end
    elseif ok and list then
        pcall(function() list:ForEach(function(_, e) local a = e:get(); local pth = valid(a) and bcPath(a); if pth then now[pth] = true end end) end)
    end
    if next(now) == nil then
        local out = {}
        pcall(function() helper:GetAcquiredBloodCodeList(mine, out) end)
        local arr = out.ReturnValue or out[1]
        if type(arr) == "table" then for _, a in pairs(arr) do local pth = valid(a) and bcPath(a); if pth then now[pth] = true end end
        elseif arr then pcall(function() arr:ForEach(function(_, e) local a = e:get(); local pth = valid(a) and bcPath(a); if pth then now[pth] = true end end) end) end
    end
    if next(now) == nil then
        if not bcWarned then
            bcWarned = true
            local n, first = 0, nil
            if type(list) == "table" then for k, v in pairs(list) do n = n + 1; if not first then first = tostring(k) .. ":" .. type(v) .. ":" .. tostring(v) end end end
            log("blood code sync: list unreadable (call ok=" .. tostring(ok) .. ", type " .. type(list) .. ", " .. n .. " entries, first " .. tostring(first) .. ")")
        end
        return
    end
    if not bcKnown then
        local n = 0
        for _ in pairs(now) do n = n + 1 end
        bcKnown = now
        log("blood code sync: " .. n .. " codes known at the start")
        return
    end
    for pth in pairs(now) do
        if not bcKnown[pth] then
            bcKnown[pth] = true
            for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(c) and not try(function() return c:IsLocalController() end) then
                    pcall(function() c:ClientMessage("CoopBC:" .. pth, FName("None"), 0) end)
                end
            end
            log("blood code sync: new blood code " .. pth .. " -> sent to the guests")
        end
    end
end
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text and text:find("^CoopBC:") then bcIn[#bcIn + 1] = text:sub(8) end
    end)
end)
function bloodCodeSyncGuest()
    if #bcIn == 0 then return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return end
    -- (2026-11-03: unlocked during the host's final cutscene, the game showed no message) -> wait only while we cannot move;
    -- otherwise unlock at once, so the message comes at the host's moment like in vanilla (the 2 s wait felt late, owner)
    if try(function() return pc:IsMoveInputIgnored() end) ~= false then return end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    for _, pth in ipairs(bcIn) do
        local a = StaticFindObject(pth)
        if not valid(a) then pcall(function() a = LoadAsset(pth) end) end
        local had = valid(a) and try(function() return helper:IsAcquiredBloodCode(mine, a) end)
        local ok = valid(a) and not had and pcall(function() helper:AcquireBloodCode(mine, a, true, false) end)   -- with the game's message (owner 2026-11-03)
        log("blood code sync: " .. pth .. (not valid(a) and " NOT FOUND" or (had and " already acquired" or (" acquired " .. tostring(ok)))))
    end
    bcIn = {}
end
-- Chest loot for the guest (R8 step 1, 2026-11-04). The host watches the chests' ChestState (0 closed, 1 opening, 2 opened); when one
-- leaves 0, its fixed contents go to the guests by asset path (ClientMessage "CoopChest:<chest>|<class>|<path>|<count>|<degeneration>|
-- <grind>"). Weapons and blood veils have their own functions; RPCClient_GainItem crashes on them (test 19:48). Entries with a
-- weight under 100 or a progress symbol may be random or conditional: logged and skipped until we know how they work.
chestSeen, chestAt, chestIn, chestGot = {}, -1000, {}, {}
function chestSyncHost()
    if os.clock() - chestAt < 2 then return end
    chestAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    for _, ch in ipairs(FindAllOf("BP_ItemBox_C") or {}) do
        local n = valid(ch) and name(ch)
        local st = n and try(function() return ch.ChestState end)
        if st ~= nil then
            local old = chestSeen[n]
            chestSeen[n] = st
            if old == 0 and st ~= 0 then
                local guests = {}
                for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                    if valid(c) and not try(function() return c:IsLocalController() end) then guests[#guests + 1] = c end
                end
                local sent, skipped = 0, 0
                pcall(function()
                    ch.SpawnItemInfos:ForEach(function(_, x)
                        local r = x:get()
                        local art = try(function() return r.ItemArticle end)
                        local weight = try(function() return r.Weight end) or 0
                        local sym = try(function() return r.DropProgressSymbol:ToString() end) or ""
                        local pth = valid(art) and bcPath(art)
                        if pth and weight >= 100 and sym == "" then
                            local msg = string.format("CoopChest:%s|%s|%s|%s|%s|%s", n, tostring(try(function() return name(art:GetClass()) end)), pth,
                                tostring(try(function() return r.ItemCount end) or 1), tostring(try(function() return r.DegenerationType end) or 0),
                                tostring(try(function() return r.Grind end) or 0))
                            for _, c in ipairs(guests) do pcall(function() c:ClientMessage(msg, FName("None"), 0) end) end
                            sent = sent + 1
                        else
                            skipped = skipped + 1
                            log("chest sync: " .. n .. " entry skipped: " .. tostring(pth) .. " weight=" .. tostring(weight) .. " sym=" .. sym)
                        end
                    end)
                end)
                log("chest sync: " .. n .. " opened (state " .. tostring(st) .. "): " .. sent .. " entries to " .. #guests .. " guest(s), " .. skipped .. " skipped")
            end
        end
    end
end
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, s)
        local text = try(function() return s:get():ToString() end)
        if text and text:find("^CoopChest:") then chestIn[#chestIn + 1] = text:sub(11) end
    end)
end)
function chestSyncGuest()
    if #chestIn == 0 then return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then return end
    if try(function() return pc:IsMoveInputIgnored() end) ~= false then return end   -- in a cutscene the game shows no message
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    for _, line in ipairs(chestIn) do
        local chest, cls, pth, cnt, deg, grind = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        local key = tostring(chest) .. "|" .. tostring(pth)
        if not pth then log("chest sync: bad line " .. line:sub(1, 120))
        elseif chestGot[key] then log("chest sync: " .. key .. " already received")
        else
            chestGot[key] = true
            local a = StaticFindObject(pth)
            if not valid(a) then pcall(function() a = LoadAsset(pth) end) end
            local n, d, g = tonumber(cnt) or 1, tonumber(deg) or 0, tonumber(grind) or 0
            local ok, e = false, "article not found"
            if valid(a) then
                if cls:find("Weapon", 1, true) then ok, e = pcall(function() helper:UpdateWeaponInventoryInfo(mine, a, n, d, g, false) end)
                elseif cls:find("Jinkaku", 1, true) then ok, e = pcall(function() helper:UpdateJinkakuInventoryInfo(mine, a, n, d, g, false) end)
                elseif cls:find("Item", 1, true) then ok, e = pcall(function() helper:GainItem(mine, a, n) end)
                else e = "unknown class " .. cls end
            end
            log("chest sync: " .. pth .. " x" .. n .. " from " .. chest .. " -> " .. (ok and "received" or ("FAILED " .. tostring(e):sub(1, 120))))
        end
    end
    chestIn = {}
end
-- Cutscene sync trace (2026-11-05, log only): CoopNative samples the scenario manager's ready flags, it only needs the address.
sceneMgrAt, sceneMgrSent = -1000, nil
function sceneMgrSend()
    if not iniHas("scene_trace=1") or os.clock() - sceneMgrAt < 5 then return end
    sceneMgrAt = os.clock()
    local m = FindFirstOf("ScenarioManager")
    local ad = valid(m) and try(function() return m:GetAddress() end)
    if not ad or ad == sceneMgrSent then return end
    sceneMgrSent = ad
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write(string.format("scenmgr %X\n", ad)); c:close() end
    log(string.format("scene flags: manager %X %s", ad, name(m)))
end
-- Co-op version on the title screen (owner 2026-11-03: to see that both PCs run the same kit). The game's version text on the
-- title gets "  /  co-op <kit>" appended (plugins\\CoopKitVersion.txt).
-- v2 (2026-11-03, after title-screen crashes inside UE4SS): no search while menus are being built. Every 2 s only a cheap check
-- whether the title menu component exists; once it has existed for 5 s, ONE pass over the text blocks; at most 3 passes per
-- title visit, and nothing while a world (our player character) exists. The first pass logs the title's texts once.
titleVerAt, titleVerLogged, titleSeenAt, titlePasses, titleDone = -1000, false, nil, 0, false
function titleVersion()
    if titleDone or os.clock() - titleVerAt < 2 then return end
    titleVerAt = os.clock()
    local tm = FindFirstOf("TitleMenuUIComponent")
    if not valid(tm) then titleSeenAt, titlePasses = nil, 0; return end
    titleSeenAt = titleSeenAt or os.clock()
    -- it did not show up in the first passes on 11-03, so it may be filled later: a pass every 10 s, 6 at most
    if os.clock() - titleSeenAt < 5 or titlePasses >= 6 or os.clock() < (titleNextAt or 0) then return end
    titleNextAt = os.clock() + 10
    titlePasses = titlePasses + 1
    if titlePasses == 6 then log("title version: last pass, the version line was not found in any text block so far") end
    local vf = io.open(WIN64 .. "\\plugins\\CoopKitVersion.txt", "r")
    local ver = vf and (vf:read("*l") or ""):gsub("CodeVein%-guest%-update%-", ""):gsub("%.zip", ""):gsub("%s", "") or "?"
    if vf then vf:close() end
    local seen = {}
    for _, tb in ipairs(FindAllOf("TextBlock") or {}) do
        local txt = valid(tb) and try(function() return tb:GetText():ToString() end)
        if txt and txt ~= "" then
            -- only what is really on screen (2026-11-04: the line changed so far was never seen on the title)
            local vis = try(function() return tb:IsVisible() end)
            if not titleVerLogged and vis == true and #seen < 60 then seen[#seen + 1] = name(tb) .. "=" .. txt:sub(1, 40) end
            if txt:find("co-op", 1, true) then titleDone = true
            -- the real line is "Game client ver. 1.53.93354" (owner 2026-11-04); "Version: First Blood" was another text
            -- 19:15 test: no text block holds that line, so the version goes behind the copyright line the owner can see
            elseif #txt < 60 and (txt:lower():find("ver%.%s*%d") or txt:find("BANDAI NAMCO", 1, true)) then
                local ok = pcall(function() tb:SetText(FText(txt .. "  /  co-op " .. ver)) end)
                log("title version: '" .. txt .. "' -> co-op " .. ver .. " " .. tostring(ok) .. " visible=" .. tostring(vis) .. " " .. tostring(try(function() return tb:GetFullName() end)):sub(1, 160))
                if ok then titleDone = true end
            end
        end
    end
    if not titleVerLogged then titleVerLogged = true; log("title version: pass " .. titlePasses .. ", texts: " .. table.concat(seen, " | "):sub(1, 3000)) end
end
function teleportToMark(why)
    local v = iniValue("test_mark")
    if not v then log("tp: no test_mark in CoopNative.ini"); return end
    -- (2026-11-03: "v and v:match(...)" kept only the first capture -> y/z nil -> the log line failed inside pcall, silently)
    local x, y, z = v:match("(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)")
    if not z then log("tp: test_mark unreadable: " .. tostring(v)); return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) then log("tp: no character"); return end
    local rot = try(function() return mine:K2_GetActorRotation() end) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok = pcall(function() mine:K2_TeleportTo({ X = tonumber(x), Y = tonumber(y), Z = tonumber(z) + 50 }, rot) end)
    log("tp (" .. why .. "): " .. name(mine) .. " -> " .. x .. "," .. y .. "," .. z .. " " .. tostring(ok))
end
autoTpDone, autoTpSeen = false, nil
function autoTeleportToMark()
    if autoTpDone or not iniHas("test_mark_autotp=1") then return end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not (valid(mine) and name(mine):find("BP_Player_C", 1, true)) then return end
    autoTpSeen = autoTpSeen or os.clock()
    if os.clock() - autoTpSeen < 8 then return end
    autoTpDone = true
    local okt, et = pcall(teleportToMark, "save loaded")
    if not okt then log("tp ERROR " .. tostring(et):sub(1, 160)) end
end
-- 2026-11-03: UE4SS crashed inside its object hash tables (+0xC77xxx) on the title screen and while loading, more often since
-- the per-second object searches grew. The world-only checks in probeCommands run only while our own player character exists.
-- Trigger survey (11-09, walls_survey=1): 11-09 20:04 the host could not talk to NPCs or open the appearance editor after the stage trip. Every 2 s in Home Base:
-- the field triggers within 4 m of us that are not seats, on change: state, gimmick, message flag, overlap, button, what our trigger component has elected.
trSeen, trAt, trLines = {}, 0, 0
function trigSurveyTick()
    if not WSV or not fsInBase or not valid(fsMyChar) then return end
    local now = os.clock()
    if now - trAt < 2 or now < hbUntil + 10 then return end
    trAt = now
    local at = try(function() return fsMyChar:K2_GetActorLocation() end)
    if not at then return end
    local tcl = StaticFindObject("/Script/Extensions.FieldTriggerActionComponent")
    local c = valid(tcl) and try(function() return fsMyChar:GetComponentByClass(tcl) end)
    local tg = valid(c) and try(function() return c:GetTargetFieldTrigger() end)
    local tgn = valid(tg) and name(tg) or "none"
    local ex = tostring(valid(c) and try(function() return c:ExistActionButton() end))
    local tick = tostring(valid(c) and try(function() return c:IsComponentTickEnabled() end))
    local ckey = "component:" .. tgn .. "/" .. ex .. "/" .. tick
    if trSeen.__c ~= ckey then
        trSeen.__c = ckey
        trLines = trLines + 1
        if trLines <= 300 then log(string.format("triggers: our trigger component (%s): target %s, button shown %s, tick %s", name(fsMyChar), tgn, ex, tick)) end
    end
    for _, q in ipairs(FindAllOf("FieldTriggerBase") or {}) do
        if valid(q) then
            local n = name(q)
            if not n:find("Sitting", 1, true) then
                local l = try(function() return q:K2_GetActorLocation() end)
                if l then
                    local d = math.sqrt((l.X - at.X) ^ 2 + (l.Y - at.Y) ^ 2 + (l.Z - at.Z) ^ 2)
                    if d < 400 then
                        local ba = try(function() return q.BindingArea end)
                        local over = valid(ba) and try(function() return ba:IsOverlappingActor(fsMyChar) end)
                        local key = table.concat({ tostring(try(function() return q.State end)), tostring(try(function() return q.bGimmickVisibility end)),
                            tostring(try(function() return q.bCanShowMessage end) == true), tostring(over), tostring(try(function() return q:IsActionButtonActive(fsMyChar) end)),
                            tostring(try(function() return q.bHidden end)), tgn == n and "elected" or "-" }, "/")
                        if trSeen[n] ~= key then
                            trSeen[n] = key
                            trLines = trLines + 1
                            if trLines <= 300 then
                                log(string.format("triggers: %s (%.0f cm): state/gimmick/canShow/overlap/active/hidden/target = %s | class %s", n, d, key, name(q:GetClass())))
                            end
                        end
                    end
                end
            end
        end
    end
end
-- Co-op fog (fog_open=1, both PCs; 11-10): BP_BarrierWall with ForMultiplay (the *_Multi walls; mist + blocking collision only, no level volumes) switch themselves on within
-- about 60-96 m of a player. Switched off here every second: the barrier (SetStateBarrierWall false), its mist (SetStateMistWall false, hidden), the blocking collision, and the wall's tick
-- stopped so its distance logic does not switch it on again. CoopNative fog_free=1 lets the area-entry check pass for the field change that follows.
fogAt, fogLines, fogDone = 0, 0, {}
fogQuietUntil = 0
function fogQuiet(sec)
    fogQuietUntil = math.max(fogQuietUntil, os.clock() + sec)
end
function fogOpenTick()
    local now = os.clock()
    if now - fogAt < 1 or now < hbUntil + 10 then return end
    fogAt = now
    for _, w in ipairs(FindAllOf("BP_BarrierWall_C") or {}) do
        if valid(w) and try(function() return w.ForMultiplay end) == true then
            local n = name(w)
            local mist = try(function() return w.MistWall end)
            local mon = valid(mist) and try(function() return mist.bProcessEnable end)
            local iw = try(function() return w.InvisibleWall end)
            local col = valid(iw) and try(function() return iw:GetCollisionEnabled() end)
            if mon == true or (type(col) == "number" and col ~= 0) then
                pcall(function() w:SetStateBarrierWall(false) end)
                if valid(mist) then
                    pcall(function() mist:SetStateMistWall(false, true) end)
                    pcall(function() mist:OnDeactivate(true) end)
                    pcall(function() mist:SetActorHiddenInGame(true) end)
                end
                if valid(iw) then pcall(function() iw:SetCollisionEnabled(0) end) end
                fogDone[n] = (fogDone[n] or 0) + 1
                fogLines = fogLines + 1
                if fogLines <= 60 then
                    log(string.format("fog: %s switched off (mist %s, collision %s), now mist %s, collision %s (%d times)", n, tostring(mon), tostring(col),
                        tostring(valid(mist) and try(function() return mist.bProcessEnable end)), tostring(valid(iw) and try(function() return iw:GetCollisionEnabled() end)), fogDone[n]))
                end
            end
        end
    end
end
lvlAt, lvlPawn, lvlLines = 0, nil, 0
function lvlWatchTick(force)
    local now = os.clock()
    if not force and (now < hbUntil + 10 or (fogQuietUntil and now < fogQuietUntil - 50)) then return end
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local pa = valid(pawn) and name(pawn):find("BP_Player", 1, true) and try(function() return pawn:GetAddress() end) or nil
    if not pa then return end
    local due = 15
    if pa ~= lvlPawn then lvlPawn, lvlAt = pa, now - 15 + 6 end   -- a new character: look again in 6 s
    if now - lvlAt < due then return end
    lvlAt = now
    local addrs, who = {}, {}
    for _, comp in ipairs(FindAllOf("HumanContextComponent") or {}) do
        local o = valid(comp) and try(function() return comp:GetOwner() end)
        if valid(o) and name(o):find("BP_Player_C", 1, true) then
            local a = try(function() return comp:GetAddress() end)
            if a then
                addrs[#addrs + 1] = string.format("%X", a)
                who[#who + 1] = string.format("%s=0x%X%s", name(o), a, (try(function() return o:GetAddress() end) == pa) and "(ours)" or "")
            end
        end
    end
    if #addrs == 0 then return end
    lvlLines = lvlLines + 1
    if lvlLines <= 200 then
        log("level watch: " .. table.concat(who, " "))
        local f = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
        if f then f:write("lvlinfo " .. table.concat(addrs, " ") .. "\n"); f:close() end
    end
end
-- Fog streaming v2 (11-12 research; fog_stream=1). Owner's rule: Area 2 | tunnel | Area 1, a co-op fog wall at each end; Area 1 loads (and Area 2
-- unloads) only where the players are, on every area. Unreal leaves streaming volumes to the server (WorldSettings bUseClientSideLevelStreamingVolumes
-- = false, read on the host 11-12): the HOST's game evaluates the volumes for every player's view and tells each guest's PC which levels to load. In
-- co-op the volumes beyond the walls are switched off (11-12: re-enabling them on the guest's PC changed nothing, and the game switched them off
-- again). So only the host acts: once any player is within 120 m of a co-op wall, it asks CoopNative "vols" which volumes contain each player (one
-- player per second, in turn) and has CoopNative switch a disabled one on ("lsvon": the game's own enabled/force bytes, logged with the raw flags).
-- The engine then streams for every player like in single player and tells the guests' PCs. Never touches LevelStreaming flags. Quiet during group
-- teleports and Home Base flows, in Home Base and 10 s after our new character; off again with our next new character until a player is near a wall.
-- On a guest: only notes whether he is near a co-op wall (the level streaming log of ClientUpdateLevelStreamingStatus is on there).
fsvAt, fsvPending, fsvMap, fsvOn, fsvPawn, fsvPawnAt, fsvAskAt, fsvTurn, fsvWho, lsNear = 0, false, nil, false, nil, 0, 0, 0, "?", false
local function fsvWalls()
    local walls = {}
    for _, w in ipairs(FindAllOf("BP_BarrierWall_C") or {}) do
        if valid(w) and try(function() return w.ForMultiplay end) == true then
            local l = try(function() return w:K2_GetActorLocation() end)
            if l then walls[#walls + 1] = { n = name(w), l = l } end
        end
    end
    return walls
end
local function fsvNear(walls, p, r)
    local pl = valid(p) and try(function() return p:K2_GetActorLocation() end)
    if not pl then return nil end
    for _, w in ipairs(walls) do
        if (w.l.X - pl.X) ^ 2 + (w.l.Y - pl.Y) ^ 2 + (w.l.Z - pl.Z) ^ 2 < r * r then return w.n end
    end
    return nil
end
function fogStreamTick()
    local now = os.clock()
    if now - fsvAt < 1 then return end
    fsvAt = now
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    if not valid(mine) or not name(mine):find("BP_Player", 1, true) then return end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then
        if now - fsvAskAt >= 2 then
            fsvAskAt = now
            local wn = fsvNear(fsvWalls(), mine, 15000)
            if (wn ~= nil) ~= lsNear then lsNear = wn ~= nil; log("fog: " .. (lsNear and ("near " .. wn .. " -> logging what the host tells us to load") or "away from the co-op walls")) end
        end
        return
    end
    if now < hbUntil + 10 or hbAskPending or hbInBase() or pendingTp then fsvPending = false; return end
    local ma = try(function() return mine:GetAddress() end)
    if ma ~= fsvPawn then
        if fsvOn then log("fog streaming: our new character -> off until a player is near a co-op wall again") end
        fsvPawn, fsvPawnAt, fsvOn, fsvPending, fsvMap = ma, now, false, false, nil
    end
    if now - fsvPawnAt < 10 then return end
    local players = { mine }
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            local g = try(function() return c.Pawn end)
            if valid(g) and name(g):find("BP_Player", 1, true) then players[#players + 1] = g end
        end
    end
    if fsvPending then
        local f = io.open(WIN64 .. "\\plugins\\CoopNative.volsout", "r")
        local s = f and (f:read("*a") or "") or ""
        if f then f:close() end
        if not s:find("done", 1, true) then
            if now - fsvAskAt > 10 then fsvPending = false end
            return
        end
        fsvPending = false
        local cmd = {}
        for a in s:gmatch("(%x+)%s") do
            local v = fsvMap and fsvMap[a]
            if valid(v) and not name(v):find("Base", 1, true) and try(function() return v.bDisabled end) == true then
                cmd[#cmd + 1] = "lsvon " .. a
                log("fog streaming: " .. fsvWho .. " stands in " .. name(v) .. " (switched off) -> switching it on")
            end
        end
        if #cmd > 0 then
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
            if c then for _, l in ipairs(cmd) do c:write(l .. "\n") end; c:close() end
        end
        return
    end
    if not fsvOn then
        local walls = fsvWalls()
        for _, p in ipairs(players) do
            local wn = fsvNear(walls, p, 12000)
            if wn then
                fsvOn = true
                log("fog streaming: " .. name(p) .. " is near " .. wn .. " -> the volumes under every player stay on, our game streams for all of us")
                break
            end
        end
        if not fsvOn then return end
    end
    fsvTurn = fsvTurn % #players + 1
    local p = players[fsvTurn]
    local loc = valid(p) and try(function() return p:K2_GetActorLocation() end)
    if not loc then return end
    if not fsvMap then
        fsvMap = {}
        for _, v in ipairs(FindAllOf("AppLevelStreamingVolume") or {}) do
            local a = valid(v) and try(function() return v:GetAddress() end)
            if a then fsvMap[string.format("%X", a)] = v end
        end
    end
    os.remove(WIN64 .. "\\plugins\\CoopNative.volsout")
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.vols", "w")
    if not f then return end
    f:write(string.format("%.0f %.0f %.0f\n", loc.X, loc.Y, loc.Z))
    for a, v in pairs(fsvMap) do if valid(v) then f:write(a .. "\n") end end
    f:close()
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write("vols\n"); c:close() end
    fsvPending, fsvAskAt, fsvWho = true, now, name(p)
end
-- guest: what the host's game tells us to load (only near a co-op wall; 300 lines at most)
lsLines = 0
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientUpdateLevelStreamingStatus", function(ctx, pkg, load, vis, block)
        if not lsNear or lsLines >= 300 then return end
        lsLines = lsLines + 1
        local pn = try(function() return pkg:get():ToString() end) or "?"
        log("fog: the host tells us " .. tostring(pn) .. " load " .. tostring(try(function() return load:get() end)) .. " show " .. tostring(try(function() return vis:get() end)))
    end)
end)
lsvAsk, lsvMap, lsvPendingAt, mwUntil, mwLast = false, nil, 0, 0, nil
function lsvPropDump(obj)
    local out = {}
    local cls = valid(obj) and try(function() return obj:GetClass() end)
    local guard = 0
    while valid(cls) and guard < 8 do
        guard = guard + 1
        local cn = name(cls)
        pcall(function()
            cls:ForEachProperty(function(p)
                local pn = try(function() return p:GetFName():ToString() end) or "?"
                local off = try(function() return p:GetOffset_Internal() end)
                local val = try(function() return obj[pn] end)
                if type(val) == "userdata" then val = "obj" end
                out[#out + 1] = string.format("%s.%s@0x%X=%s", cn, pn, off or -1, tostring(val))
            end)
        end)
        if cn == "Volume" or cn == "Actor" then break end
        cls = try(function() return cls:GetSuperStruct() end)
    end
    return out
end
function lsvInfo()
    local ws
    for _, cn in ipairs({ "AppWorldSettings", "WorldSettings" }) do
        local w = FindFirstOf(cn)
        if valid(w) then ws = w; break end
    end
    log("lsvinfo: world settings " .. (valid(ws) and name(ws) or "none") .. ", bUseClientSideLevelStreamingVolumes = " ..
        tostring(valid(ws) and try(function() return ws.bUseClientSideLevelStreamingVolumes end)) .. ", bEnableWorldComposition = " ..
        tostring(valid(ws) and try(function() return ws.bEnableWorldComposition end)))
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) then
            log("lsvinfo: " .. name(c) .. " local " .. tostring(try(function() return c:IsLocalController() end)) .. ", bIsUsingStreamingVolumes = " ..
                tostring(try(function() return c.bIsUsingStreamingVolumes end)))
        end
    end
    local vols = FindAllOf("AppLevelStreamingVolume") or {}
    local v1 = vols[1]
    local okA, all = pcall(function() return v1:IsAllForceDisabled(v1) end)
    local dis, tot = 0, 0
    for _, v in ipairs(vols) do
        if valid(v) then tot = tot + 1; if try(function() return v.bDisabled end) == true then dis = dis + 1 end end
    end
    log("lsvinfo: IsAllForceDisabled = " .. tostring(okA and all) .. (okA and "" or (" (ERROR " .. tostring(all):sub(1, 100) .. ")")) .. "; volumes " .. tot .. ", disabled " .. dis)
    if valid(v1) then
        local props = lsvPropDump(v1)
        for i = 1, #props, 6 do log("lsvinfo: props " .. table.concat(props, " ", i, math.min(#props, i + 5))) end
    end
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local loc = valid(pawn) and try(function() return pawn:K2_GetActorLocation() end)
    if not loc then log("lsvinfo: no character -> no volume check"); return end
    lsvMap = {}
    os.remove(WIN64 .. "\\plugins\\CoopNative.volsout")
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.vols", "w")
    if not f then return end
    f:write(string.format("%.0f %.0f %.0f\n", loc.X, loc.Y, loc.Z))
    for _, v in ipairs(vols) do
        local a = valid(v) and try(function() return v:GetAddress() end)
        if a then lsvMap[string.format("%X", a)] = v; f:write(string.format("%X\n", a)) end
    end
    f:close()
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
    if c then c:write("vols\n"); c:close() end
    lsvAsk, lsvPendingAt = true, os.clock()
end
function lsvTick()
    if lsvAsk then
        local f = io.open(WIN64 .. "\\plugins\\CoopNative.volsout", "r")
        local s = f and (f:read("*a") or "") or ""
        if f then f:close() end
        if s:find("done", 1, true) then
            lsvAsk = false
            local parts = {}
            for a in s:gmatch("(%x+)%s") do
                local v = lsvMap and lsvMap[a]
                if valid(v) then
                    parts[#parts + 1] = name(v) .. " disabled=" .. tostring(try(function() return v.bDisabled end)) .. " wants=" .. tostring(try(function() return v:IsEitherLevelShouldBeLoaded() end))
                end
            end
            log("lsvinfo: volumes around us: " .. (#parts > 0 and table.concat(parts, " | ") or "none"))
        elseif os.clock() - lsvPendingAt > 10 then lsvAsk = false; log("lsvinfo: no answer from CoopNative vols") end
    end
    if os.clock() < mwUntil then
        local pc = localPC()
        local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
        local anim = valid(pawn) and try(function() return pawn.Mesh:GetAnimInstance() end)
        local m = valid(anim) and try(function() return anim:GetCurrentActiveMontage() end)
        local mn = valid(m) and (try(function() return m:GetFullName() end) or name(m)) or "none"
        if mn ~= mwLast then
            mwLast = mn
            log("montagewatch: active montage " .. mn .. (valid(pawn) and (" on " .. name(pawn)) or ""))
        end
    end
end
TP_MONTAGE = {
    start = "/Game/Characters/AnimationSets/TStdUnisex/Montages/AM_TStdUnisex_TCmn_TriggerAc_Checkpoint_Start.AM_TStdUnisex_TCmn_TriggerAc_Checkpoint_Start",
    finish = "/Game/Characters/AnimationSets/TStdUnisex/Montages/AM_TStdUnisex_TCmn_TriggerAc_Checkpoint_End.AM_TStdUnisex_TCmn_TriggerAc_Checkpoint_End",
}
tpaWatch = nil   -- host: {at, old = {pawn addresses}, due = {addr = time}}
function tpMontage(pawn, which, why)
    if not iniHas("tp_anim=1") or not valid(pawn) then return end
    local path = TP_MONTAGE[which]
    local m = StaticFindObject(path)
    if not valid(m) and LoadAsset then pcall(function() m = LoadAsset(path) end) end
    if not valid(m) then log("teleport animation: " .. which .. " is not loaded, skipped"); return end
    local ok, r = pcall(function() return pawn:PlayAnimMontage(m, 1.0, FName("None")) end)
    log(string.format("teleport animation: %s on %s (%s) -> %s %s", which, name(pawn), why, tostring(ok), tostring(r)))
end
function tpaHostTick()
    if not tpaWatch then return end
    local now = os.clock()
    if now - tpaWatch.at > 30 then tpaWatch = nil; return end
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            local g = try(function() return c.Pawn end)
            local a = valid(g) and name(g):find("BP_Player", 1, true) and try(function() return g:GetAddress() end)
            if a and not tpaWatch.old[a] then
                tpaWatch.due[a] = tpaWatch.due[a] or (now + 1.5)
                if tpaWatch.due[a] ~= true and now >= tpaWatch.due[a] then
                    tpaWatch.due[a] = true
                    tpMontage(g, "finish", "the guest arrived next to us")
                end
            end
        end
    end
end
-- Environment watch (11-10, walls_survey=1, read-only; research for the hot spring, the appearance editor and the portals, run alone): one line whenever any of this changes:
-- pawn, view target, field flags (hideout / hot spring), the character's Home Base info (FieldType, CameraType, ClothType, ...), anim flags (spa / editor), movement mode,
-- input ignore flags, the editor's character and UI state, whether a small poly scene plays.
ewLast, ewAt, ewLines = "", 0, 0
function envWatchTick()
    local now = os.clock()
    if now - ewAt < 1.5 then return end
    ewAt = now
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local p = {}
    p[#p + 1] = "pawn " .. (valid(pawn) and name(pawn) or "none")
    local cmr = valid(pc) and try(function() return pc.PlayerCameraManager end) or nil
    local vt = valid(cmr) and (try(function() return cmr.ViewTarget.Target end) or try(function() return cmr:GetViewTarget() end)) or nil
    p[#p + 1] = "view " .. (valid(vt) and name(vt) or "?")
    local fm = FindFirstOf("AppFieldManager")
    if valid(fm) then
        p[#p + 1] = string.format("hideout %s spa %s", tostring(try(function() return fm:IsInHideout(fm) end)), tostring(try(function() return fm:IsInHotSpring(fm) end)))
        local cf = try(function() return fm:GetCurrentField(fm) end)
        if cf ~= nil then
            local s = try(function() return cf:ToString() end) or tostring(cf)
            p[#p + 1] = "field " .. tostring(s):sub(1, 40)
        end
    end
    if valid(pawn) then
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local bi = nil
        if valid(helper) then
            -- the getter's struct comes back as a return value or through an out parameter: try both
            bi = try(function() return helper:GetRestrictedActionInBaseInfo(pawn) end)
            if bi == nil or try(function() return bi.FieldType end) == nil then
                local out = {}
                local okg = pcall(function() helper:GetRestrictedActionInBaseInfo(pawn, out) end)
                if okg and (out.FieldType ~= nil or (out.ReturnValue and out.ReturnValue.FieldType ~= nil)) then bi = out.ReturnValue or out else bi = nil end
            end
        end
        if bi ~= nil then
            local function g(k) return tostring(try(function() return bi[k] end)) end
            p[#p + 1] = string.format("base[field %s cam %s cloth %s move %s dash %s atk %s step %s weapon %s menu %s hud %s mask %s/%s avatar %s special %s]", g("FieldType"), g("CameraType"), g("ClothType"),
                g("LimitMoveType"), g("bCanDash"), g("bCanAttack"), g("bCanStep"), g("bWeaponVisibility"), g("bCanFieldMenu"), g("HeadUpDisplayType"), g("bToxicGuardMaskInnerVisibility"),
                g("bToxicGuardMaskOuterVisibility"), g("bNowAvatarCustomizing"), g("bSpecialGimmickActive"))
        else
            p[#p + 1] = "base ?"
        end
        local anim = try(function() return pawn.Mesh:GetAnimInstance() end)
        if valid(anim) then
            p[#p + 1] = string.format("anim %s spa %s editing %s", name(anim), tostring(try(function() return anim:IsSpaMode() end)), tostring(try(function() return anim:IsAvatarCustomizing() end)))
        end
        local cm = try(function() return pawn.CharacterMovement end)
        p[#p + 1] = "mode " .. tostring(valid(cm) and try(function() return cm.MovementMode end))
        local l = try(function() return pawn:K2_GetActorLocation() end)
        if l then p[#p + 1] = string.format("at %.0f,%.0f,%.0f", l.X, l.Y, l.Z) end
    end
    if valid(pc) then
        p[#p + 1] = string.format("ignore move %s look %s", tostring(try(function() return pc:IsMoveInputIgnored() end)), tostring(try(function() return pc:IsLookInputIgnored() end)))
    end
    local ac = FindFirstOf("BP_AvatarCustomizeCharacter_C")
    local au = FindFirstOf("BP_AvatarCustomizeUIComponent_C")
    p[#p + 1] = string.format("editor[char %s ui %s appearing %s finish %s]", valid(ac) and name(ac) or "-", valid(au) and "yes" or "-",
        tostring(valid(au) and try(function() return au.bAvatarAppearing end)), tostring(valid(au) and try(function() return au.bReserveFinish end)))
    local sm = StaticFindObject("/Script/Extensions.Default__ScenarioManager")
    p[#p + 1] = "smallpoly " .. tostring(valid(sm) and try(function() return sm:IsSmallPolyPlaying() end))
    -- the position changes all the time: compare without it
    local sig = table.concat(p, " | "):gsub("at %-?%d+,%-?%d+,%-?%d+", "")
    if sig ~= ewLast then
        ewLast = sig
        ewLines = ewLines + 1
        if ewLines <= 400 then log("env: " .. table.concat(p, " | ")) end
    end
end
-- Wall survey (11-09, walls_survey=1, read-only, both PCs). The co-op end-of-area fog: BP_BarrierWall (ForMultiplay, IsEnabled, InvisibleWall collision, MistWall = the fog,
-- LevelStreaming) next to BP_MistWall_*_Multi. FieldMeta_Full: every co-op field has MultiplayFlagName Reached_<St> and ProhibitHostingFlagName Boss_<St>. What we need to see:
-- which barrier walls exist in the loaded levels, which are on for the host and for the guest, where they are, and what changes when the players walk up to them.
-- Every 5 s (game thread, in the world only), logs on change; "walls" in CoopProbe.cmd lists everything again. 500 lines at most.
WSV = iniHas("walls_survey=1")
wsLast, wsAt, wsLines, wsForce, wsKnown = {}, -1000, 0, false, -1
local function wsLog(s)
    wsLines = wsLines + 1
    if wsLines <= 500 then log("walls: " .. s) end
end
function wallSurveyTick()
    if not WSV then return end
    local now = os.clock()
    if now < hbUntil + 10 then return end
    if not wsForce and now - wsAt < 5 then return end
    wsAt = now
    local force = wsForce
    wsForce = false
    local pc = localPC()
    local pawn = valid(pc) and try(function() return pc.Pawn end) or nil
    local pl = valid(pawn) and try(function() return pawn:K2_GetActorLocation() end) or nil
    local function dist(l)
        if not (pl and l) then return -1 end
        return math.floor(math.sqrt((l.X - pl.X) ^ 2 + (l.Y - pl.Y) ^ 2 + (l.Z - pl.Z) ^ 2) / 100 + 0.5)
    end
    local function at(a)
        local l = valid(a) and try(function() return a:K2_GetActorLocation() end) or nil
        return l and string.format("%.0f,%.0f,%.0f", l.X, l.Y, l.Z) or "?", l
    end
    local bws = FindAllOf("BP_BarrierWall_C") or {}
    local mws = FindAllOf("BP_MistWall_C") or {}
    local count = #bws * 1000 + #mws
    if count ~= wsKnown then
        wsKnown, force = count, true
        wsLog(string.format("%.0f barrier walls, %.0f mist walls in the loaded levels; we are at %s", #bws, #mws, pl and string.format("%.0f,%.0f,%.0f", pl.X, pl.Y, pl.Z) or "?"))
    end
    local seenMist = {}
    for _, w in ipairs(bws) do
        if valid(w) then
            local n = name(w)
            local mist = try(function() return w.MistWall end)
            local iw = try(function() return w.InvisibleWall end)
            local mn = valid(mist) and name(mist) or "-"
            if valid(mist) then seenMist[mn] = true end
            local col = valid(iw) and (try(function() return iw:GetCollisionEnabled() end) or try(function() return iw:GetActorEnableCollision() end)) or nil
            local lvls = try(function() return w.LevelStreaming:GetArrayNum() end)
            local sig = table.concat({ tostring(try(function() return w.IsEnabled end)), tostring(valid(mist) and try(function() return mist.bProcessEnable end)),
                tostring(col), tostring(valid(mist) and try(function() return mist.bHidden end)) }, "/")
            if force or wsLast[n] ~= sig then
                local first = wsLast[n] == nil
                wsLast[n] = sig
                local pos, l = at(w)
                wsLog(string.format("barrier %s%s: multi=%s enabled=%s dynamic=%s | mist %s on=%s hidden=%s | blocking collision=%s | %s level volume(s) | at %s (%.0fm)%s", n, first and " (new)" or "",
                    tostring(try(function() return w.ForMultiplay end)), tostring(try(function() return w.IsEnabled end)), tostring(try(function() return w.IsDynamic end)),
                    mn, tostring(valid(mist) and try(function() return mist.bProcessEnable end)), tostring(valid(mist) and try(function() return mist.bHidden end)),
                    tostring(col), tostring(lvls), pos, dist(l), first and "" or "  *** CHANGED ***"))
            end
        end
    end
    for _, m in ipairs(mws) do
        if valid(m) then
            local n = name(m)
            if not seenMist[n] then
                local on = try(function() return m.bProcessEnable end)
                local sig = tostring(on) .. "/" .. tostring(try(function() return m.bHidden end))
                if wsLast[n] ~= sig and (force or wsLast[n] ~= nil or on == true or n:find("Multi", 1, true)) then
                    local first = wsLast[n] == nil
                    wsLast[n] = sig
                    local pos, l = at(m)
                    wsLog(string.format("mist %s%s: on=%s hidden=%s initial=%s at %s (%.0fm)%s", n, first and " (new)" or "", tostring(on), tostring(try(function() return m.bHidden end)),
                        tostring(try(function() return m.bInitialEnable end)), pos, dist(l), first and "" or "  *** CHANGED ***"))
                elseif wsLast[n] == nil then
                    wsLast[n] = sig
                end
            end
        end
    end
    -- the warp portals (native WarpPortalBase, in the stages) and the portal points (DLC, FieldTriggers with a dialog, e.g. next to the Home Base Mistle)
    for _, cls in ipairs({ "WarpPortalBase", "BP_WarpPortalPointBase_C" }) do
        for _, w in ipairs(FindAllOf(cls) or {}) do
            if valid(w) then
                local n = name(w)
                local st = tostring(try(function() return w.WarpPortalState end))
                local fs = tostring(try(function() return w.State end))
                local hid = tostring(try(function() return w.bHidden end))
                local dest = try(function() return w.Destination:ToString() end)
                local hold = try(function() return w.HoldStateFlagName:ToString() end) or try(function() return w.VisibleFormula end)
                local sig = st .. "/" .. fs .. "/" .. hid
                if force or wsLast[n] ~= sig then
                    local first = wsLast[n] == nil
                    wsLast[n] = sig
                    local pos, l = at(w)
                    wsLog(string.format("portal %s%s (%s): warp state %s, trigger state %s, hidden %s, destination %s, flag %s | at %s (%.0fm)%s", n, first and " (new)" or "", name(w:GetClass()), st, fs, hid,
                        tostring(dest), tostring(hold), pos, dist(l), first and "" or "  *** CHANGED ***"))
                end
            end
        end
    end
end
local function inWorldNow()
    local pc = localPC()
    local p = valid(pc) and try(function() return pc.Pawn end) or nil
    return valid(p) and name(p):find("BP_Player_C", 1, true) ~= nil
end
-- 11-07: the controller holds the seat's camera while we sit, so "in the world" was false and the seat sync stopped a second after sitting down: the head stopped, the getting-up
-- signal never went out, in every round so far.
local function inSeatNow()
    local pc = localPC()
    local p = valid(pc) and try(function() return pc.Pawn end) or nil
    return valid(p) and name(p):find("BP_Sitting", 1, true) ~= nil
end
local function probeCommands()
    local world = inWorldNow()
    if lsvAsk or os.clock() < mwUntil then pcall(lsvTick) end
    if loadTest and os.clock() - loadTest.at > 6 then
        local fl = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
        if fl then fl:write(string.format("tpfade %X 0\n", loadTest.a)); fl:close() end
        log("loadtest: lift asked for")
        loadTest = nil
    end
    if WSV and not ewErr and iniHas("env_watch=1") then
        local oke, ee = pcall(envWatchTick)
        if not oke then ewErr = true; log("env watch ERROR " .. tostring(ee):sub(1, 160)) end
    end
    pcall(guestOutro)
    pcall(writeMyPawn)
    if world then pcall(guestMemorySpectate) end
    if world then pcall(npcCensusTick) end
    if world then pcall(visMirrorHost) end
    if world then pcall(visMirrorGuest) end
    if world then pcall(hbRescueTick) end
    if world or inSeatNow() then
        local okf, ef = pcall(flavorSyncTick)
        if not okf and not fsErr then fsErr = true; log("flavor sync ERROR " .. tostring(ef):sub(1, 160)) end
        if iniHas("level_watch=1") and not lvlErr then
            local okl, el = pcall(lvlWatchTick)
            if not okl then lvlErr = true; log("level watch ERROR " .. tostring(el):sub(1, 160)) end
        end
        if iniHas("fog_open=1") and not fogErr then
            local okg, eg = pcall(fogOpenTick)
            if not okg then fogErr = true; log("fog open ERROR " .. tostring(eg):sub(1, 160)) end
        end
        if iniHas("fog_stream=1") and not fsvErr then
            local oks, es = pcall(fogStreamTick)
            if not oks then fsvErr = true; log("fog streaming ERROR " .. tostring(es):sub(1, 160)) end
        end
        if WSV and not wsErr then
            local okw, ew = pcall(wallSurveyTick)
            if not okw then wsErrN = (wsErrN or 0) + 1; log("wall survey ERROR " .. tostring(ew):sub(1, 160)); if wsErrN >= 5 then wsErr = true end end
        end
        if pnRecOn then
            local okp, ep = pcall(pnSendNew)
            if not okp and not pnErr then pnErr = true; log("piano send ERROR " .. tostring(ep):sub(1, 160)) end
        end
    end
    if world then
        local okr, er = pcall(recTick)
        if not okr and not recErr then recErr = true; log("rec ERROR " .. tostring(er):sub(1, 160)) end
    end
    if world then pcall(bossWallsOff) end
    pcall(autoTeleportToMark)
    if not world then pcall(titleVersion) else titleDone = false end
    if world then pcall(bloodCodeSyncHost) end
    if world then pcall(bloodCodeSyncGuest) end
    if world then pcall(chestSyncHost) end
    pcall(bossKillRevive)   -- not "world": a dead host may have no character
    pcall(bossForceTick)
    pcall(hbWatch)
    pcall(talkFnSend)
    pcall(bossDeadMark)
    if world then pcall(chestSyncGuest) end
    if world then pcall(sceneMgrSend) end
    pcall(guestMemoryControl)
    pcall(guestTeleportFade)
    if world then pcall(memoryFollow) end
    if world then pcall(memoryBaseLog) end
    if world then pcall(veilWatch) end
    local okr, er = pcall(sceneRelay)
    if not okr and not relayErr then relayErr = true; log("scene relay ERROR " .. tostring(er):sub(1, 160)) end
    guestLevelWatch()
    guestRestRequest()
    resyncAfterMenu()
    guestLevelUpRelay()
    if os.clock() <= disableUntil then disableGuestMenuEntries() elseif not disabledLogged and disableUntil > 0 then disabledLogged = true end
    guestRestHealCheck()
    local f = io.open(PROBE_CMD, "r"); if not f then return end
    local c = (f:read("*a") or ""):gsub("%s+", ""); f:close(); os.remove(PROBE_CMD)
    if c == "openmenu" then openCheckpointMenu(1)
    elseif c == "openmenu2" then openCheckpointMenu(2)
    elseif c == "closemenu" then
        local cp = FindFirstOf("BP_CheckpointUIComponent_C")
        local ok, r = pcall(function() return cp:Close(false, true) end)
        log("menu: Close -> " .. (ok and tostring(r) or ("ERROR " .. tostring(r):sub(1, 140))))
    elseif c == "levelme" then
        -- solo test of the level-up call path: the host levels itself up by one through CoopNative, without the menu
        local cp = FindFirstOf("BP_CheckpointUIComponent_C")
        local a = valid(cp) and try(function() return cp:GetAddress() end)
        local f = a and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
        if f then f:write(string.format("levelup %X 1 0\n", a)); f:close() end
        log("levelme: " .. (f and "sent" or "no checkpoint component"))
    elseif c == "memrespawn" or c == "memrespawn2" then
        -- Memory with a guest (session 10): the museum spawns the host's memory character but never starts it (its tick is not
        -- registered, no BeginPlay), so its appear never ends and the memory's loading fade stays. Give the host a fresh character
        -- at the same spot with RequestPlayerSpawn (the path the group respawn uses; its characters tick and appear normally).
        local gs = FindFirstOf("BP_AppGameState_C")
        if not valid(gs) or try(function() return gs.Role end) ~= 3 then log("memrespawn: host only"); return end
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local pc = localPC()
        local old = valid(pc) and try(function() return pc.Pawn end) or nil
        if not valid(old) then log("memrespawn: no pawn on the host controller"); return end
        local loc = try(function() return old:K2_GetActorLocation() end)
        local rot = try(function() return old:K2_GetActorRotation() end)
        if not loc or not rot then log("memrespawn: no location"); return end
        local at = { X = loc.X, Y = loc.Y, Z = loc.Z + 20 }
        local r = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 }
        -- memrespawn2: SkipAppear = true (no PlayerSpawner; the group respawn spawns the guest this way and those characters start)
        local skip = c == "memrespawn2"
        local ok, e = pcall(function() helper:RequestPlayerSpawn(old, pc, at, r, r, true, skip) end)
        log(c .. ": RequestPlayerSpawn(host controller, skipAppear " .. tostring(skip) .. ") at " .. string.format("%.0f %.0f %.0f", at.X, at.Y, at.Z) .. " -> " ..
            (ok and "called" or ("ERROR " .. tostring(e):sub(1, 140))) .. "; old pawn " .. name(old))
    elseif c:find("^fname") then
        -- resolve FName indexes for the native CGP trace: "fname 123 456 ..."
        local out = {}
        for n in c:gmatch("(%d+)") do out[#out + 1] = n .. "=" .. tostring(try(function() return FName(tonumber(n)):ToString() end)) end
        log("fname: " .. table.concat(out, " "))
    elseif c == "rec" then
        recEvent("mark")
    elseif c == "recforcehost" then
        -- solo: the game's own "force this layout" slot on the host, to the other layout of the same group
        for _, l in ipairs(FindAllOf("ScenarioProgressLoader") or {}) do
            if valid(l) and name(l):find("Base0", 1, true) then
                local cur = try(function() return l.ProgressName:ToString() end) or ""
                if cur:find("ScenarioLayout", 1, true) then
                    local nm = cur:sub(1, -2) .. (cur:sub(-1) == "2" and "1" or "2")
                    local okS, eS = pcall(function() l.ForcedProgressName = FName(nm) end)
                    local got = try(function() return l.ForcedProgressName:ToString() end)
                    local okR, eR = pcall(function() l:ReloadProgress() end)
                    log("rec force: " .. name(l) .. " was " .. cur .. ", forced " .. tostring(got) .. " set " .. (okS and "ok" or tostring(eS):sub(1, 100)) .. ", reload " .. (okR and "ok" or tostring(eR):sub(1, 100)))
                end
            end
        end
        recEvent("force")
    elseif c == "recforce" then
        local nm
        for _, l in ipairs(FindAllOf("ScenarioProgressLoader") or {}) do
            local pn = valid(l) and try(function() return l.ProgressName:ToString() end)
            if type(pn) == "string" and pn:find("Base0", 1, true) then nm = pn end
        end
        log("rec force: host layout " .. tostring(nm))
        if nm then
            for _, g in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(g) and not try(function() return g:IsLocalController() end) then pcall(function() g:ClientMessage("CoopRecForce:" .. nm, FName("None"), 0) end) end
            end
            recEvent("force")
        end
    elseif c == "tp" then
        -- 2026-11-03 (owner): the test start position near the boss, test_mark=X,Y,Z in CoopNative.ini (host test copy)
        local okt, et = pcall(teleportToMark, "command")
        if not okt then log("tp ERROR " .. tostring(et):sub(1, 160)) end
    elseif c == "walls" then
        wsForce = true
        log("walls: full list asked for")
    elseif c == "lsvinfo" then
        local ok, e = pcall(lsvInfo)
        if not ok then log("lsvinfo ERROR " .. tostring(e):sub(1, 160)) end
    elseif c == "montagewatch" then
        mwUntil, mwLast = os.clock() + 120, nil
        log("montagewatch: on for 120 s")
    elseif c == "loadtest" then
        -- 11-11: the join loading screen (usage 64) on our own screen for 6 s, then lifted: checks the lift before the guest gets it
        local pcl = localPC()
        local pl = valid(pcl) and try(function() return pcl.Pawn end) or nil
        local al = valid(pl) and try(function() return pl:GetAddress() end)
        local fl = al and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
        if fl then fl:write(string.format("tpfade %X 1 64\n", al)); fl:close(); loadTest = { a = al, at = os.clock() } end
        log("loadtest: loading screen " .. (fl and "asked for, lifted in 6 s" or "FAILED (no character)"))
    elseif c == "bosshp1" then
        local gs = FindFirstOf("BP_AppGameState_C")
        if not valid(gs) or try(function() return gs.Role end) ~= 3 then log("bosshp1: host only"); return end
        local list, helper = bossesInFight()
        if #list == 0 then log("bosshp1: no boss fight running") end
        for _, x in ipairs(list) do
            local ok, e = pcall(function() helper:SetHealth(x, 1) end)
            log("bosshp1: " .. name(x) .. " -> 1 health " .. (ok and "ok" or ("ERROR " .. tostring(e):sub(1, 120))))
        end
    elseif c == "chests" or c == "chestgive" or c == "chestgivew" then
        -- R8 (2026-11-04): what chests really hold, and does UItemComponent:RPCClient_GainItem take it. chests = log only;
        -- chestgive / chestgivew = give up to 3 item / non-item articles to our own character (test save only).
        local mine = try(function() return localPC().Pawn end)
        local comp = valid(mine) and try(function() return mine.Item end) or nil
        local n, items, others = 0, {}, {}
        for _, ch in ipairs(FindAllOf("BP_ItemBox_C") or {}) do
            if valid(ch) then
                n = n + 1
                local parts = {}
                local ok, e = pcall(function()
                    ch.SpawnItemInfos:ForEach(function(_, x)
                        local r = x:get()
                        local art = try(function() return r.ItemArticle end)
                        local cls = valid(art) and try(function() return name(art:GetClass()) end) or "?"
                        local cnt = try(function() return r.ItemCount end) or 1
                        parts[#parts + 1] = string.format("%s[%s] x%s drop=%s weight=%s grind=%s sym=%s", valid(art) and name(art) or "?", tostring(cls), tostring(cnt),
                            tostring(try(function() return r.DropType end)), tostring(try(function() return r.Weight end)), tostring(try(function() return r.Grind end)),
                            tostring(try(function() return r.DropProgressSymbol:ToString() end)))
                        if valid(art) then
                            local list = tostring(cls):find("Item", 1, true) and items or others
                            list[#list + 1] = {art, cnt > 0 and cnt or 1, try(function() return r.DegenerationType end), try(function() return r.Grind end)}
                        end
                    end)
                end)
                log("chests: " .. name(ch) .. " state=" .. tostring(try(function() return ch.ChestState end)) .. " flag=" ..
                    tostring(try(function() return ch.HoldStateFlagName:ToString() end)) .. " | " .. (ok and table.concat(parts, " ; ") or ("unreadable " .. tostring(e):sub(1, 100))))
            end
        end
        log("chests: " .. n .. " chest(s), " .. #items .. " item article(s), " .. #others .. " other article(s), item component " .. tostring(valid(comp)))
        if c ~= "chests" and valid(comp) then
            local list = c == "chestgive" and items or others
            for i = 1, math.min(3, #list) do
                -- RPCClient_GainItem takes item articles only: a weapon article crashed the game (2026-11-04, 0x146302C4E)
                local art, cnt = list[i][1], list[i][2]
                local cls = tostring(try(function() return name(art:GetClass()) end))
                local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
                local ok, e = pcall(function()
                    if cls:find("Weapon", 1, true) then helper:UpdateWeaponInventoryInfo(mine, art, cnt, list[i][3] or 0, list[i][4] or 0, false)
                    elseif cls:find("Jinkaku", 1, true) then helper:UpdateJinkakuInventoryInfo(mine, art, cnt, list[i][3] or 0, list[i][4] or 0, false)
                    else comp:RPCClient_GainItem(art, cnt) end
                end)
                log("chests: give " .. name(list[i][1]) .. " x" .. tostring(list[i][2]) .. " -> " .. (ok and "called" or ("ERROR " .. tostring(e):sub(1, 120))))
            end
        end
    elseif c == "deathvt" then
        -- fall presentation: the address of our DeathComponent, to read its vtable (Multicast_MigrationToDeath_Implementation = slot +0x430)
        local p = try(function() return localPC().Pawn end)
        local d = valid(p) and try(function() return p.Death end) or nil
        log(string.format("deathvt: pawn %X death %X", valid(p) and p:GetAddress() or 0, valid(d) and d:GetAddress() or 0))
    elseif c == "baseinfo" then
        -- Home Base mode research (item 1): the game's "restricted action in base" info (weapon visibility, attack, dash, menu, ...)
        -- per player, plus the field manager's IsInHideout and each player's anim instance bIsBaseMode
        local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
        local fields = {"FieldType", "HeadUpDisplayType", "LimitMoveType", "bCanDash", "bCanAttack", "bWeaponVisibility", "bCanStep",
            "UseItemType", "bCanFieldMenu", "CameraType", "ClothType", "bToxicGuardMaskInnerVisibility", "bToxicGuardMaskOuterVisibility",
            "bJinkakuVisibility", "CameraLightIntensity", "bNowAvatarCustomizing", "bSpecialGimmickActive"}
        for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
            if valid(p) then
                local out = {}
                local ok, e = pcall(function() helper:GetRestrictedActionInBaseInfo(p, out) end)
                local info = out.OutInfo or out
                local parts = {}
                for _, k in ipairs(fields) do
                    local v = try(function() return info[k] end)
                    if v ~= nil then parts[#parts + 1] = k .. "=" .. tostring(v) end
                end
                local anim = try(function() return p.Mesh:GetAnimInstance() end)
                local bm = valid(anim) and try(function() return anim.bIsBaseMode end)
                log("baseinfo: " .. name(p) .. (ok and "" or (" ERROR " .. tostring(e):sub(1, 100))) .. " bIsBaseMode=" .. tostring(bm)
                    .. " " .. table.concat(parts, " "))
            end
        end
        local fm = FindFirstOf("AppFieldManager")
        if valid(fm) then
            local out = {}
            local ok, r = pcall(function() return fm:IsInHideout(fm) end)
            log("baseinfo: IsInHideout -> " .. tostring(ok) .. " " .. tostring(r) .. " " .. tostring(out.ReturnValue))
        end
    elseif c == "lvlinfo" then
        -- level-up check values of every player's HumanContextComponent (CoopNative logs level, max, cost, haze)
        local addrs = {}
        for _, comp in ipairs(FindAllOf("HumanContextComponent") or {}) do
            local o = valid(comp) and try(function() return comp:GetOwner() end)
            if valid(o) and name(o):find("BP_Player_C", 1, true) then
                local a = try(function() return comp:GetAddress() end)
                if a then addrs[#addrs + 1] = string.format("%X", a); log("lvlinfo: " .. name(o) .. " component 0x" .. addrs[#addrs]) end
            end
        end
        local f = #addrs > 0 and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a")
        if f then f:write("lvlinfo " .. table.concat(addrs, " ") .. "\n"); f:close() end
    elseif c == "guesthaze" then
        -- haze test (session 8): give the guest's character copy in our world 100000 haze, to see whether the host-side level-up
        -- for him was refused for lack of haze (his haze is spent only on his PC)
        local pc = localPC()
        local mine = valid(pc) and try(function() return pc.Pawn end) or nil
        local n = 0
        for _, comp in ipairs(FindAllOf("HumanContextComponent") or {}) do
            local o = valid(comp) and try(function() return comp:GetOwner() end)
            if valid(o) and name(o) ~= name(mine) and name(o):find("BP_Player_C", 1, true) then
                if pcall(function() comp:Server_AddExp(100000) end) then n = n + 1 end
            end
        end
        log("guesthaze: +100000 haze on " .. n .. " guest character(s)")
    elseif c == "pieces" then
        -- list the widgets inside the open Mistle menu (to find the partner-switch entry)
        local n = 0
        for _, w in ipairs(FindAllOf("UserWidget") or {}) do
            local full = valid(w) and try(function() return w:GetFullName() end) or ""
            if full:find("WDT_CheckpointMenu_C", 1, true) and not full:find("^WidgetBlueprintGeneratedClass") then
                n = n + 1
                log("menu piece: " .. full:sub(1, 200) .. " enabled=" .. tostring(try(function() return w:GetIsEnabled() end)) ..
                    " vis=" .. tostring(try(function() return w:GetVisibility() end)))
            end
        end
        log("menu pieces listed: " .. n)
    elseif c ~= "" then log("probe command unknown: " .. c) end
end

local last = ""
-- World-change guard (2026-10-30, item 5): polling session functions while a map travel tears the old world down crashed the game
-- (18:55, the owner joining the brother's world: null read inside IsSendRescueSignal from a Lua poll). Session polls pause from a
-- ClientTravel until the new world's game state has existed for 5 s (or 30 s at most), and for 5 s after any game state change.
local wgTravelAt, wgGs, wgGsAt = -1000, nil, -1000
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientTravelInternal", function() wgTravelAt = os.clock() end)
end)
local function worldSettled()
    local gs = FindFirstOf("BP_AppGameState_C")
    local ok, a = pcall(function() return gs:IsValid() and gs:GetAddress() end)
    a = ok and a or nil
    if a ~= wgGs then
        wgGs, wgGsAt = a, os.clock()
        if wgTravelAt > 0 and os.clock() - wgTravelAt < 30 then wgTravelAt = -1000 end
    end
    if not a then return false end
    if os.clock() - wgTravelAt < 30 then return false end
    return os.clock() - wgGsAt > 5
end

-- 2026-11-04: with these mods polling during the load the first engine tick came after 80 s, without them after 22 s. Nothing here
-- is needed before the first tick, so the loops wait for CoopNative's signal (or 120 s, should CoopNative be missing).
local coopReadyFile = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]ue4ss[/\\]Mods[/\\]") or ".") .. "\\plugins\\CoopNative.ticked"
local coopReadyStart, coopReady = os.time(), false
local function coopEngineReady()
    if coopReady then return true end
    local f = io.open(coopReadyFile, "r")
    if f then f:close(); coopReady = true elseif os.time() - coopReadyStart > 120 then coopReady = true end
    return coopReady
end
LoopAsync(200, function()
    if not coopEngineReady() then return false end
    ExecuteInGameThread(function()
        local line = worldSettled() and (try(stateLine) or "state error") or last
        if line ~= last then log("STATE " .. line); last = line end
        local w = try(spectateWindow) or false
        writeWindow(w)
        pcall(spectateCam, w)
        pcall(unlockInput)
        local rested = try(restEdge) or false
        local ok, e = pcall(groupRest, rested)
        if not ok and not groupRestErr then groupRestErr = true; log("group rest ERROR " .. tostring(e):sub(1, 160)) end
        local okc, ec = pcall(combatProbe)
        if not okc and not combatErr then combatErr = true; log("combat probe ERROR " .. tostring(ec):sub(1, 160)) end
        pcall(sendMenuClass)
        pcall(sendRestoreClass)
        local okc2, ec2 = pcall(probeCommands)
        if not okc2 then log("probe command ERROR " .. tostring(ec2):sub(1, 160)) end
        whoTick = whoTick + 1; if whoTick % 50 == 1 then pcall(whoIsWho) end
        local okr, er = pcall(groupRespawn, rested)
        local okk, ek = pcall(keepDying, rested)
        pcall(sendTpInfo)
        local okt, et = pcall(groupTeleport)
        if not okt and not teleportErr then teleportErr = true; log("group teleport ERROR " .. tostring(et):sub(1, 160)) end
        if not okk and not keepErr then keepErr = true; log("keep dying ERROR " .. tostring(ek):sub(1, 160)) end
        if not okr and not respawnErr then respawnErr = true; log("group respawn ERROR " .. tostring(er):sub(1, 160)) end
    end)
    return false
end)

-- key presses at the piano are short: 50 ms, only while sitting there
-- (off by default: the only crash at the piano, UE4SS.dll +0x2AE933 on standing up, 17:38, came with this poll; two stand-ups without it were fine)
if FLAVOR then
    LoopAsync(50, function()
        if not coopEngineReady() then return false end
        if not flavorPianoOn then return false end
        ExecuteInGameThread(function() pcall(flavorPianoPoll) end)
        return false
    end)
end

-- (piano presses go out from probeCommands, on the game thread; a 50 ms LoopAsync for them crashed the guest on 11-07 21:23)

-- engine leave/kick/travel paths (client RPCs run on the guest; game mode calls on the host)
local HOOKS = {
    "/Script/Engine.PlayerController:ClientWasKicked",
    "/Script/Engine.PlayerController:ClientReturnToMainMenu",
    "/Script/Engine.PlayerController:ClientTravel",
    "/Script/Engine.PlayerController:ClientTravelInternal",
    "/Script/Engine.PlayerController:ServerNotifyLoadedWorld",
    "/Script/Engine.GameModeBase:ReturnToMainMenuHost",
    "/Script/Engine.GameModeBase:K2_OnLogout",
}
-- Death trace (trace_death=1, log only, read once at load): the death/fade/respawn natives, to see the order a death goes
-- through on each PC (session 8: the group respawn leaves the guest without input because his own death sequence never ends).
-- Lua hooks on GetRescueSignalState and FieldTriggerBase:IsAuthorization froze the game, and with Controller:Possess/UnPossess and
-- PlayerController:ClientRestart in this list the game crashed at the title screen (2026-10-28 08:32); it still crashed there with
-- BaseInputController:Set/ClearTemporaryInputMask hooked (08:34), and still with the FadeUIComponentIF Request*/FinishCurrentFadeKind
-- statics hooked (08:35; calling RequestUnfade from Lua also crashed the guest): none of them are hooked.
if iniHas("trace_death_lua=1") then   -- crashes at the title screen (see above); the native trace uses trace_death=1
    for _, fn in ipairs({
        "/Script/Extensions.CharacterHelper:TryExecuteDeath",
        "/Script/Extensions.CharacterHelper:RequestTryExecuteDeath",
        "/Script/Extensions.DeathComponent:Multicast_MigrationToDeath",
        "/Script/Extensions.AIDataManager:OnPlayerDeath",
        "/Script/Extensions.UIHelper:RequestDeathFade",
        "/Script/Extensions.CharacterHelper:RequestPlayerRespawn",
        "/Script/Extensions.CharacterHelper:RequestPlayerSpawn",
        "/Script/Extensions.BaseInputController:ServerRequestGuestPlayerSpawn",
        "/Script/Extensions.HumanCommonBase:RPCServer_RequestRespawn",
        "/Script/Extensions.CheckPointUIComponent:RequestPlayerSpawnToLastCheckPoint",
    }) do HOOKS[#HOOKS + 1] = fn end
end
for _, fn in ipairs(HOOKS) do
    local short = fn:match("[^.]+:[^:]+$") or fn
    local ok, err = pcall(function()
        RegisterHook(fn, function(ctx, ...)
            local args = {}
            for _, p in ipairs({...}) do
                local v = try(function() return p:get() end)
                if type(v) == "userdata" then v = try(function() return v:ToString() end) or try(function() return v:GetFName():ToString() end) or "obj" end
                args[#args + 1] = tostring(v)
            end
            log("CALL " .. short .. "(" .. table.concat(args, ", ") .. ") on " .. name(try(function() return ctx:get() end)))
        end)
    end)
    log("hook " .. short .. (ok and " ok" or (" FAILED " .. tostring(err):sub(1, 90))))
end
log("loaded")
