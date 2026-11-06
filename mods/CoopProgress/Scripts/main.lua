-- CoopProgress: what a guest misses in Code Vein co-op (cranebeaker/coop-anything#207, eight8pac/codevein-coop#1).
-- Step 1, always on, read-only: logs boss rewards, progress flag changes and the main story position.
-- Steps 2 and 3, off by default, guest side only, triggered by the boss area's MulticastGainRewards on the guest's own
-- game (the boss area is a level actor, so the guest has its reward lists and defeat symbol without any network channel):
--   guest_rewards=1   give the guest the host's BossAreaRewards when the guest list is empty, once per boss (ledger.txt)
--   guest_progress=1  move the guest's main story position up to the boss's defeat symbol, never down; also up to the
--                     host's position when the host publishes it
--   host_publish=1    (host) send the host's story position to the guests through the game's co-op symbol sync
-- Both copy every .sav under %LOCALAPPDATA%\CodeVein\Saved\SaveGames to backups\<time>\ before their first write of a
-- game run, and write nothing if that copy fails. solo_as_guest=1 runs the guest side in solo play, for tests only.
-- Output: the UE4SS log, plus one line per event in journal.txt next to config.txt.
-- config.txt (read at load): enabled=1 journal=1 guest_rewards=0 guest_progress=0 host_publish=0 solo_as_guest=0
-- Status 2026-10-28: all of it tested in solo play only (steps 2 and 3 and the position channel with solo_as_guest=1,
-- the channel as a loopback on one PC). Nothing has run in a two-player session yet.
local TAG = "[CoopProgress] "
local ROLE_AUTHORITY = 3

local MOD_DIR = debug.getinfo(1, "S").source:match("^@(.*)[/\\]Scripts[/\\]main%.lua$") or "."
local function log(s) print(TAG .. os.date("%H:%M:%S ") .. tostring(s) .. "\n") end
local function try(f) local ok, v = pcall(f); if ok then return v end return nil end
local function valid(o) return o ~= nil and try(function() return o:IsValid() end) end
local function name(o) return try(function() return o:GetFName():ToString() end) or "?" end

local cfg = {enabled = "1", journal = "1", guest_rewards = "0", guest_progress = "0", host_publish = "0", solo_as_guest = "0"}
local f = io.open(MOD_DIR .. "\\config.txt", "r")
if f then
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*([%w_]+)")
        if k then cfg[k] = v end
    end
    f:close()
end
if cfg.enabled == "0" then log("disabled in config.txt"); return end

-- one line per event, tab-separated: time, role, kind, details
local function role()
    local gs = FindFirstOf("BP_AppGameState_C")
    local sm = FindFirstOf("AppSessionManager")
    if not valid(gs) then return "noworld" end
    local auth = try(function() return gs.Role end) == ROLE_AUTHORITY
    local multi = valid(sm) and try(function() return sm:IsOnlineMultiplay(gs) end)
    if not multi then return "solo" end
    return auth and "host" or "guest"
end
local function journal(kind, details)
    log(kind .. " " .. details)
    if cfg.journal == "0" then return end
    local j = io.open(MOD_DIR .. "\\journal.txt", "a")
    if j then j:write(os.date("%Y-%m-%d %H:%M:%S") .. "\t" .. role() .. "\t" .. kind .. "\t" .. details .. "\n"); j:close() end
end

-- any parameter as text: numbers and bools as is, FName/FString/FText through ToString, objects by name
local function text(v)
    if type(v) ~= "userdata" then return tostring(v) end
    return try(function() return v:ToString() end) or (valid(v) and name(v)) or "obj"
end
local function args(...)
    local out = {}
    for _, p in ipairs({...}) do out[#out + 1] = text(try(function() return p:get() end)) end
    return table.concat(out, ", ")
end

-- a reward array as "Item xCount; ...". Field names from the Dumper-7 SDK (RoeanAigis/CodeVein-SDK, UE 4.18.3):
-- FBossAreaReward { ItemArticle, ItemCount, DegenerationType }, FBossAreaCooperativePlayReward { RewardArticle, Count }.
local function rewards(arr, itemField, countField)
    if arr == nil then return "nil" end
    local out = {}
    local ok, err = pcall(function()
        arr:ForEach(function(_, e)
            local r = e:get()
            local item = try(function() return r[itemField] end)
            local count = try(function() return r[countField] end)
            out[#out + 1] = (valid(item) and name(item) or "?") .. " x" .. tostring(count or "?")
        end)
    end)
    if not ok then return "unreadable (" .. tostring(err):sub(1, 80) .. ")" end
    return #out == 0 and "empty" or table.concat(out, "; ")
end

local hooked = {}
local function hook(path, fn)
    local ok, err = pcall(function() RegisterHook(path, fn) end)
    hooked[#hooked + 1] = path:match("[^.]+$") .. (ok and " ok" or " FAILED")
    if not ok then log("hook " .. path .. " FAILED " .. tostring(err):sub(1, 90)) end
end

-- Main story line (main_progress.txt, from DT_ProgressSymbol's MainProgress rows): position = last true symbol.
local line, lineIndex = {}, {}
local lf = io.open(MOD_DIR .. "\\main_progress.txt", "r")
if lf then
    for l in lf:lines() do
        local row, sym = l:match("^([^#\t]+)\t(%S+)")
        if sym then line[#line + 1] = {row = row, sym = sym}; lineIndex[sym] = #line end
    end
    lf:close()
end
local function saveManager() return StaticFindObject("/Script/Extensions.Default__AppSaveManager") end
local function helper() return StaticFindObject("/Script/Extensions.Default__CharacterHelper") end
local function currentPosition()
    local sm, ctx = saveManager(), FindFirstOf("BP_AppGameState_C")
    if not (valid(sm) and valid(ctx)) then return nil end
    local pos, gap = 0, nil
    for i, e in ipairs(line) do
        if try(function() return sm:CheckGameProgress(e.sym, ctx) end) then
            if pos < i - 1 and not gap then gap = line[pos + 1].sym .. " false before " .. e.sym end
            pos = i
        end
    end
    return pos, gap
end
local function localPawn()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if try(function() return pc:IsLocalPlayerController() end) then
            local p = try(function() return pc.Pawn end)
            if valid(p) then return p end
        end
    end
end

-- Save backup, once per game run, before the first write. Copies every .sav under SaveGames (byte for byte, with io)
-- to backups\<time>\ in the mod folder. Any failure means no backup, and then nothing is written.
local backupDone = nil
local function ensureBackup()
    if backupDone ~= nil then return backupDone end
    backupDone = false
    local root = (os.getenv("LOCALAPPDATA") or "") .. "\\CodeVein\\Saved\\SaveGames"
    local dest = MOD_DIR .. "\\backups\\" .. os.date("%Y%m%d-%H%M%S")
    local ok, err = pcall(function()
        local list = assert(io.popen('dir /b /s "' .. root .. '\\*.sav"'))
        local files = {}
        for p in list:lines() do files[#files + 1] = p end
        list:close()
        assert(#files > 0, "no .sav under " .. root)
        for _, p in ipairs(files) do
            local rel = p:sub(#root + 2)
            local dir = (dest .. "\\" .. rel):match("^(.*)\\[^\\]+$")
            os.execute('mkdir "' .. dir .. '" 2>nul')
            local i = assert(io.open(p, "rb")); local data = i:read("a"); i:close()
            local o = assert(io.open(dest .. "\\" .. rel, "wb")); o:write(data); o:close()
            local c = assert(io.open(dest .. "\\" .. rel, "rb")); local back = c:read("a"); c:close()
            assert(#back == #data, "copy size differs for " .. rel)
        end
        journal("BACKUP", #files .. " save files -> " .. dest)
    end)
    if not ok then journal("BACKUP", "FAILED, nothing will be written: " .. tostring(err):sub(1, 160)) end
    backupDone = ok
    return ok
end

-- Ledger of rewards already given, one "defeatSymbol|article" per line, so a boss with two phases (two multicasts) or a
-- second kill gives its rewards once. It is per installation, not per save slot.
local ledger = {}
local lg = io.open(MOD_DIR .. "\\ledger.txt", "r")
if lg then for l in lg:lines() do ledger[l] = true end; lg:close() end
local function remember(key)
    ledger[key] = true
    local w = io.open(MOD_DIR .. "\\ledger.txt", "a"); if w then w:write(key .. "\n"); w:close() end
end

local function isGuestSide()
    local r = role()
    return r == "guest" or (r == "solo" and cfg.solo_as_guest == "1")
end

-- Step 2: the host's boss items for the guest. Weapons go through UpdateWeaponInventoryInfo, items through GainItem
-- (each tested on its own from a test-only helper on 2026-10-28).
local function giveRewards(area, defeat)
    local toGuest = try(function() return area.BossAreaRewardsToGuest:GetArrayNum() end) or 0
    if toGuest > 0 then journal("GUEST", defeat .. ": the game has its own guest rewards here, none added"); return end
    local p, h = localPawn(), helper()
    if not (p and valid(h)) then journal("GUEST", "no pawn, rewards skipped"); return end
    local entries = {}
    pcall(function()
        area.BossAreaRewards:ForEach(function(_, e)
            local r = e:get()
            entries[#entries + 1] = {article = try(function() return r.ItemArticle end), count = try(function() return r.ItemCount end) or 0,
                degeneration = try(function() return r.DegenerationType end) or 0}
        end)
    end)
    for _, e in ipairs(entries) do
        if valid(e.article) and e.count > 0 then
            local art = name(e.article)
            local key = defeat .. "|" .. art
            if ledger[key] then
                journal("GUEST", "already given: " .. key)
            elseif ensureBackup() then
                local cls = name(try(function() return e.article:GetClass() end))
                local ok, err
                if cls:find("Weapon", 1, true) then
                    ok, err = pcall(function() h:UpdateWeaponInventoryInfo(p, e.article, e.count, e.degeneration, 0, false) end)
                else
                    ok, err = pcall(function() return h:GainItem(p, e.article, e.count) end)
                end
                journal("GUEST", "give " .. art .. " x" .. e.count .. " (" .. cls .. ") " .. (ok and "ok" or ("FAILED " .. tostring(err):sub(1, 100))))
                if ok then remember(key) end
            end
        end
    end
end

-- Step 3: a symbol on the guest's story line (a boss's defeat symbol, or the host's position), only forward, only for
-- symbols on the main line.
local function moveProgress(symbol)
    local target = lineIndex[symbol]
    if not target then journal("GUEST", symbol .. " is not on the main story line, progress unchanged"); return end
    local pos = currentPosition()
    if not pos then journal("GUEST", "position unreadable, progress unchanged"); return end
    if pos >= target then journal("GUEST", string.format("position %d already at or past %s (%d)", pos, symbol, target)); return end
    if not ensureBackup() then return end
    local ctx = localPawn() or FindFirstOf("BP_AppGameState_C")
    local ok, err = pcall(function() saveManager():SetGameProgress(symbol, ctx, true) end)
    journal("GUEST", string.format("progress %d -> %s (%d) %s", pos, symbol, target, ok and "ok" or ("FAILED " .. tostring(err):sub(1, 100))))
end

-- Story flags outside the main line (2026-11-03, two-PC test): after the host's boss kill and final cutscene, flags such as
-- Boss_St09_Suc (boss done: fog wall, NPCs), <map>.BP_CheckPoint_Boss (Mistle), Get_BreathBC (blood code) and
-- St09_Scenario1_FirstTime flipped on the host only; the position channel moves the main line alone. The host also publishes
-- every BoolMap flag that turns true (except IAF_* item pickups, which stay per player) with the marker "CoopProgress.flag";
-- the guest sets it with SetGameProgress(flag, ctx, true), only false -> true, after the same save backup.
local lastFlags, flagErr = nil, false
local fullApplied, reloadAt = 0, nil
local FLAG_MARKER = "CoopProgress.flag"
local function setFlag(flag)
    local cur = lastFlags and lastFlags["BoolMap:" .. flag]
    if cur == "true" then journal("GUEST", "flag " .. flag .. " already true"); return end
    if not ensureBackup() then return end
    local ctx = localPawn() or FindFirstOf("BP_AppGameState_C")
    local ok, err = pcall(function() saveManager():SetGameProgress(flag, ctx, true) end)
    journal("GUEST", "flag " .. flag .. " -> true " .. (ok and "ok" or ("FAILED " .. tostring(err):sub(1, 100))))
    if ok then reloadAt = os.time() + 3 end
end

-- Full flag sync (2026-11-03, two-PC test: the flips during the session arrived, but older differences between the two saves
-- and the ValMap numbers were never synced; NPCs and the fog wall stayed). When a guest joins, the host sends its whole flag
-- state in batches of FULL_BATCH entries with the marker "CoopProgress.full": "B:<flag>" for every true BoolMap flag (no IAF_*
-- item pickups) and "V:<name>=<n>" for every non-zero ValMap value. The guest applies only what is ahead of his own state
-- (false -> true, a smaller number -> the host's), after the same save backup, then asks AScenarioProgressLoader to reload
-- the story-dependent world (ReloadProgress), so objects that read the flags when they were loaded can catch up.
local FULL_MARKER, FULL_BATCH = "CoopProgress.full", 40
local function applyFull(entries)
    local n = 0
    local ctx = localPawn() or FindFirstOf("BP_AppGameState_C")
    for _, e in ipairs(entries) do
        local b = e:match("^B:(.+)$")
        local vname, vval = e:match("^V:(.+)=(%-?%d+)$")
        if b and not b:find("^IAF_") and not b:find("^WAF_") and (not lastFlags or lastFlags["BoolMap:" .. b] ~= "true") then
            if not ensureBackup() then return end
            if pcall(function() saveManager():SetGameProgress(b, ctx, true) end) then n = n + 1 end
        elseif vname then
            local cur = tonumber(lastFlags and lastFlags["ValMap:" .. vname] or "0") or 0
            local want = tonumber(vval) or 0
            if want > cur then
                if not ensureBackup() then return end
                if pcall(function() saveManager():SetGameProgressInt(vname, ctx, want) end) then n = n + 1 end
            end
        end
    end
    fullApplied = fullApplied + n
    if n > 0 then
        journal("GUEST", "full sync batch: " .. n .. " of " .. #entries .. " entries applied (" .. fullApplied .. " so far)")
        reloadAt = os.time() + 3   -- after the last batch: reload the story-dependent world once
    end
end
local function reloadWorldProgress()
    if not reloadAt or os.time() < reloadAt then return end
    reloadAt = nil
    local loaders = FindAllOf("ScenarioProgressLoader") or {}
    local done = 0
    for _, l in ipairs(loaders) do
        if valid(l) and pcall(function() l:ReloadProgress() end) then done = done + 1 end
    end
    journal("GUEST", "world progress reload: " .. done .. " of " .. #loaders .. " ScenarioProgressLoader(s); " .. fullApplied .. " entries applied in total")
end

-- Host -> guest story position, for progress outside boss kills. The host calls the game's own co-op symbol sync,
-- ScenarioPlayerComponent:MulticastSetSyncedSymbols(symbols, results), on its character, with the marker below first and
-- its position second. Solo test 2026-10-28: the call works from Lua, the hook reads both arrays, and it does not change
-- CheckGameProgress. Whether it reaches the guest's copy of the host's character is untested (needs two PCs).
local MARKER = "CoopProgress.pos"
local PUBLISH_S = 10
local function hostPublishes() return cfg.host_publish == "1" and (role() == "host" or (role() == "solo" and cfg.solo_as_guest == "1")) end
local lastPublished, lastPublishAt = nil, 0
local flagQueue = {}
local function publishFlags(comp)
    while #flagQueue > 0 do
        local f = flagQueue[1]
        local ok, err = pcall(function() comp:MulticastSetSyncedSymbols({FLAG_MARKER, f}, {true, true}) end)
        if not ok then journal("HOST", "flag publish FAILED " .. tostring(err):sub(1, 100)); return end
        journal("HOST", "published flag " .. f)
        table.remove(flagQueue, 1)
    end
end
local fullQueue, guestCount = {}, 0
local function queueFullState()
    if not lastFlags then return false end
    local entries = {}
    for k, v in pairs(lastFlags) do
        local b = k:match("^BoolMap:(.+)$")
        local vn = k:match("^ValMap:(.+)$")
        if b and v == "true" and not b:find("^IAF_") and not b:find("^WAF_") then entries[#entries + 1] = "B:" .. b
        elseif vn and v ~= "0" and tonumber(v) then entries[#entries + 1] = "V:" .. vn .. "=" .. v end
    end
    table.sort(entries)
    for i = 1, #entries, FULL_BATCH do
        local batch = {FULL_MARKER}
        for j = i, math.min(i + FULL_BATCH - 1, #entries) do batch[#batch + 1] = entries[j] end
        fullQueue[#fullQueue + 1] = batch
    end
    journal("HOST", "full flag state queued for the guest: " .. #entries .. " entries in " .. #fullQueue .. " batch(es)")
    return true
end
local function remoteControllers()
    local n = 0
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and try(function() return pc:IsLocalPlayerController() end) == false then n = n + 1 end
    end
    return n
end
local function publishFull(comp)
    -- a new guest -> send everything (once per join), one batch per publish tick
    local n = remoteControllers()
    if n > guestCount then
        if queueFullState() then guestCount = n end
    elseif n < guestCount then guestCount = n end
    local batch = table.remove(fullQueue, 1)
    if not batch then return end
    local results = {}
    for i = 1, #batch do results[i] = true end
    local ok, err = pcall(function() comp:MulticastSetSyncedSymbols(batch, results) end)
    if not ok then journal("HOST", "full sync batch FAILED " .. tostring(err):sub(1, 100)); table.insert(fullQueue, 1, batch) end
end
local function publishPosition()
    if not hostPublishes() then return end
    local pos = currentPosition()
    if not pos or pos == 0 then return end
    if pos == lastPublished and os.time() - lastPublishAt < 60 and #flagQueue == 0 and #fullQueue == 0 and remoteControllers() <= guestCount then return end   -- resend every minute for late joiners
    local p = localPawn()
    -- FindAllOf + GetOwner on every ScenarioPlayerComponent crashed UE4SS (null read at UE4SS.dll+0x2AED17) when a skip had just
    -- replaced characters: half-destroyed components are still listed (2026-11-03, host; same crash as codevein-coop's guest
    -- Mistle crashes). Take the component straight from our own character (BP_Player.ScenarioPlayer).
    local comp = valid(p) and try(function() return p.ScenarioPlayer end) or nil
    if not valid(comp) then return end
    publishFlags(comp)
    publishFull(comp)
    local ok, err = pcall(function() comp:MulticastSetSyncedSymbols({MARKER, line[pos].sym}, {true, true}) end)
    if ok then
        if pos ~= lastPublished then journal("HOST", "published position " .. pos .. " " .. line[pos].sym) end
        lastPublished, lastPublishAt = pos, os.time()
    else
        journal("HOST", "publish FAILED " .. tostring(err):sub(1, 100))
    end
end

-- Host decides the ending (2026-11-04). The Successor bosses end in Boss_StXX_Ret when every ReturnFlags vestige is broken, else in
-- Boss_StXX_Suc (memory map IsReturn; table by Rikka, #1). The host's game sets that flag in the step after the memory, which the
-- guest's game never runs, and BP hooks do not register on this UE4SS build. So the host works the result out at the kill and
-- sends the flag on the normal flag channel; the guest has it well before his final cutscene.
local RETURN_FLAGS = {Boss_St07 = {10, 13, 14, 15, 16}, Boss_St09 = {19, 20, 22, 23},
                      Boss_St11 = {25, 28, 29, 31, 32}, Boss_St12 = {34, 37, 38, 40, 41}}
local function hostEnding(defeat)
    local need = RETURN_FLAGS[defeat]
    if not need then return end
    -- the game's own question, the same one IsReturn asks; a plain call is safe (only hooking it froze the load, Rikka); the flag
    -- copy is the fallback
    local gs = FindFirstOf("BP_AppGameState_C")
    local ret, missing, source = true, {}, "game"
    for _, n in ipairs(need) do
        local sym = "IAF_BloodCrystal_BrokenNormal_" .. n
        local ok, v = pcall(function() return saveManager():CheckGameProgress(sym, gs) end)
        if not ok or type(v) ~= "boolean" then
            source = "copy"
            if not lastFlags then journal("HOST", "ending " .. defeat .. ": no answer for " .. sym .. " and no flag copy, nothing sent"); return end
            v = lastFlags["BoolMap:" .. sym] == "true"
        end
        if not v then ret = false; missing[#missing + 1] = n end
    end
    local flag = defeat .. (ret and "_Ret" or "_Suc")
    flagQueue[#flagQueue + 1] = flag
    journal("HOST", "ending " .. defeat .. " decided at the kill: " .. flag .. " (missing vestiges: " .. (#missing > 0 and table.concat(missing, " ") or "none") .. ", from the " .. source .. ")")
end

-- Boss kill. Runs on host and guest in co-op, and in solo play (solo tests, 2026-10-28), once per boss phase.
hook("/Script/Extensions.BossAreaBase:MulticastGainRewards", function(ctx, ...)
    local area = try(function() return ctx:get() end)
    if not valid(area) then journal("REWARDS", "area unreadable"); return end
    local defeat = text(try(function() return area.BossDefeatSymbol end))
    local last = try(function() return area:IsLastPhase() end)
    journal("REWARDS", string.format("area=%s id=%s defeat=%s lastPhase=%s host=[%s] guest=[%s] coopHost=[%s] coopGuest=[%s]",
        name(area), text(try(function() return area.BossAreaId end)), defeat, tostring(last),
        rewards(try(function() return area.BossAreaRewards end), "ItemArticle", "ItemCount"),
        rewards(try(function() return area.BossAreaRewardsToGuest end), "ItemArticle", "ItemCount"),
        rewards(try(function() return area.CooperativePlayRewardToHost end), "RewardArticle", "Count"),
        rewards(try(function() return area.CooperativePlayRewardToGuest end), "RewardArticle", "Count")))
    -- 2026-11-03 (Rikka, #1): the post-memory ending is chosen by the memory map's IsReturn: every ReturnFlags entry (the
    -- Successor's broken vestiges, IAF_BloodCrystal_BrokenNormal_*) true -> Boss_StXX_Ret, else Boss_StXX_Suc. Log those flags
    -- on both PCs at each boss phase, plus the _Ret/_Suc flags, to compare host and guest.
    if lastFlags then
        local broken, branch = {}, {}
        for k, v in pairs(lastFlags) do
            local n = k:match("^BoolMap:IAF_BloodCrystal_BrokenNormal_(%d+)$")
            if n then broken[#broken + 1] = {tonumber(n), v} end
            local b = k:match("^BoolMap:(Boss_St%d+_[RS][eu][tc])$")
            if b and b:find(tostring(defeat), 1, true) == 1 then branch[#branch + 1] = b .. "=" .. v end
        end
        table.sort(broken, function(x, y) return x[1] < y[1] end)
        local parts = {}
        for _, e in ipairs(broken) do parts[#parts + 1] = e[1] .. "=" .. e[2] end
        table.sort(branch)
        journal("VESTIGES", defeat .. " broken vestiges: " .. table.concat(parts, " ") .. " | " .. table.concat(branch, " "))
    end
    if hostPublishes() and last ~= false then
        local ok, err = pcall(hostEnding, tostring(defeat))
        if not ok then journal("HOST", "ending error: " .. tostring(err):sub(1, 120)) end
    end
    if not isGuestSide() or (cfg.guest_rewards ~= "1" and cfg.guest_progress ~= "1") then return end
    if last == false then journal("GUEST", defeat .. ": not the last phase, waiting"); return end
    if cfg.guest_rewards == "1" then
        local ok, err = pcall(giveRewards, area, defeat)
        if not ok then journal("GUEST", "rewards error: " .. tostring(err):sub(1, 120)) end
    end
    if cfg.guest_progress == "1" then
        local ok, err = pcall(moveProgress, defeat)
        if not ok then journal("GUEST", "progress error: " .. tostring(err):sub(1, 120)) end
        -- 2026-11-03: the host's <defeat>_Suc flips right before its final cutscene and reached the guest ~5 s later; when his
        -- final cutscene started first, his game chose the other ending. Set it here, at the kill, if his flag store has it.
        -- (the four Successor bosses: the host's decision arrives on the flag channel instead, see hostEnding)
        local suc = tostring(defeat) .. "_Suc"
        if not RETURN_FLAGS[tostring(defeat)] and lastFlags and lastFlags["BoolMap:" .. suc] ~= nil then
            local ok2, err2 = pcall(setFlag, suc)
            if not ok2 then journal("GUEST", "early " .. suc .. " error: " .. tostring(err2):sub(1, 120)) end
        end
    end
end)

-- 2026-11-06: when a cutscene's picture really starts: the ready flags and the audio prepare line do not show it (5 s gap on screen)
hook("/Script/MovieScene.MovieSceneSequencePlayer:Play", function(ctx)
    local o = try(function() return ctx:get() end)
    journal("SYNC", "SequencePlayer:Play " .. (valid(o) and tostring(try(function() return o:GetFullName() end)):sub(1, 140) or "?"))
end)

-- Story flags. Hooks on the UAppSaveManager setters register but saw nothing while Boss_St07's flags changed (solo test
-- 2026-10-28): the game sets them natively. They stay as a cheap signal; the flag store itself is diffed below.
for _, fn in ipairs({"SetGameProgress", "SetGameProgressInt"}) do
    hook("/Script/Extensions.AppSaveManager:" .. fn, function(_, ...) journal("FLAG", fn .. "(" .. args(...) .. ")") end)
end

-- The game's own co-op symbol sync and Haze RPCs (SDK), logged to learn when vanilla uses them in a two-player session:
-- the guest asks with ServerSetSyncedSymbols, the host answers everyone with MulticastSetSyncedSymbols (symbols, results).
for _, fn in ipairs({"ScenarioPlayerComponent:MulticastSetSyncedSymbols", "ScenarioPlayerComponent:ServerSetSyncedSymbols",
                     "ScenarioPlayerComponent:MulticastFlowDiagramSetSyncedSymbols", "ScenarioPlayerComponent:ServerFlowDiagramSetSyncedSymbols",
                     "ScenarioManager:StartLargePolyLoad", "ScenarioManager:PrepareLargePolySequence", "ScenarioManager:PlayLargePolySequence", "ScenarioManager:PlayLargePoly",
                     "ScenarioPlayerComponent:ServerSetReadyToPlay", "ScenarioPlayerComponent:MulticastSetReadyToPlay",
                     "ScenarioPlayerComponent:ServerSetReadyToFinish", "ScenarioPlayerComponent:MulticastSetReadyToFinish",
                     "ScenarioPlayerComponent:ServerSetReadyToSkip", "ScenarioPlayerComponent:ServerSetOnlineMultiplaySynced",
                     "ScenarioPlayerComponent:MulticastSetOnlineMultiplaySynced",
                     "HumanContextComponent:Client_AddExp", "HumanContextComponent:Server_AddExp"}) do
    hook("/Script/Extensions." .. fn, function(ctx, ...)
        local parts = {}
        for _, p in ipairs({...}) do
            local v = try(function() return p:get() end)
            local list = {}
            if type(v) == "userdata" and pcall(function() v:ForEach(function(_, e) list[#list + 1] = text(e:get()) end) end) and #list > 0 then
                parts[#parts + 1] = "[" .. table.concat(list, ",") .. "]"
            else
                parts[#parts + 1] = text(v)
            end
        end
        journal("SYNC", fn:match(":(.+)$") .. "(" .. table.concat(parts, "; ") .. ") on " .. name(try(function() return ctx:get() end)))
        -- the host's full flag state, published by publishFull() on the host's PC (on his join)
        if fn:find("MulticastSetSyncedSymbols", 1, true) and parts[1] and parts[1]:find("^%[" .. FULL_MARKER:gsub("%.", "%%.") .. ",")
           and isGuestSide() and cfg.guest_progress == "1" then
            local entries = {}
            for e in parts[1]:sub(2, -2):gmatch("[^,]+") do entries[#entries + 1] = e end
            table.remove(entries, 1)   -- the marker
            local ok, err = pcall(applyFull, entries)
            if not ok then journal("GUEST", "full sync error: " .. tostring(err):sub(1, 120)) end
        end
        -- a host flag, published by publishFlags() on the host's PC
        if fn:find("MulticastSetSyncedSymbols", 1, true) and parts[1] and parts[1]:find("^%[" .. FLAG_MARKER:gsub("%.", "%%.") .. ",")
           and isGuestSide() and cfg.guest_progress == "1" then
            local fl = parts[1]:match("^%[[^,]+,([^%]]+)%]")
            if fl then
                local ok, err = pcall(setFlag, fl)
                if not ok then journal("GUEST", "host flag error: " .. tostring(err):sub(1, 120)) end
            end
        end
        -- the host's position, published by publishPosition() on the host's PC
        if fn:find("MulticastSetSyncedSymbols", 1, true) and parts[1] and parts[1]:find("^%[" .. MARKER:gsub("%.", "%%.") .. ",")
           and isGuestSide() and cfg.guest_progress == "1" then
            local sym = parts[1]:match("^%[[^,]+,([^,%]]+)")
            if sym then
                local ok, err = pcall(moveProgress, sym)
                if not ok then journal("GUEST", "host position error: " .. tostring(err):sub(1, 120)) end
            end
        end
    end)
end

-- The flag store (SDK): UGameProgressFlagTable { TMap<FString,int32> ValMap; TMap<FString,bool> BoolMap; ... }.
-- Every DIFF_S seconds the two maps are read and every change since the last read is journaled as FLAG lines.
local DIFF_S = 2
local function readFlags()
    local t = FindFirstOf("GameProgressFlagTable")
    if not valid(t) then return nil end
    local flags = {}
    for _, m in ipairs({"BoolMap", "ValMap"}) do
        local ok = pcall(function()
            t[m]:ForEach(function(k, v) flags[m .. ":" .. text(k:get())] = text(v:get()) end)
        end)
        if not ok then return nil end
    end
    return flags
end
local function diffFlags()
    local now = readFlags()
    if not now then
        if not flagErr then flagErr = true; log("flag store unreadable (not loaded yet, or TMap reads unsupported)") end
        return
    end
    flagErr = false
    -- loading a save fills the store at once (219 FLAG lines on the second solo test): a jump in size is a new baseline
    local count, lastCount = 0, 0
    for _ in pairs(now) do count = count + 1 end
    if lastFlags then for _ in pairs(lastFlags) do lastCount = lastCount + 1 end end
    if lastFlags and math.abs(count - lastCount) > 50 then
        log("flag store changed size " .. lastCount .. " -> " .. count .. " (save loaded?): new baseline, no diff")
        lastFlags = now
        return
    end
    if lastFlags then
        -- the keys exist from the title screen on, so loading a save changes values, not the size: a burst of
        -- changes in one read is a load (third solo test), journaled as one line
        local changes = {}
        for k, v in pairs(now) do
            if lastFlags[k] ~= v then changes[#changes + 1] = k .. " " .. tostring(lastFlags[k]) .. " -> " .. v end
        end
        for k, v in pairs(lastFlags) do
            if now[k] == nil then changes[#changes + 1] = k .. " " .. v .. " -> removed" end
        end
        if #changes > 50 then
            journal("LOAD", #changes .. " flag changes at once: new baseline")
        else
            for _, c in ipairs(changes) do journal("FLAG", c) end
            if hostPublishes() then
                for k, v in pairs(now) do
                    local fl = k:match("^BoolMap:(.+)$")
                    if fl and v == "true" and lastFlags[k] == "false" and not fl:find("^IAF_") and not fl:find("^WAF_") then flagQueue[#flagQueue + 1] = fl end
                end
            end
        end
    else
        log("flag store read: " .. count .. " entries")
    end
    lastFlags = now
end
-- Main story position. The MainProgress symbols are not in the two maps; CheckGameProgress reads them as one position on
-- an ordered line (solo tests: setting Reached_St07_Boss also made Vol_St07_A and SubBoss_St07 true). A true symbol after
-- a false one is reported, since it would break the one-position model.
local lastPos, gapReported = nil, false
local function position()
    if #line == 0 then return end
    local pos, gap = currentPosition()
    if not pos then return end
    if gap and not gapReported then gapReported = true; journal("GAP", gap) end
    if pos ~= lastPos then
        local e = line[pos]
        journal("POSITION", string.format("%d/%d %s", pos, #line, e and (e.row .. ":" .. e.sym) or "start"))
        lastPos = pos
    end
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
LoopAsync(DIFF_S * 1000, function()
    if not coopEngineReady() then return false end
    ExecuteInGameThread(function()
        local ok, err = pcall(diffFlags)
        if not ok then log("flag diff error: " .. tostring(err):sub(1, 120)) end
        ok, err = pcall(position)
        if not ok then log("position error: " .. tostring(err):sub(1, 120)) end
        ok, err = pcall(reloadWorldProgress)
        if not ok then log("reload error: " .. tostring(err):sub(1, 120)) end
        -- while full-sync batches or flags are queued, publish every DIFF_S instead of every PUBLISH_S
        if os.time() % PUBLISH_S < DIFF_S or #fullQueue > 0 or #flagQueue > 0 then
            ok, err = pcall(publishPosition)
            if not ok then log("publish error: " .. tostring(err):sub(1, 120)) end
        end
    end)
    return false
end)

log("loaded from " .. MOD_DIR .. " | hooks: " .. table.concat(hooked, ", "))
