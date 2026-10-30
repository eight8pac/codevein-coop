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
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w"); if c then c:write("replay"); c:close() end
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
local function spectateWindow()
    if os.clock() - rewardsAt < 60 then return false end
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
            local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
            if c then c:write(string.format("unfade %X", addr)); c:close(); e = string.format("unfade sent for 0x%X", addr) end
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
    local m = FindFirstOf("WDT_CheckpointMenu_C")
    local cls = valid(m) and try(function() return m:GetClass() end) or nil
    local addr = cls and try(function() return cls:GetAddress() end)
    if not addr then return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
    if c then c:write(string.format("menuclass %X", addr)); c:close(); menuClassSent = true end
    log(string.format("vestige menu: WDT_CheckpointMenu_C class at 0x%X sent to CoopNative", addr))
end

-- Vestige restoration with a session (vestige_keep=1, R4 stage 2): CoopNative answers "no session" to the restoration screen's
-- IsCreateSession / GetOnlineOtherPlayerNum; Lua hands over that screen's class once ("restclass <hex>"), like the menu class.
-- CoopNative.cmd holds one command, so wait while another one is still pending.
local restClassSent = false
local function sendRestoreClass()
    if restClassSent or not iniHas("vestige_keep=1") then return end
    local m = FindFirstOf("BP_BCRestorationUIComponent_C")
    local cls = valid(m) and try(function() return m:GetClass() end) or nil
    local addr = cls and try(function() return cls:GetAddress() end)
    if not addr then return end
    local pending = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "r")
    if pending then pending:close(); return end
    local c = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
    if c then c:write(string.format("restclass %X", addr)); c:close(); restClassSent = true end
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
local function sendTpInfo()
    if os.clock() - tpInfoAt < 2 then return end
    tpInfoAt = os.clock()
    local gs = FindFirstOf("BP_AppGameState_C")
    if not valid(gs) or try(function() return gs.Role end) ~= 3 then return end
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
            pendingTp = { at = os.clock(), oldHost = valid(m0) and try(function() return m0:GetAddress() end) or nil }
            log("group teleport: host teleports, guests follow once the host has arrived")
        elseif what:find("^arrived") and pendingTp then
            pendingTp.arrivedAt = os.clock()
            log("group teleport: host's characters re-spawned at the target")
        end
    end
    if not pendingTp then return end
    if os.clock() - pendingTp.at > 60 then log("group teleport: host did not arrive within 60 s, given up"); pendingTp = nil; return end
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
    pendingTp = nil
    -- by remote controller: right after the teleport the host's old pawn still exists and was taken for a guest (spawned twice)
    local n = 0
    for _, c in ipairs(FindAllOf("ActionPlayerController_C") or {}) do
        local p = valid(c) and not try(function() return c:IsLocalController() end) and try(function() return c.Pawn end) or nil
        if valid(p) and name(p):find("BP_Player_C", 1, true) and not try(function() return helper:IsDeath(p) end) then
            if respawnGuest(helper, p, mine, true) then
                oldPawns[#oldPawns + 1] = { p = p, n = name(p), at = os.clock() }
                n = n + 1
            end
        end
    end
    log("group teleport: " .. n .. " guest(s) brought to the host")
end
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
-- tell CoopNative our own HumanContextComponent (for the direct level-up call), written when the menu opens
local function writeMyComponent()
    local pc = localPC()
    local mine = valid(pc) and try(function() return pc.Pawn end) or nil
    for _, c in ipairs(FindAllOf("HumanContextComponent") or {}) do
        if valid(c) and valid(mine) and name(try(function() return c:GetOwner() end)) == name(mine) then
            local a = try(function() return c:GetAddress() end)
            local f = a and io.open(WIN64 .. "\\plugins\\CoopNative.mycomp", "w")
            if f then f:write(string.format("%X", a)); f:close(); log(string.format("guest rest: own HumanContextComponent 0x%X handed to CoopNative", a)) end
        end
    end
end
local function guestRestRequest()
    local f = io.open(RESTREQ, "r"); if not f then return end
    f:close(); os.remove(RESTREQ)
    pcall(writeMyComponent)
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
    local comp
    for _, c in ipairs(FindAllOf("HumanContextComponent") or {}) do
        if valid(c) and valid(mine) and name(try(function() return c:GetOwner() end)) == name(mine) then comp = c end
    end
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
    local f = addr and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
    if f then f:write(string.format("syncall %X", addr)); f:close() end
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
        for _, c in ipairs(FindAllOf("HumanContextComponent") or {}) do
            if valid(c) and valid(mine) and name(try(function() return c:GetOwner() end)) == name(mine) then
                lvlWatch = { a = try(function() return c:GetAddress() end), at = os.clock(), step = 0 }
            end
        end
    end
    if not lvlWatch or not lvlWatch.a then return end
    local due = LVL_STEPS[lvlWatch.step + 1]
    if not due then lvlWatch = nil; return end
    if os.clock() - lvlWatch.at < due then return end
    lvlWatch.step = lvlWatch.step + 1
    local f = io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
    if f then f:write(string.format("lvlinfo %X", lvlWatch.a)); f:close() end
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
            log("guest outro: " .. name(a) .. ":MulticastExecuteFlowDiagramWithCallback(FinishEvent) -> " .. (ok and "called" or ("ERROR " .. tostring(e):sub(1, 140))))
            return
        end
    end
    log("guest outro: boss area 0x" .. t .. " not found")
end
local function probeCommands()
    pcall(guestOutro)
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
        local f = a and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
        if f then f:write(string.format("levelup %X 1 0", a)); f:close() end
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
    elseif c == "bosshp1" then
        local gs = FindFirstOf("BP_AppGameState_C")
        if not valid(gs) or try(function() return gs.Role end) ~= 3 then log("bosshp1: host only"); return end
        local list, helper = bossesInFight()
        if #list == 0 then log("bosshp1: no boss fight running") end
        for _, x in ipairs(list) do
            local ok, e = pcall(function() helper:SetHealth(x, 1) end)
            log("bosshp1: " .. name(x) .. " -> 1 health " .. (ok and "ok" or ("ERROR " .. tostring(e):sub(1, 120))))
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
        local f = #addrs > 0 and io.open(WIN64 .. "\\plugins\\CoopNative.cmd", "w")
        if f then f:write("lvlinfo " .. table.concat(addrs, " ")); f:close() end
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
LoopAsync(200, function()
    ExecuteInGameThread(function()
        local line = try(stateLine) or "state error"
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
