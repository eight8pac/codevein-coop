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
        if dead then
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "a"); if c then c:write("replay\n"); c:close() end
        end
        log("boss rewards: spectate window forced closed" .. (dead and ", own character dead -> replay requested" or ""))
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
    if isHost then return deadOther and aliveMine end            -- a guest died, the host lives
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
    return deadMine and aliveOther
end
postBossUntil = -1000   -- set when the host's memory starts/ends (scene relay); no spectate window until then
local function spectateWindow()
    if os.clock() - rewardsAt < 60 then return false end
    -- 2026-11-02: after the memory his BossAreaState still said "fight running" (his story flags) and leftover memory characters
    -- counted as dead -> the spectate window opened: camera on the host, death filter and crisis music in the final cutscene
    if os.clock() < postBossUntil then return false end
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) then return false end
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    if try(function() return gs.BossAreaState end) ~= 2 then return try(function() return fieldWindow(gs, helper) end) or false end
    local dead, alive = false, false
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) then
            if try(function() return helper:IsDeath(p) end) then dead = true else alive = true end
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
local RESPAWN_DELAY = 4
local downed = {}   -- dead guest pawn name -> {at = os.clock(), mode = "spectate"|"respawn"}
local function respawnGuest(helper, deadPawn, hostPawn, withAppear)
    local pc
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then pc = c end
    end
    if not valid(pc) then log("group respawn: no remote PlayerController"); return false end
    local loc = hostPawn:K2_GetActorLocation()
    local rot = hostPawn:K2_GetActorRotation()
    local right = hostPawn:GetActorRightVector()
    local at = { X = loc.X + right.X * 150, Y = loc.Y + right.Y * 150, Z = loc.Z + 50 }
    local r = { Pitch = 0, Yaw = rot.Yaw, Roll = 0 }
    -- InIsSkipAppear = true: without it the guest's controller first got a PlayerSpawner (appear sequence) and he could not move
    local ok, e = pcall(function() helper:RequestPlayerSpawn(hostPawn, pc, at, r, r, true, not withAppear) end)
    log("group respawn: RequestPlayerSpawn(" .. name(pc) .. ") next to the host" .. (withAppear and " with the appear effect" or "") ..
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
    if not valid(hostPawn) or try(function() return helper:IsDeath(hostPawn) end) then downed = {}; return end
    local seen = {}
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if valid(p) and name(p) ~= name(hostPawn) and try(function() return helper:IsDeath(p) end) then
            local n = name(p); seen[n] = true
            local d = downed[n]
            if not d then
                d = { at = os.clock(), mode = "spectate" }   -- owner, session 8: always back on the host's next rest
                downed[n] = d
                log("group respawn: " .. n .. " died -> spectates until the host rests" .. (lastCombat and " (in combat)" or " (out of combat)"))
            end
            local due = (d.mode == "respawn" and os.clock() - d.at >= RESPAWN_DELAY) or (d.mode == "spectate" and rested)
            if due and not d.done then d.done = true; respawnGuest(helper, p, hostPawn) end   -- one try per death
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
            -- item 8 v2: host -> guest message (PlayerController:ClientMessage is a client RPC): the guest fades now, at the start
            for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
                if valid(c) and not try(function() return c:IsLocalController() end) then
                    local okm = pcall(function() c:ClientMessage("CoopTeleportFade", FName("None"), 0) end)
                    log("group teleport: fade message to " .. name(c) .. " " .. tostring(okm))
                end
            end
        elseif what:find("^arrived") and pendingTp then
            pendingTp.arrivedAt = os.clock()
            log("group teleport: host's characters re-spawned at the target")
        end
    end
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
    if pendingTp.memend then
        -- 2026-11-05: "can move" came 2 s into the final cutscene (it does not block move input): the guest spawned into the host's
        -- cutscene with the join message. The game's own report of the finished scene is the real end.
        if not pendingTp.finishedAt or os.clock() - pendingTp.finishedAt < 2 then return end
        log("group teleport: the final cutscene finished -> bringing the guests")
        memendBring = true
    end
    pendingTp = nil
    -- by remote controller: right after the teleport the host's old pawn still exists and was taken for a guest (spawned twice)
    local n = 0
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        if valid(c) and not try(function() return c:IsLocalController() end) then
            local p = try(function() return c.Pawn end)
            local isPlayer = valid(p) and name(p):find("BP_Player_C", 1, true) ~= nil
            if isPlayer and not try(function() return helper:IsDeath(p) end) then
                if respawnGuest(helper, p, mine, true) then
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
    c:write(string.format("tpfade %X %d\n", ctx, on and 1 or 0)); c:close()
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
        local scene = tpfReady.host and tpfReady.guest
        local done = scene or (tpfMineAt and os.clock() - tpfMineAt > 1.5) or os.clock() - tpfOnAt > 25
        local ctx = valid(mine) and try(function() return mine:GetAddress() end)
        if not ctx and valid(pc) then ctx = try(function() return pc:GetAddress() end) end
        if done and ctx and tpfadeSend(ctx, false) then
            log("teleport fade: lifted (" .. (scene and "both games ready, the scene starts" or (tpfMineAt and "our new character is next to the host" or "timeout")) .. ")")
            tpfOnAt, tpfMineAt = nil, nil
        end
    elseif tpfMessageAt then
        local ctx = valid(mine) and try(function() return mine:GetAddress() end)
        if os.clock() - tpfMessageAt > 5 then tpfMessageAt = nil
        elseif ctx and tpfadeSend(ctx, true) then
            log("teleport fade: host's message -> fade")
            tpfOnAt, tpfMine, tpfMessageAt = os.clock(), mineName, nil
            tpfReady = {}
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
    for _, q in ipairs(FindAllOf("Character") or {}) do
        local n = valid(q) and name(q)
        -- (2026-11-03: Sophie is BP_SubQuestChara_08_002_SumikaDevil: side-quest characters are included too)
        if n and (n:find("ScenarioChara", 1, true) or n:find("SubQuestChara", 1, true)) then out[#out + 1] = {q, "V"} end
    end
    for _, c in ipairs(WALL_CLASSES) do
        for _, q in ipairs(FindAllOf(c) or {}) do if valid(q) then out[#out + 1] = {q, "W"} end end
    end
    return out
end
function visState(q, kind)
    if kind == "W" then return try(function() return q.bProcessEnable end) and "1" or "0" end
    local pv = try(function() return q.bProgressVisibility end)
    local sv = try(function() return q.bShouldBeVisible end)
    local hidden = try(function() return q.bHidden end)
    if pv == nil then return hidden and "0" or "1" end   -- classes without progress visibility
    -- (2026-11-03: Cyllene was off by progress on the guest but could be shown again through bHidden; count both)
    return (pv and sv ~= false and not hidden) and "1" or "0"
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
    local changed = {}
    for _, e in ipairs(visActors()) do
        local q, kind = e[1], e[2]
        local n = name(q)
        local s = kind .. visState(q, kind)
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
                    pcall(function() q.bShouldBeVisible = on end)
                    pcall(function() q:SetActorHiddenInGame(not on) end)
                end
                applied[#applied + 1] = n .. (on and " on" or " off")
            end
        end
    end
    if #applied > 0 then log("visibility mirror: " .. table.concat(applied, ", ")) end
end
function npcCensus(reason)
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
    menuClosedAt = nil
    menuWatch = false
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
    if os.clock() - sceneMgrAt < 5 then return end
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
local function inWorldNow()
    local pc = localPC()
    local p = valid(pc) and try(function() return pc.Pawn end) or nil
    return valid(p) and name(p):find("BP_Player_C", 1, true) ~= nil
end
local function probeCommands()
    local world = inWorldNow()
    pcall(guestOutro)
    pcall(writeMyPawn)
    if world then pcall(guestMemorySpectate) end
    if world then pcall(npcCensusTick) end
    if world then pcall(visMirrorHost) end
    if world then pcall(visMirrorGuest) end
    if world then pcall(bossWallsOff) end
    pcall(autoTeleportToMark)
    if not world then pcall(titleVersion) else titleDone = false end
    if world then pcall(bloodCodeSyncHost) end
    if world then pcall(bloodCodeSyncGuest) end
    if world then pcall(chestSyncHost) end
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
    elseif c == "tp" then
        -- 2026-11-03 (owner): the test start position near the boss, test_mark=X,Y,Z in CoopNative.ini (host test copy)
        local okt, et = pcall(teleportToMark, "command")
        if not okt then log("tp ERROR " .. tostring(et):sub(1, 160)) end
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
