-- CoopSeamless: automatic "step out and rejoin" for Code Vein co-op. Host and guests run the same mod.
-- Host: once you have hosted in this game run (or host=always), the mod re-sends the distress signal
--   and opens the Field channel whenever the session is gone or closed and the game is calm (no boss
--   fight, no cutscene, no Home Base, no loading). It also lets the menu send a signal in areas whose
--   boss is dead.
-- Guest: once you have joined a host in this game run (or guest=always), the mod searches and joins
--   again after a disconnect (boss kill, death).
-- Cancelling the signal or leaving through the menu turns auto mode off until you host or join again by hand.
-- config.txt in the mod folder (read every second):  enabled=1  host=auto|always|off  guest=auto|always|off
local TAG = "[CoopSeamless] "
local SETTLE_S, HOST_RETRY_S, OPEN_RETRY_S, GUEST_RETRY_S = 8, 30, 10, 25
local FIELD, BOSSAREA, CINEMATICS, ENEMYRESET = 1, 2, 4, 8   -- ESessionOpenness
local ROLE_AUTHORITY = 3

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]main%.lua$") or "."
local function log(s) print(TAG .. os.date("%H:%M:%S ") .. tostring(s) .. "\n") end
local function valid(o) return o ~= nil and o:IsValid() end
local function try(f, ...) local ok, v = pcall(f, ...); if ok then return v end return nil end

local cfg = {enabled = "1", host = "auto", guest = "auto"}
local function readConfig()
    local f = io.open(MOD_DIR .. "\\config.txt", "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*(%w+)%s*=%s*(%w+)")
        if k then cfg[k] = v end
    end
    f:close()
end

-- sticky intent, set by what the player did in this game run
local hostSticky, guestSticky, hostName = false, false, nil
local allowSend = false            -- read by the IsSendRescueSignal override
local publicConnections = 3        -- what the vanilla field menu passes (BP_FieldMenuUIComponent bytecode); likely unused
local calmSince, lastCreate, lastOpen, lastSearch = nil, -1e9, -1e9, -1e9
local lastLine, lastPawnName = "", ""
local wasHosting, wasJoined = false, false   -- previous tick, for start-of-session detection

