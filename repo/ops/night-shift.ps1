#!/usr/bin/env pwsh
# Night Shift runner for native Windows (no WSL). Scheduled hourly via
# Register-ScheduledTask (see install.ps1). Mirrors night-shift.sh's shape:
# check the budget gates, then work tasks one claude invocation at a time,
# re-checking the budget between each. Every failure path exits WITHOUT
# running claude (fail closed). check_budget.py is the single source of
# truth for gate logic on every platform -- this wrapper never reimplements it.

$ErrorActionPreference = "Stop"
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Load config.env (plain KEY="VALUE" lines, same file every platform reads) ---
$Config = @{}
Get-Content (Join-Path $Base "config.env") | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -match '^\s*$') { return }
    if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') {
        $Config[$Matches[1]] = $Matches[2]
    }
}
function Cfg($name, $default = "") {
    if ($Config.ContainsKey($name) -and $Config[$name]) { return $Config[$name] }
    return $default
}

$LogDir = [Environment]::ExpandEnvironmentVariables((Cfg "LOG_DIR" "$HOME\claude-night-shift\logs"))
$ModeFile = [Environment]::ExpandEnvironmentVariables((Cfg "MODE_FILE" "$HOME\claude-night-shift\mode"))
$SecretsDir = [Environment]::ExpandEnvironmentVariables((Cfg "SECRETS_DIR" "$HOME\claude-night-shift\secrets"))
$RepoDir = [Environment]::ExpandEnvironmentVariables((Cfg "REPO_DIR"))
$ClaudeBin = [Environment]::ExpandEnvironmentVariables((Cfg "CLAUDE_BIN" "claude"))
$GithubRepo = Cfg "GITHUB_REPO"
$MaxTasksPerRun = [int](Cfg "MAX_TASKS_PER_RUN" "6")
$TaskTimeoutMin = [int](Cfg "TASK_TIMEOUT_MIN" "90")
$MaxTurnsPerTask = Cfg "MAX_TURNS_PER_TASK" "250"
$Model = Cfg "MODEL" ""

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "night-shift.log"
function Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -Append -Encoding utf8 $LogFile
}

$Python3 = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $Python3) { $Python3 = Get-Command python -ErrorAction SilentlyContinue }
if (-not $Python3) { Log "no python3/python on PATH; aborting"; exit 0 }

# --- single-instance lock ---
$LockDir = Join-Path $Base ".lock"
try {
    New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
} catch {
    $oldPid = $null
    $pidFile = Join-Path $LockDir "pid"
    if (Test-Path $pidFile) { $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue }
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        exit 0   # a previous run is still working; that's fine
    }
    Remove-Item -Recurse -Force $LockDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $LockDir -ErrorAction SilentlyContinue | Out-Null
}
$PID | Out-File (Join-Path $LockDir "pid")

# Keep the machine awake for this run only (mirrors caffeinate/systemd-inhibit).
# The override is scoped to THIS process's image name and is always cleared
# in the finally block below, even on error or Ctrl-C.
$ProcName = (Get-Process -Id $PID).ProcessName + ".exe"
powercfg /requestsoverride PROCESS $ProcName SYSTEM | Out-Null

function Invoke-Budget($mode) {
    $env:WORK_START_HOUR = Cfg "WORK_START_HOUR" "8"
    $env:WORK_END_HOUR = Cfg "WORK_END_HOUR" "18"
    $env:WORKDAYS = Cfg "WORKDAYS" "0,1,2,3,4"
    $env:PCT_PER_WORK_HOUR = Cfg "PCT_PER_WORK_HOUR" "1.0"
    $env:SAFETY_FACTOR = Cfg "SAFETY_FACTOR" "1.25"
    $env:MIN_SURPLUS_START = Cfg "MIN_SURPLUS_START" "8"
    $env:MIN_SURPLUS_CONTINUE = Cfg "MIN_SURPLUS_CONTINUE" "3"
    $env:WEEKLY_HARD_CAP = Cfg "WEEKLY_HARD_CAP" "85"
    $env:FIVE_HOUR_MAX_START = Cfg "FIVE_HOUR_MAX_START" "90"
    $env:FIVE_HOUR_MAX_CONTINUE = Cfg "FIVE_HOUR_MAX_CONTINUE" "95"
    $env:LOG_DIR = $LogDir
    $env:MODE_FILE = $ModeFile
    $env:MODEL = $Model
    $env:SECRETS_DIR = $SecretsDir
    $env:GITHUB_REPO = $GithubRepo
    $out = & $Python3.Path (Join-Path $Base "check_budget.py") --mode $mode 2>>$LogFile
    return @{ Text = ($out -join "`n"); Code = $LASTEXITCODE }
}

