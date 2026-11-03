# Code Vein co-op (guest) launcher step: before the game starts, install a newer guest kit from the host's LAN share.
# The share comes from log_share= in plugins\CoopNative.ini; the newest kit is named in <share>\kits\latest.txt; the installed
# one in plugins\CoopKitVersion.txt. Nothing happens if the share cannot be reached (the game starts with the installed kit).
param([string]$Win64)
$plugins = Join-Path $Win64 'plugins'
$ini = Join-Path $plugins 'CoopNative.ini'
$share = ''
if (Test-Path $ini) {
    $line = Get-Content $ini | Where-Object { $_ -like 'log_share=*' } | Select-Object -First 1
    if ($line) { $share = $line.Substring(10).Trim() }
}
if (-not $share) { Write-Host 'Co-op update: no log_share in CoopNative.ini, skipped.'; exit 0 }
try {
    $kits = Join-Path $share 'kits'
    $latest = (Get-Content (Join-Path $kits 'latest.txt') -ErrorAction Stop | Select-Object -First 1).Trim()
    $vf = Join-Path $plugins 'CoopKitVersion.txt'
    $cur = ''
    if (Test-Path $vf) { $cur = (Get-Content $vf | Select-Object -First 1).Trim() }
    if ($latest -and $latest -ne $cur -and (Test-Path (Join-Path $kits $latest))) {
        Write-Host "Co-op update: $cur -> $latest"
        Expand-Archive -Path (Join-Path $kits $latest) -DestinationPath $Win64 -Force
    } else {
        Write-Host "Co-op update: up to date ($cur)"
    }
} catch {
    Write-Host "Co-op update: share not reachable ($_), starting with the installed kit."
}
