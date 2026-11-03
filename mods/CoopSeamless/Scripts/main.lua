-- CoopSeamless: automatic "step out and rejoin" for Code Vein co-op. Host and guests run the same mod.
-- Host: once you have hosted in this game run (or host=always), the mod re-sends the distress signal
--   and opens the Field channel whenever the session is gone or closed and the game is calm (no boss
--   fight, no cutscene, no Home Base, no loading). It also lets the menu send a signal in areas whose
--   boss is dead.
-- Guest: once you have joined a host in this game run (or guest=always), the mod searches and joins
--   again after a disconnect (boss kill, death).
-- Cancelling the signal or leaving through the menu turns auto mode off until you host or join again by hand.
-- config.txt in the mod folder (read every second):  enabled=1  host=auto|always|off  guest=auto|always|off
-- Proposal 2026-11-03, all off by default (untested in game):
--   sessiondiag=1   log only: signatures of the search/join functions, and after any search the found signals with their names
--   lockhost=1      guest: rejoin only the host he joined by hand (search, pick that host's signal, join); no join if he is absent
--   remember=1      keep the role and the host's name in state.txt, so auto mode is back after a crash or a restart
--   versioncheck=1  host sends a fingerprint of CoopSeamless/CoopProbe/CoopProgress to a guest who joins; the guest logs mismatches
local TAG = "[CoopSeamless] "
local SETTLE_S, HOST_RETRY_S, OPEN_RETRY_S, GUEST_RETRY_S = 8, 30, 10, 25
local FIELD, BOSSAREA, CINEMATICS, ENEMYRESET = 1, 2, 4, 8   -- ESessionOpenness
local ROLE_AUTHORITY = 3

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]main%.lua$") or "."
local function log(s) print(TAG .. os.date("%H:%M:%S ") .. tostring(s) .. "\n") end
local function valid(o) return o ~= nil and o:IsValid() end
local function try(f, ...) local ok, v = pcall(f, ...); if ok then return v end return nil end

local cfg = {enabled = "1", host = "auto", guest = "auto", sessiondiag = "0", lockhost = "0", remember = "0", versioncheck = "0"}
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
local lockedHost = nil             -- lockhost: the one host this guest rejoins (his PlayerName, i.e. the Steam name)

-- remember: role and host name survive a crash or restart (state.txt next to config.txt; names can hold spaces, so not in config)
local STATE_PATH = MOD_DIR .. "\\state.txt"
local function saveState(role, host)
    local f = io.open(STATE_PATH, "w")
    if f then f:write("role=" .. role .. "\n"); if host then f:write("host=" .. host .. "\n") end; f:close() end
end
local function loadState()
    local f = io.open(STATE_PATH, "r")
    if not f then return nil end
    local st = {}
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(.*)$")
        if k then st[k] = v end
    end
    f:close()
    return st
end

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

