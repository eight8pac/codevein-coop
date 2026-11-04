-- Syntax check without running: compiles each file (loadfile) and counts top-level locals (Lua's limit is 200 per function).
-- Usage: tools/lua.exe tools/luacheck.lua <file.lua> ...
local bad = 0
for _, path in ipairs(arg) do
    local f, e = loadfile(path)
    local n = 0
    for line in io.lines(path) do if line:match("^local ") then n = n + 1 end end
    if f then print(string.format("ok     %4d top-level locals  %s", n, path))
    else print("ERROR  " .. e); bad = bad + 1 end
    if n > 180 then print("WARN   near the 200-local limit: " .. path) end
end
os.exit(bad == 0 and 0 or 1)
