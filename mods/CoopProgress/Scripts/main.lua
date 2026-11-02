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

-- Host -> guest story position, for progress outside boss kills. The host calls the game's own co-op symbol sync,
-- ScenarioPlayerComponent:MulticastSetSyncedSymbols(symbols, results), on its character, with the marker below first and
-- its position second. Solo test 2026-10-28: the call works from Lua, the hook reads both arrays, and it does not change
-- CheckGameProgress. Whether it reaches the guest's copy of the host's character is untested (needs two PCs).
local MARKER = "CoopProgress.pos"
local PUBLISH_S = 10
local function hostPublishes() return cfg.host_publish == "1" and (role() == "host" or (role() == "solo" and cfg.solo_as_guest == "1")) end
local lastPublished, lastPublishAt = nil, 0
local function publishPosition()
    if not hostPublishes() then return end
    local pos = currentPosition()
    if not pos or pos == 0 then return end
    if pos == lastPublished and os.time() - lastPublishAt < 60 then return end   -- resend every minute for late joiners
    local p = localPawn()
    local comp
    for _, c in ipairs(FindAllOf("ScenarioPlayerComponent") or {}) do
        if valid(c) and p and name(try(function() return c:GetOwner() end)) == name(p) then comp = c end
    end
    if not comp then return end
    local ok, err = pcall(function() comp:MulticastSetSyncedSymbols({MARKER, line[pos].sym}, {true, true}) end)
    if ok then
        if pos ~= lastPublished then journal("HOST", "published position " .. pos .. " " .. line[pos].sym) end
        lastPublished, lastPublishAt = pos, os.time()
    else
        journal("HOST", "publish FAILED " .. tostring(err):sub(1, 100))
    end
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
    if not isGuestSide() or (cfg.guest_rewards ~= "1" and cfg.guest_progress ~= "1") then return end
    if last == false then journal("GUEST", defeat .. ": not the last phase, waiting"); return end
    if cfg.guest_rewards == "1" then
        local ok, err = pcall(giveRewards, area, defeat)
        if not ok then journal("GUEST", "rewards error: " .. tostring(err):sub(1, 120)) end
    end
    if cfg.guest_progress == "1" then
        local ok, err = pcall(moveProgress, defeat)
        if not ok then journal("GUEST", "progress error: " .. tostring(err):sub(1, 120)) end
    end
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
local lastFlags, flagErr = nil, false
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

LoopAsync(DIFF_S * 1000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(diffFlags)
        if not ok then log("flag diff error: " .. tostring(err):sub(1, 120)) end
        ok, err = pcall(position)
        if not ok then log("position error: " .. tostring(err):sub(1, 120)) end
        if os.time() % PUBLISH_S < DIFF_S then
            ok, err = pcall(publishPosition)
            if not ok then log("publish error: " .. tostring(err):sub(1, 120)) end
        end
    end)
    return false
end)

log("loaded from " .. MOD_DIR .. " | hooks: " .. table.concat(hooked, ", "))