-- Search/join by host (proposal 2026-11-03). From the paks and the exe (not run yet): App_GameInstance has Event_SearchLobby
-- (MaxResult) and Event_JoinSession(SearchResult) next to Event_FindAndJoinSession; UAppOnlineWrapperIF has
-- GetFoundOnlineSessionsCount, GetOnlineSessionResult, GetFoundOnlineSessionInfo, ShowInviteUI; the engine's
-- FindSessionsCallbackProxy:GetServerName(BlueprintSessionResult) gives the owner's name (Steam OSS). Parameter names and
-- order are read from the UFunctions at run time, nothing is assumed: an unknown parameter stops the call.
local GI_PATH = "/Game/Modes/App_GameInstance.App_GameInstance_C:"
local IF_OWNERS = {"/Script/Extensions.AppSessionManager:", "/Script/Extensions.AppOnlineWrapper:", "/Script/Extensions.AppOnlineWrapperIF:"}
local function paramNames(path)
    local fn = StaticFindObject(path)
    if not valid(fn) then return nil end
    local names = {}
    fn:ForEachProperty(function(p) names[#names + 1] = p:GetFName():ToString() end)
    return names
end
local function findFn(name)        -- first owner class that has this UFunction
    for _, o in ipairs(IF_OWNERS) do
        local n = paramNames(o .. name)
        if n then return o .. name, n end
    end
end
-- call obj:fname with arguments picked by parameter name from `values` (a value of false is passed as is; "nil" means nil)
local function callByNames(obj, fname, names, values)
    local args, n = {}, 0
    for _, p in ipairs(names) do
        if p ~= "ReturnValue" then
            local v = values[p]
            if v == nil then return false, "unknown parameter " .. p end
            n = n + 1
            if v ~= "nil" then args[n] = v end
        end
    end
    return pcall(function() return obj[fname](obj, table.unpack(args, 1, n)) end)
end

local function logSignatures()
    for _, e in ipairs({"Event_SearchLobby", "Event_JoinSession", "Event_FindAndJoinSession", "Event_CreateLobby"}) do
        local n = paramNames(GI_PATH .. e)
        log("diag: " .. e .. "(" .. (n and table.concat(n, ", ") or "NOT FOUND") .. ")")
    end
    for _, f in ipairs({"GetFoundOnlineSessionsCount", "GetOnlineSessionResult", "GetFoundOnlineSessionInfo", "FindOnlineSessionsLatent",
                        "JoinOnlineSessionLatent", "ShowInviteUI", "CancelFindOnlineSessions"}) do
        local path, n = findFn(f)
        log("diag: " .. (path or f) .. "(" .. (n and table.concat(n, ", ") or "NOT FOUND") .. ")")
    end
    local n = paramNames("/Script/OnlineSubsystemUtils.FindSessionsCallbackProxy:GetServerName")
    log("diag: FindSessionsCallbackProxy:GetServerName(" .. (n and table.concat(n, ", ") or "NOT FOUND") .. ")")
end

-- the found signals after a search: { {result = <BlueprintSessionResult>, name = <owner name or nil>}, ... } or nil + reason
local SEARCH_VALUES_BASE = {Caller = "nil", JoinSessionCaller = "nil", SearchLobbyCaller = "nil", MaxResult = 50, UseLAN = false, bUseLAN = false}
local function foundSessions(s)
    local cPath, cNames = findFn("GetFoundOnlineSessionsCount")
    local rPath, rNames = findFn("GetOnlineSessionResult")
    if not (cPath and rPath) then return nil, "count/result functions not found" end
    local ctx = {WorldContextObject = s.gs}
    local ok, count = callByNames(s.sm, "GetFoundOnlineSessionsCount", cNames, ctx)
    if not ok or type(count) ~= "number" then return nil, "count: " .. tostring(count) end
    local proxy = StaticFindObject("/Script/OnlineSubsystemUtils.Default__FindSessionsCallbackProxy")
    local list = {}
    for i = 0, count - 1 do
        local vals = {WorldContextObject = s.gs, InSearchResultsIndex = i, Index = i}
        local okR, res = callByNames(s.sm, "GetOnlineSessionResult", rNames, vals)
        if not okR then return nil, "result " .. i .. ": " .. tostring(res) end
        local name = valid(proxy) and try(function() return proxy:GetServerName(res):ToString() end) or nil
        list[#list + 1] = {result = res, name = name}
    end
    return list
end

-- lockhost: 1) Event_SearchLobby, 2) when the search is over, join the signal whose owner is lockedHost, else wait
local pickPending, pickSince = false, 0
local function searchForHost(s)
    local n = paramNames(GI_PATH .. "Event_SearchLobby")
    if not n then log("lockhost: Event_SearchLobby not found -> no join"); return end
    local ok, err = callByNames(s.gi, "Event_SearchLobby", n, SEARCH_VALUES_BASE)
    log("lockhost: searching for " .. tostring(lockedHost) .. (ok and "" or (" FAILED " .. tostring(err))))
    if ok then pickPending, pickSince = true, os.time() end
end
local function pickHost(s)
    pickPending = false
    local list, why = foundSessions(s)
    if not list then log("lockhost: cannot read the results (" .. tostring(why) .. ") -> no join"); return end
    local names = {}
    for _, e in ipairs(list) do
        names[#names + 1] = tostring(e.name)
        if e.name and e.name == lockedHost then
            local n = paramNames(GI_PATH .. "Event_JoinSession")
            local vals = {}
            for k, v in pairs(SEARCH_VALUES_BASE) do vals[k] = v end
            vals.SearchResult = e.result
            local ok, err = n and callByNames(s.gi, "Event_JoinSession", n, vals)
            log("lockhost: joining " .. lockedHost .. ((n and ok) and "" or (" FAILED " .. tostring(n and err or "Event_JoinSession not found"))))
            return
        end
    end
    log("lockhost: " .. lockedHost .. " is not among " .. #list .. " signal(s) [" .. table.concat(names, ", ") .. "] -> waiting")
end

-- versioncheck: FNV-1a of each mod's main.lua; the host sends "CoopVersion:<mod>=<hash>,..." with ClientMessage (a client RPC,
-- already used by CoopProbe as a host -> guest channel); the guest compares with his own files
local MODS_DIR = MOD_DIR:match("^(.*)[/\\][^/\\]+$") or "."
local function fingerprint()
    local parts = {}
    for _, m in ipairs({"CoopSeamless", "CoopProbe", "CoopProgress"}) do
        local f = io.open(MODS_DIR .. "\\" .. m .. "\\Scripts\\main.lua", "rb")
        local h = "absent"
        if f then
            local data = f:read("a"); f:close()
            local x = 2166136261
            for i = 1, #data do x = ((x ~ data:byte(i)) * 16777619) & 0xFFFFFFFF end
            h = string.format("%08x", x)
        end
        parts[#parts + 1] = m .. "=" .. h
    end
    return table.concat(parts, ",")
end
local myPrint = nil
local lastOthers = 0
local function sendVersion()
    myPrint = myPrint or fingerprint()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) and not try(function() return c:IsLocalPlayerController() end) then
            pcall(function() c:ClientMessage("CoopVersion:" .. myPrint, FName("None"), 0) end)
        end
    end
    log("versioncheck: sent " .. myPrint)
end
pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(ctx, msg)
        if cfg.versioncheck ~= "1" then return end
        local text = try(function() return msg:get():ToString() end)
        local theirs = text and text:match("^CoopVersion:(.*)$")
        if not theirs then return end
        myPrint = myPrint or fingerprint()
        if theirs == myPrint then log("versioncheck: same mods as the host (" .. theirs .. ")"); return end
        local mine = {}
        for m, h in myPrint:gmatch("(%w+)=(%w+)") do mine[m] = h end
        for m, h in theirs:gmatch("(%w+)=(%w+)") do
            if mine[m] ~= h then log("versioncheck: MISMATCH " .. m .. " host=" .. h .. " here=" .. tostring(mine[m])) end
        end
    end)
end)