local function snapshot()
    local sm = FindFirstOf("AppSessionManager")
    local gs = FindFirstOf("BP_AppGameState_C")
    local gi = FindFirstOf("App_GameInstance_C")
    if not (valid(sm) and valid(gs) and valid(gi)) then return nil end
    local s = {sm = sm, gs = gs, gi = gi}
    s.online = try(function() return sm:BPIsOnlineMode(gi) end)
    s.busy = try(function() return sm:IsOnlineSessionBusy() end)
    s.multi = try(function() return sm:IsOnlineMultiplay(gs) end)
    s.created = try(function() return sm:IsCreateSession(gs) end)
    s.public = try(function() return sm:IsPublicSession(gs) end)
    s.prohib = try(function() return sm:IsSessionOperationProhibition(gs) end)
    s.searching = try(function() return sm:IsSearchingSessions(gs) end)
    s.signal = try(function() return sm:GetRescueSignalState(gs) end)
    s.others = try(function() return sm:GetOnlineOtherPlayerNum(gs) end)
    s.boss = try(function() return gs.BossAreaState end)
    s.authority = try(function() return gs.Role end) == ROLE_AUTHORITY
    s.ch = {}
    for _, bit in ipairs({FIELD, BOSSAREA, CINEMATICS, ENEMYRESET}) do
        s.ch[bit] = try(function() return sm:ExpectsBeOpenRaw(bit) end)
    end
    -- on death the old pawn stays valid (IsDeath true) until the respawn spawns a new one
    s.pawn, s.pawnName, s.dead, s.downed = false, "", false, false
    local helper = StaticFindObject("/Script/Extensions.Default__CharacterHelper")
    local function life(p)   -- "dead", "downed" (revivable) or "ok"
        if try(function() return helper:IsDeath(p) end) or try(function() return helper:IsDying(p) end) then return "dead" end
        if try(function() return helper:IsDowned(p) end) then return "downed" end
        return "ok"
    end
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if try(function() return pc:IsLocalPlayerController() end) then
            local p = try(function() return pc.Pawn end)
            if try(function() return valid(p) end) then
                s.pawn = true
                s.pawnName = try(function() return p:GetFName():ToString() end) or ""
                local l = life(p)
                s.dead, s.downed = l == "dead", l == "downed"
            end
        end
    end
    -- every player character this game knows about (own + replicated), for boss-fight death analysis
    local players = {}
    for _, p in ipairs(FindAllOf("BP_Player_C") or {}) do
        if try(function() return valid(p) end) then
            players[#players + 1] = (try(function() return p:GetFName():ToString() end) or "?") .. ":" .. life(p)
        end
    end
    s.players = table.concat(players, ",")
    s.cutscene = false
    for _, p in ipairs(FindAllOf("LevelSequencePlayer") or {}) do
        if try(function() return p:IsPlaying() end) then s.cutscene = true; break end
    end
    return s
end

local function stateLine(s)
    local function b(v) if v == nil then return "?" end return v and "1" or "0" end
    return string.format("auth=%s online=%s busy=%s multi=%s others=%s created=%s signal=%s public=%s prohib=%s searching=%s boss=%s ch[F,B,C,E]=%s%s%s%s pawn=%s dead=%s downed=%s cutscene=%s players=[%s] | host=%s guest=%s",
        b(s.authority), b(s.online), b(s.busy), b(s.multi), tostring(s.others), b(s.created), tostring(s.signal),
        b(s.public), b(s.prohib), b(s.searching), tostring(s.boss), b(s.ch[FIELD]), b(s.ch[BOSSAREA]),
        b(s.ch[CINEMATICS]), b(s.ch[ENEMYRESET]), s.pawn and s.pawnName or "0", b(s.dead), b(s.downed), b(s.cutscene), s.players, b(hostSticky), b(guestSticky))
end

-- calm: nothing the game is doing that a session change could disturb
local function isCalm(s)
    return s.online and not s.busy and s.prohib == false and s.boss == 0 and s.pawn and not s.dead and not s.downed and not s.cutscene
        and s.ch[BOSSAREA] ~= false and s.ch[CINEMATICS] ~= false and s.ch[ENEMYRESET] ~= false
end

local function callWithCaller(what, f)
    -- the game passes a menu object as Caller and reports back through IF_SessionEvent; we want no callback
    local ok, err = pcall(f, nil)
    if not ok then log(what .. " with nil caller failed (" .. tostring(err) .. "), retrying with the game state")
        ok, err = pcall(f, FindFirstOf("BP_AppGameState_C")) end
    log(what .. (ok and " sent" or (" FAILED " .. tostring(err))))
end

local function tick()
    readConfig()
    if cfg.enabled == "0" then allowSend = false; return end
    local s = snapshot()
    if not s then return end
    local now = os.time()

    -- learn intent from what happens, only when a session or connection starts: right after a leave
    -- through the menu the game still reports the old connection for a moment (2-PC test 2026-10-26)
    local hosting = (s.authority and s.created and s.signal ~= 0) and true or false
    local joined = (s.multi and not s.authority) and true or false
    local hostingStarted, joinStarted = hosting and not wasHosting, joined and not wasJoined
    wasHosting, wasJoined = hosting, joined
    if hostingStarted and not hostSticky and cfg.host ~= "off" then
        hostSticky = true; guestSticky = false; log("host mode on (session created here)")
    end
    if joinStarted and not guestSticky and cfg.guest ~= "off" then
        guestSticky = true; hostSticky = false
        local names = {}
        for _, ps in ipairs(FindAllOf("PlayerState") or {}) do
            local n = try(function() return ps.PlayerName:ToString() end)
            if n then names[#names + 1] = n end
        end
        hostName = table.concat(names, " + ")   -- everyone in the session; logged only
        log("guest mode on (joined a host; players: " .. hostName .. ")")
    end
    local wantHost = s.authority and (cfg.host == "always" or (cfg.host == "auto" and hostSticky))
    local wantGuest = cfg.guest == "always" or (cfg.guest == "auto" and guestSticky)

    local line = stateLine(s)
    if line ~= lastLine then log("STATE " .. line); lastLine = line end

    -- un-grey the menu entry wherever hosting makes sense, also before the first (manual) signal
    allowSend = cfg.host ~= "off" and s.online and s.prohib == false and s.boss == 0
    if isCalm(s) then calmSince = calmSince or now else calmSince = nil end
    if s.pawnName ~= lastPawnName then   -- respawn or travel: wait the full settle time again
        lastPawnName = s.pawnName
        if calmSince then calmSince = now end
    end
    if not calmSince or now - calmSince < SETTLE_S then return end

    if wantHost then
        if not s.created then
            if now - lastCreate >= HOST_RETRY_S then
                lastCreate = now
                log("host: no session -> Event_CreateLobby(" .. publicConnections .. ")")
                callWithCaller("Event_CreateLobby", function(c) s.gi:Event_CreateLobby(publicConnections, false, c) end)
            end
        elseif s.ch[FIELD] == false and now - lastOpen >= OPEN_RETRY_S then
            lastOpen = now
            log("host: session closed for Field -> OpenOnlineSession(Field)")
            local ok, err = pcall(function() s.sm:OpenOnlineSession(s.gs, FIELD) end)
            if not ok then log("OpenOnlineSession FAILED " .. tostring(err)) end
        end
    elseif wantGuest and s.authority and not s.multi and not s.created and not s.searching then
        if now - lastSearch >= GUEST_RETRY_S then
            lastSearch = now
            log("guest: not connected -> Event_FindAndJoinSession (last host: " .. tostring(hostName) .. ")")
            callWithCaller("Event_FindAndJoinSession", function(c) s.gi:Event_FindAndJoinSession(c) end)
        end
    end
end

-- Allow "send distress signal" in beaten areas while host mode wants it (vanilla greys it out there).
local okSend, errSend = pcall(function()
    RegisterHook("/Script/Extensions.AppSessionManager:IsSendRescueSignal",
        function() if allowSend then return true end end,
        function() if allowSend then return true end end)
end)
log("IsSendRescueSignal override " .. (okSend and "registered" or ("FAILED " .. tostring(errSend))))

-- Leaving: the menu's "cancel signal" / "leave" ends in the native DestroyOnlineSessionLatent (seen
-- 2026-10-25), while vanilla boss and wipe teardowns do not call it (session 2). Hooks on Blueprint
-- functions (the menu, the game instance's Event_*) cannot be registered on this UE4SS build.
-- On the guest it fired only when the player left through the menu, not on the boss-end kick or on
-- deaths (2-PC session, 2026-10-26). So on either side a destroy means "I chose to stop".
local okDestroy, errDestroy = pcall(function()
    RegisterHook("/Script/Extensions.AppOnlineWrapper:DestroyOnlineSessionLatent", function()
        if hostSticky then
            hostSticky = false; log("session destroyed through the game's menu flow -> host auto mode off")
        elseif guestSticky then
            guestSticky = false; log("left the host through the game's menu flow -> guest auto mode off")
        else
            log("DestroyOnlineSessionLatent seen (auto mode already off)")
        end
    end)
end)
log("DestroyOnlineSessionLatent hook " .. (okDestroy and "registered" or ("FAILED " .. tostring(errDestroy))))

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

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if not worldSettled() then return end
        local ok, err = pcall(tick)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)
log("loaded from " .. MOD_DIR)