try {
    # --- Gate check (with one token-refresh retry on exit code 3) ---------------
    $result = Invoke-Budget "start"
    if ($result.Code -eq 3) {
        Log "OAuth token stale; refreshing with a minimal claude call"
        & $ClaudeBin -p "Reply with exactly: ok" --model claude-haiku-4-5-20251001 *>> $LogFile
        $result = Invoke-Budget "start"
    }
    if ($result.Code -ne 0) {
        Log "no-go (rc=$($result.Code)): $($result.Text)"
        exit 0
    }
    Log "GO: $($result.Text)"

    # --- Prepare the repo clone ---------------------------------------------------
    $TokenFile = Join-Path $SecretsDir "github-token"
    if (-not (Test-Path $TokenFile)) { Log "missing $TokenFile; aborting"; exit 0 }
    $env:GH_TOKEN = (Get-Content $TokenFile -Raw).Trim()
    $env:GITHUB_REPO = $GithubRepo

    if (-not (Test-Path $RepoDir)) { Log "REPO_DIR $RepoDir missing; aborting"; exit 0 }
    Push-Location $RepoDir
    git remote set-url origin "https://x-access-token:$($env:GH_TOKEN)@github.com/$GithubRepo.git"
    git fetch origin 2>>$LogFile
    if ($LASTEXITCODE -ne 0) { Log "git fetch failed; aborting"; Pop-Location; exit 0 }
    git checkout -q main; git reset -q --hard origin/main; git clean -qfd

    # --- Task loop -----------------------------------------------------------------
    $tasks = 0
    while ($tasks -lt $MaxTasksPerRun) {
        $result = Invoke-Budget "continue"
        if ($result.Code -ne 0) { Log "stopping loop (rc=$($result.Code)): $($result.Text)"; break }

        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $RunLog = Join-Path $LogDir "task-$stamp.json"
        Log "task invocation $($tasks + 1) -> $RunLog"

        # Model precedence: CONTROL.md's model line (in $result.Text as
        # model_override) beats the local MODEL knob, which beats the
        # account default.
        $effectiveModel = $Model
        try {
            $decision = $result.Text | ConvertFrom-Json
            if ($decision.model_override) { $effectiveModel = $decision.model_override }
        } catch { }
        $modelArgs = @()
        if ($effectiveModel) { $modelArgs = @("--model", $effectiveModel) }

        $promptText = Get-Content (Join-Path $RepoDir "RUNNER_PROMPT.md") -Raw
        $proc = Start-Process -FilePath $ClaudeBin -ArgumentList (
            @("-p", $promptText,
              "--settings", (Join-Path $Base "runner-settings.json"),
              "--permission-mode", "acceptEdits",
              "--max-turns", "$MaxTurnsPerTask",
              "--output-format", "json") + $modelArgs
        ) -NoNewWindow -PassThru -RedirectStandardOutput $RunLog -RedirectStandardError $LogFile

        $finished = $proc.WaitForExit($TaskTimeoutMin * 60 * 1000)
        $tasks++
        if (-not $finished) {
            Log "task invocation hit the ${TaskTimeoutMin}m wall clock; killing and will resume next run"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            continue
        }
        $rc = $proc.ExitCode

        $runLogContent = ""
        if (Test-Path $RunLog) { $runLogContent = Get-Content $RunLog -Raw -ErrorAction SilentlyContinue }
        if ($runLogContent -match "NO_ACTIONABLE_TASKS") { Log "queue empty; done for now"; break }
        if ($rc -ne 0) { Log "claude exited rc=$rc (usage limit or error); stopping loop"; break }

        $marker = [regex]::Match($runLogContent, "TASK_COMPLETE \d+ [A-D]")
        Log "invocation finished: $(if ($marker.Success) { $marker.Value } else { 'no completion marker' })"

        git checkout -q main; git reset -q --hard origin/main; git clean -qfd
    }
    Log "run complete; task invocations: $tasks"
} finally {
    powercfg /requestsoverride PROCESS $ProcName | Out-Null
    Remove-Item -Recurse -Force $LockDir -ErrorAction SilentlyContinue
    if (Get-Location -Stack -ErrorAction SilentlyContinue) {
        try { Pop-Location -ErrorAction SilentlyContinue } catch { }
    }
}