local stateLoaded, sigLogged, wasSearching, versionAt = false, false, false, nil
local function tick()
    readConfig()
    if cfg.enabled == "0" then allowSend = false; return end
    local s = snapshot()
    if not s then return end
    local now = os.time()

    if not stateLoaded then
        stateLoaded = true
        local st = cfg.remember == "1" and loadState() or nil
        if st and st.role == "host" and cfg.host ~= "off" then
            hostSticky = true; log("remember: host mode on from state.txt")
        elseif st and st.role == "guest" and cfg.guest ~= "off" then
            guestSticky = true; lockedHost = st.host; log("remember: guest mode on from state.txt (host: " .. tostring(st.host) .. ")")
        end
    end
    if cfg.sessiondiag == "1" and not sigLogged then sigLogged = true; logSignatures() end
    if wasSearching and not s.searching and cfg.sessiondiag == "1" then
        local list, why = foundSessions(s)
        if list then
            local names = {}
            for _, e in ipairs(list) do names[#names + 1] = tostring(e.name) end
            log("diag: search over, " .. #list .. " signal(s): [" .. table.concat(names, ", ") .. "]")
        else
            log("diag: search over, results not readable (" .. tostring(why) .. ")")
        end
    end
    wasSearching = s.searching and true or false
    if cfg.versioncheck == "1" and s.authority and s.created then
        local others = s.others or 0
        if others > lastOthers then versionAt = now + 5 end   -- a guest arrived: give his controller a moment
        lastOthers = others
        if versionAt and now >= versionAt then versionAt = nil; sendVersion() end
    else
        lastOthers = 0
    end

    -- learn intent from what happens, only when a session or connection starts: right after a leave
    -- through the menu the game still reports the old connection for a moment (2-PC test 2026-10-26)
    local hosting = (s.authority and s.created and s.signal ~= 0) and true or false
    local joined = (s.multi and not s.authority) and true or false
    local hostingStarted, joinStarted = hosting and not wasHosting, joined and not wasJoined
    wasHosting, wasJoined = hosting, joined
    if hostingStarted and not hostSticky and cfg.host ~= "off" then
        hostSticky = true; guestSticky = false; log("host mode on (session created here)")
        if cfg.remember == "1" then saveState("host") end
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
        -- lockhost: with one guest (vanilla cap) the one other name is the host
        local me
        for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
            if try(function() return pc:IsLocalPlayerController() end) then me = try(function() return pc.PlayerState.PlayerName:ToString() end) end
        end
        local others = {}
        for _, n in ipairs(names) do if n ~= me then others[#others + 1] = n end end
        if #others == 1 then lockedHost = others[1] else log("lockhost: " .. #others .. " other players, host not known") end
        if cfg.remember == "1" then saveState("guest", lockedHost) end
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
        if cfg.lockhost == "1" and lockedHost then
            if pickPending then
                if now - pickSince >= 3 then pickHost(s) end
            elseif now - lastSearch >= GUEST_RETRY_S then
                lastSearch = now
                searchForHost(s)
            end
        elseif now - lastSearch >= GUEST_RETRY_S then
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
        if cfg.remember == "1" then saveState("none") end
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
