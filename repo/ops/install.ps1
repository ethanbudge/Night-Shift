#!/usr/bin/env pwsh
# Installs (or updates) the Night Shift runner on native Windows (PowerShell
# 7+, no WSL required). Copies the runner scripts OUTSIDE the repo clone so
# the sandboxed agent can never modify the code that governs it. Re-run
# after changing these scripts.

$ErrorActionPreference = "Stop"
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dest = Join-Path $HOME "claude-night-shift"
$TaskName = "NightShift"

Write-Host "==> Checking prerequisites"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "git not found. Install Git for Windows first."; exit 1
}
$Python3 = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $Python3) { $Python3 = Get-Command python -ErrorAction SilentlyContinue }
if (-not $Python3) { Write-Error "python3/python not found on PATH"; exit 1 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error "claude CLI not found. Install it first, then run 'claude' -> /login."
    exit 1
}

Write-Host "==> Installing to $Dest"
New-Item -ItemType Directory -Force -Path (Join-Path $Dest "logs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Dest "secrets") | Out-Null

foreach ($f in @("night-shift.ps1", "check_budget.py", "runner-settings.json", "mode.sh", "secret_scan.py")) {
    Copy-Item (Join-Path $Src $f) (Join-Path $Dest $f) -Force
}
if (-not (Test-Path (Join-Path $Dest "config.env"))) {
    Copy-Item (Join-Path $Src "config.env") (Join-Path $Dest "config.env")
    Write-Host "    NOTE: edit $Dest\config.env (GITHUB_REPO at minimum)"
} else {
    Write-Host "    keeping existing config.env (compare against the shipped one for new knobs)"
}

Write-Host "==> Registering the hourly scheduled task"
$Action = New-ScheduledTaskAction -Execute "pwsh.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Dest\night-shift.ps1`""
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1) `
    -RepetitionDuration ([TimeSpan]::MaxValue)
$Settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Force | Out-Null

Write-Host "==> Done. Next steps if this is a first install:"
Write-Host "  1. Set-Content -NoNewline -Path $Dest\secrets\github-token -Value 'github_pat_...'"
Write-Host "  2. Edit $Dest\config.env"
Write-Host "  3. bash $Src\setup-labels.sh   (with GH_TOKEN exported; needs Git Bash or WSL for this one-time step)"
Write-Host "  4. cd into the repo clone, run 'claude' once to accept the folder trust prompt"
Write-Host "  5. Test: & '$($Python3.Path)' $Dest\check_budget.py --mode start; `$LASTEXITCODE"
Write-Host "  6. (optional) copy CONTROL.md into your tasks repo root for phone-based remote control"
Write-Host ""
Write-Host "To remove: Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
