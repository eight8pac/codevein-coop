@echo off
rem Code Vein co-op (guest): install a newer kit from the host's share, then start the game through Steam.
rem Lives in ...\CODE VEIN\CodeVein\Binaries\Win64\ (next to the game exe). Put a desktop shortcut to it.
rem The last steps are ONE parenthesised block: cmd reads a block completely before it runs it, and an update may replace
rem this very file while it runs (without the block, cmd went on at the old position in the new file).
rem Full path: on the guest PC plain "powershell" was not found (the exit log zip failed the same way, error 2).
setlocal
set "W=%~dp0"
(
  if exist "%W%plugins\CoopLauncher.ps1" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%W%plugins\CoopLauncher.ps1" -Win64 "%W%."
  start "" "steam://rungameid/678960"
  exit /b 0
)
