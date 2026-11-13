<#
.SYNOPSIS
    Installs lockwatch on Windows as a Scheduled Task that runs at logon.

.DESCRIPTION
    - Copies lockwatch.py to C:\Program Files\lockwatch (admin-only writable,
      because the task runs elevated - powercfg /requests requires it).
    - Finds pythonw.exe (installs Python with winget if missing and you agree).
    - lockwatch reads the user's lock timeout (screen saver, inactivity
      policy, display-off timeout) itself unless -IdleThreshold is given.
    - Registers a task that starts at logon for the signed-in user with
      highest privileges, restarts on failure, and never times out.
    Logs go to %LOCALAPPDATA%\lockwatch\lockwatch.jsonl for that user.

.PARAMETER User
    Account to monitor (DOMAIN\user). Defaults to the user signed in at the
    console, so it still does the right thing if you elevate with a
    different admin account.

.PARAMETER IdleThreshold
    Seconds idle after which the screen should have locked. Auto-detected
    by lockwatch if omitted.

.PARAMETER Uninstall
    Removes the task and the program folder (logs are left in place).

.EXAMPLE
    .\install-windows.ps1
    .\install-windows.ps1 -IdleThreshold 600
    .\install-windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$User,
    [int]$IdleThreshold = 0,
    [switch]$Uninstall,
    [switch]$Yes,      # don't prompt (e.g. for installing Python)
    [switch]$Elevated  # internal: set when relaunched with admin rights
)

$ErrorActionPreference = 'Stop'
# The elevated window closes on exit; keep it open so the output can be read.
function Exit-Script([int]$code) {
    if ($Elevated) { Read-Host 'Press Enter to close' | Out-Null }
    exit $code
}
trap { Write-Host "ERROR: $_" -ForegroundColor Red; Exit-Script 1 }
$TaskName   = 'lockwatch'
$InstallDir = Join-Path $env:ProgramFiles 'lockwatch'
$ScriptSrc  = Join-Path $PSScriptRoot 'lockwatch.py'

# --- Elevate -----------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator rights...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)", "`"$($kv.Value)`"" }
    }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

# --- Uninstall ---------------------------------------------------------------
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    }
    Get-CimInstance Win32_Process -Filter "Name LIKE 'python%'" |
        Where-Object { $_.CommandLine -like "*$InstallDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Write-Host "Removed $InstallDir." }
    Write-Host 'lockwatch uninstalled. Logs in %LOCALAPPDATA%\lockwatch were kept.'
    Exit-Script 0
}

if (-not (Test-Path $ScriptSrc)) { throw "lockwatch.py not found next to this installer ($ScriptSrc)." }

# --- Target user -------------------------------------------------------------
if (-not $User) {
    $User = (Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $User) { $User = "$env:USERDOMAIN\$env:USERNAME" }
}
try {
    $sid = (New-Object Security.Principal.NTAccount($User)).Translate([Security.Principal.SecurityIdentifier]).Value
} catch { throw "Can't resolve user '$User'. Pass -User DOMAIN\name." }
Write-Host "Monitoring user: $User"

# --- Python ------------------------------------------------------------------
function Find-Pythonw {
    $cands = @()
    if (Get-Command py.exe -ErrorAction SilentlyContinue) {
        $exe = & py.exe -3 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $exe) { $cands += $exe.Trim() }
    }
    foreach ($n in 'python.exe', 'python3.exe') {
        Get-Command $n -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notlike '*\WindowsApps\*' } |   # skip Store alias stubs
            ForEach-Object { $cands += $_.Source }
    }
    $cands += Get-ChildItem "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | ForEach-Object FullName
    foreach ($c in $cands) {
        $w = Join-Path (Split-Path $c) 'pythonw.exe'
        if (Test-Path $w) {
            $ver = & $c -c "import sys; print(sys.version_info >= (3, 8))" 2>$null
            if ($ver -eq 'True') { return $w }
        }
    }
    return $null
}

$pythonw = Find-Pythonw
if (-not $pythonw) {
    Write-Warning 'Python 3.8+ was not found.'
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        $ok = $Yes -or ((Read-Host 'Install Python 3 for all users with winget? [y/N]') -match '^[Yy]')
        if ($ok) {
            winget install --id Python.Python.3.12 --scope machine --silent `
                --accept-package-agreements --accept-source-agreements
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path', 'User')
            $pythonw = Find-Pythonw
        }
    }
    if (-not $pythonw) { throw 'Install Python 3 for all users (python.org or winget), then run this again.' }
}
if ($pythonw -like "$env:SystemDrive\Users\*" -and $pythonw -notlike "*\$($User.Split('\')[-1])\*") {
    Write-Warning "Python is installed inside another user's profile ($pythonw); $User may not be able to run it. Install Python for all users if the task fails."
}
Write-Host "Using Python: $pythonw"

# --- Idle threshold ----------------------------------------------------------
# By default lockwatch reads the user's lock settings itself (screen saver,
# inactivity policy, display-off timeout) and re-checks them every 10 minutes.
$thresholdArg = ''
if ($IdleThreshold -gt 0) {
    $thresholdArg = " --idle-threshold $IdleThreshold"
    Write-Host "Idle threshold: $IdleThreshold seconds"
} else {
    Write-Host "Idle threshold: auto (read from this user's lock settings)"
}

# --- Install files -----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item $ScriptSrc (Join-Path $InstallDir 'lockwatch.py') -Force
Copy-Item (Join-Path $PSScriptRoot 'README.md') $InstallDir -Force -ErrorAction SilentlyContinue
Write-Host "Installed to $InstallDir"

# --- Scheduled task ----------------------------------------------------------
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute $pythonw `
               -Argument "`"$InstallDir\lockwatch.py`" --quiet$thresholdArg" `
               -WorkingDirectory $InstallDir
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $User
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
               -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Records what prevents the screen from locking (lockwatch).' | Out-Null
Write-Host "Registered scheduled task '$TaskName' (runs at logon, elevated)."

# Start now if that user is signed in.
if ((Get-CimInstance Win32_ComputerSystem).UserName -eq $User) {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 5
    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "Task started (state: $((Get-ScheduledTask -TaskName $TaskName).State), last result: $($info.LastTaskResult))."
}

$userHome = (Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid).LocalPath
Write-Host ''
Write-Host "Done. Log: $userHome\AppData\Local\lockwatch\lockwatch.jsonl"
Write-Host "Report:   `"$($pythonw -replace 'pythonw.exe$','python.exe')`" `"$InstallDir\lockwatch.py`" report"
Write-Host "Remove:   .\install-windows.ps1 -Uninstall"
Exit-Script 0
