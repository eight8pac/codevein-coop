@echo off
rem Code Vein co-op (guest): install a newer kit from the host's share, then start the game through Steam.
rem Lives in ...\CODE VEIN\CodeVein\Binaries\Win64\ (next to the game exe). Put a desktop shortcut to it.
rem The last steps are ONE parenthesised block: cmd reads a block completely before it runs it, and an update may replace
rem this very file while it runs (without the block, cmd went on at the old position in the new file).
setlocal
set "W=%~dp0"
(
  if exist "%W%plugins\CoopLauncher.ps1" powershell -NoProfile -ExecutionPolicy Bypass -File "%W%plugins\CoopLauncher.ps1" -Win64 "%W%."
  start "" "steam://rungameid/678960"
  exit /b 0
)
