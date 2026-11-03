# One-time setup on the HOST PC (run as administrator): a LAN drop folder for the guest's automatic log zips.
#  - creates the local user "coopdrop" (no admin rights; you choose the password, it is asked for below)
#  - hides that user from the Windows login screen
#  - creates <project>\local\incoming and lets only coopdrop (and you) write there
#  - shares that folder as \\<this PC>\coopdrop, change access for coopdrop only
#  - enables "File and Printer Sharing" in the firewall for PRIVATE networks only (public networks stay closed)
# Nothing is sent anywhere; the share is reachable only from networks marked "Private" on this PC.
# Undo: Remove-SmbShare -Name coopdrop; Remove-LocalUser -Name coopdrop  (the folder and its files stay)

$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Please run this script as administrator (right-click PowerShell -> Run as administrator).' -ForegroundColor Red
    exit 1
}
$project = Split-Path $PSScriptRoot -Parent
$folder = Join-Path $project 'local\incoming'
$user = 'coopdrop'

Write-Host "Folder: $folder"
New-Item -ItemType Directory -Force -Path $folder | Out-Null

if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
    $pw = Read-Host -AsSecureString "Choose a password for the user '$user' (your brother's PC will store it once)"
    New-LocalUser -Name $user -Password $pw -Description 'Code Vein co-op log drop (LAN share only)' -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    Write-Host "User '$user' created."
} else {
    Write-Host "User '$user' already exists (password unchanged)."
}
# not shown on the login screen
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name $user -Value 0 -PropertyType DWord -Force | Out-Null

# folder permissions: coopdrop may write (Modify) in this folder only
$acl = Get-Acl $folder
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -Path $folder -AclObject $acl
Write-Host "Folder permission: $user may write in $folder"

# the share (change access for coopdrop, full access for you)
$me = $id.Name
if (Get-SmbShare -Name $user -ErrorAction SilentlyContinue) { Remove-SmbShare -Name $user -Force }
New-SmbShare -Name $user -Path $folder -ChangeAccess $user -FullAccess $me -Description 'Code Vein co-op log drop' | Out-Null
Write-Host "Share: \\$env:COMPUTERNAME\$user"

# firewall: File and Printer Sharing on private networks only (language-independent group id)
Get-NetFirewallRule -Group '@FirewallAPI.dll,-28502' | Where-Object { $_.Profile -match 'Private' } | Enable-NetFirewallRule
Write-Host 'Firewall: File and Printer Sharing enabled for private networks.'
Get-NetConnectionProfile | ForEach-Object { Write-Host ("Network '{0}' ({1}): {2}" -f $_.Name, $_.InterfaceAlias, $_.NetworkCategory) }
Write-Host ''
Write-Host 'Done. On your brother''s PC run once (as his normal user, not admin), with the password you chose:' -ForegroundColor Green
Write-Host "  cmdkey /add:$env:COMPUTERNAME /user:$env:COMPUTERNAME\$user /pass:<password>"
