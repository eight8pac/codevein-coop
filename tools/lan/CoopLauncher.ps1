# Code Vein co-op (guest) launcher step: before the game starts, install a newer guest kit from the host's LAN share.
# The share comes from log_share= in plugins\CoopNative.ini; the newest kit is named in <share>\kits\latest.txt; the installed
# one in plugins\CoopKitVersion.txt. Nothing happens if the share cannot be reached (the game starts with the installed kit).
param([string]$Win64)
$logDir = Join-Path (Join-Path $Win64 'plugins') 'CoopLogs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'launcher.log'
try { Start-Transcript -Path $log -Force | Out-Null } catch {}
$plugins = Join-Path $Win64 'plugins'
$ini = Join-Path $plugins 'CoopNative.ini'
$share = ''
if (Test-Path $ini) {
    $line = Get-Content $ini | Where-Object { $_ -like 'log_share=*' } | Select-Object -First 1
    if ($line) { $share = $line.Substring(10).Trim() }
}
if (-not $share) { Write-Host 'Co-op update: no log_share in CoopNative.ini, skipped.'; try { Stop-Transcript | Out-Null } catch {}; exit 0 }
function Invoke-Timed([scriptblock]$Block, [object[]]$ArgList, [int]$Seconds) {
    $job = Start-Job -ScriptBlock $Block -ArgumentList $ArgList
    if (Wait-Job $job -Timeout $Seconds) { $r = Receive-Job $job -ErrorAction Stop; Remove-Job $job -Force; return $r }
    Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force -ErrorAction SilentlyContinue
    throw "no answer from the share after $Seconds s"
}
try {
    $kits = Join-Path $share 'kits'
    $latest = (Invoke-Timed { param($p) (Get-Content (Join-Path $p 'latest.txt') -ErrorAction Stop | Select-Object -First 1) } @($kits) 8).Trim()
    $vf = Join-Path $plugins 'CoopKitVersion.txt'
    $cur = ''
    if (Test-Path $vf) { $cur = (Get-Content $vf | Select-Object -First 1).Trim() }
    $have = $false
    if ($latest -and $latest -ne $cur) { $have = [bool](Invoke-Timed { param($p) Test-Path $p } @((Join-Path $kits $latest)) 8) }
    if ($have) {
        Write-Host "Co-op update: $cur -> $latest"
        $tmp = Join-Path $env:TEMP $latest
        Invoke-Timed { param($a, $b) Copy-Item -LiteralPath $a -Destination $b -Force } @((Join-Path $kits $latest), $tmp) 90 | Out-Null
        Expand-Archive -Path $tmp -DestinationPath $Win64 -Force
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Co-op update: up to date ($cur)"
    }
} catch {
    Write-Host "Co-op update: share not reachable ($_), starting with the installed kit."
}
try { Stop-Transcript | Out-Null } catch {}
# the host can read this without waiting for the next log zip
if ($share) { try { Invoke-Timed { param($a, $b) Copy-Item $a $b -Force -ErrorAction SilentlyContinue } @($log, (Join-Path $share 'launcher.log')) 8 | Out-Null } catch {} }
