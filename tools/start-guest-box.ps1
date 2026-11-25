# One-PC guest (2026-11-17): start the guest copy game2 inside the Sandboxie-Plus box CoopGuest, under a second Steam account that
# is logged in to the boxed Steam (its login, saves and settings live in C:\Sandbox\<user>\CoopGuest; game2's Binaries\Win64 is an
# OpenFilePath, so mods and logs are written there directly). The runner leaves game2 alone while local\onepc-guest.txt exists.
# The game must start with game2's Win64 as working directory: steam_api looks for steam_appid.txt in the working directory, and
# without it Steam restarts the game from the real install (seen 16:03 on 11-17, harmless inside the box, but without our mods).
$Root = Split-Path $PSScriptRoot   # the test folder (this script sits in its tools folder)
$sb = 'C:\Program Files\Sandboxie-Plus\Start.exe'
$g = Join-Path $Root 'game2\CodeVein\Binaries\Win64'
$exe = Join-Path $g 'CodeVein-Win64-Shipping.exe'
if (-not (Test-Path $sb)) { 'Sandboxie-Plus is not installed'; exit 1 }
if (Get-Process CodeVein-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($g, 'OrdinalIgnoreCase') }) { 'the guest copy is already running'; exit 0 }

# the boxed Steam: its own registry says which steam.exe it is (ActiveProcess pid inside the box)
function BoxSteamPid {
  $tmp = Join-Path $g 'boxsteam.txt'
  Remove-Item $tmp -ErrorAction SilentlyContinue
  Start-Process -FilePath $sb -ArgumentList '/box:CoopGuest', '/wait', 'cmd', '/c', "reg query HKCU\Software\Valve\Steam\ActiveProcess /v pid > `"$tmp`" 2>&1" -Wait -WindowStyle Hidden
  $line = Get-Content $tmp -ErrorAction SilentlyContinue | Where-Object { $_ -match 'pid\s+REG_DWORD\s+0x([0-9a-fA-F]+)' } | Select-Object -First 1
  Remove-Item $tmp -ErrorAction SilentlyContinue
  if (-not $line) { return 0 }
  $id = [Convert]::ToInt32(($line -replace '.*0x', ''), 16)
  if ($id -and (Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'steam' })) { return $id }
  return 0
}
$sp = BoxSteamPid
if (-not $sp) {
  'starting Steam in the box (second account)...'
  Start-Process -FilePath $sb -ArgumentList '/box:CoopGuest', '"C:\Program Files (x86)\Steam\steam.exe"'
  for ($i = 0; $i -lt 40 -and -not $sp; $i++) { Start-Sleep -Seconds 3; $sp = BoxSteamPid }
  if (-not $sp) { 'the boxed Steam did not come up within 2 minutes (log in with the second account in it, then run this again)'; exit 1 }
  Start-Sleep -Seconds 10   # let it finish logging in
}
"boxed Steam: pid $sp"
Remove-Item (Join-Path $g 'ue4ss\UE4SS.log'), (Join-Path $g 'plugins\CoopNative.log') -ErrorAction SilentlyContinue
# the owner's window layout for the guest (windowed 1176x664 on the right monitor, 11-17): the game rewrites its settings file on exit
# and does not keep a dragged window position, so the saved copy is put back before every start (box copy only, never the real file)
$gus = Join-Path $Root 'local\onepc-guest-GameUserSettings.ini'
$localData = [Environment]::GetFolderPath('LocalApplicationData'); $profileDir = [Environment]::GetFolderPath('UserProfile')
$boxGus = Join-Path ('C:\Sandbox\' + $env:USERNAME + '\CoopGuest\user\current' + $localData.Substring($profileDir.Length)) 'CodeVein\Saved\Config\WindowsNoEditor\GameUserSettings.ini'
if ((Test-Path $gus) -and (Test-Path (Split-Path $boxGus))) { Copy-Item $gus $boxGus -Force }
# Own network ports (11-17 16:25/16:30): Code Vein also starts a Steam game server (game port 7777 = Unreal's default, Steam port +1,
# query port 27015). With the host copy running on the same PC those ports are taken, the guest's Steam init failed ("Steam server and
# client running on the same machine") and it fell back to offline mode. Unreal's own switches move the guest's ports.
# 11-18: with local\onepc-guest-noasync.txt the guest also starts with -NoAsyncLoadingThread (test: the BitArrayIndex crashes all run
# on FAsyncLoadingThread, same chain every time).
$gargs = @('/box:CoopGuest', "`"$exe`"", '-port=7787', '-QueryPort=27025')
if (Test-Path (Join-Path $Root 'local\onepc-guest-noasync.txt')) { $gargs += '-NoAsyncLoadingThread' }   # (an empty argument breaks Start-Process)
Start-Process -FilePath $sb -ArgumentList $gargs -WorkingDirectory $g
'guest copy starting (title in about 40 s)'

# Window position (11-17): the game ignores the saved WindowPosX/Y and opens where it likes; the owner dragged it over every time. A
# detached helper waits for the title screen, then moves the guest's window to the spot in local\onepc-guest-window.txt ("x,y").
$wf = Join-Path $Root 'local\onepc-guest-window.txt'
if (Test-Path $wf) {
  $xy = (Get-Content $wf -Raw).Trim() -split ','
  $mover = @"
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public struct GWR { public int L, T, R, B; } public static class GW { [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out GWR r); }'
`$log = '$g\ue4ss\UE4SS.log'
for (`$i = 0; `$i -lt 90; `$i++) { Start-Sleep -Seconds 2; if ((Test-Path `$log) -and (Select-String -Path `$log -Pattern 'title version' -Quiet)) { break } }
# (11-17 19:42: one move right after the title was undone by the game, which places the window relative to the monitor it opened on)
for (`$j = 0; `$j -lt 15; `$j++) {
  Start-Sleep -Seconds 2
  `$p = Get-Process CodeVein-Win64-Shipping -ErrorAction SilentlyContinue | Where-Object { `$_.Path -like '$g*' -and `$_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not `$p) { continue }
  `$r = New-Object GWR; [void][GW]::GetWindowRect(`$p.MainWindowHandle, [ref]`$r)
  if (`$r.L -ne $($xy[0]) -or `$r.T -ne $($xy[1])) { [void][GW]::SetWindowPos(`$p.MainWindowHandle, [IntPtr]::Zero, $($xy[0]), $($xy[1]), 0, 0, 0x0015) }
}
"@
  # (11-18: passed inline with -Command the multi-line script lost its quotes on the way and never moved anything; a file is safe)
  $mf = Join-Path $Root 'local\onepc-guest-window-mover.ps1'
  Set-Content -Path $mf -Value $mover -Encoding UTF8
  Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$mf`"" -WindowStyle Hidden
  "the window is moved to $($xy[0]),$($xy[1]) once the title shows"
}
