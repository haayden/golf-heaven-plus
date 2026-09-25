# Close RV There Yet (gracefully when possible), relaunch it through Steam, and wait until the
# GHPDev harness answers. New mod folders and mods.txt changes need a full restart like this.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
# Plain `bash` can resolve to WSL, which can't see this path; use Git Bash explicitly.
$bash = 'C:\Program Files\Git\bin\bash.exe'

$game = Get-Process -Name 'Ride-Win64-Shipping' -ErrorAction SilentlyContinue
if ($game) {
    [void]$game.CloseMainWindow()
    if (-not $game.WaitForExit(20000)) { Stop-Process -Id $game.Id -Force; Start-Sleep -Seconds 2 }
}

Start-Process 'steam://rungameid/3949040'

$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $reply = & $bash "$repo/tools/ghp.sh" ping 2>$null
    if ($reply -eq 'pong') { Write-Output 'game is up, GHPDev answered'; exit 0 }
}
Write-Output 'timed out waiting for GHPDev'
exit 1
