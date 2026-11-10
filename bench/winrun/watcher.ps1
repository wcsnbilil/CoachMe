# CoachMe watcher: every 5 s. Valorant running or coachme-bench\PAUSE present -> stop the jobs.
# Otherwise, if nothing is running and there is no jobs.done / jobs.failed -> start winrun\jobs.ps1 hidden.
$bench = "C:\Users\k8881\coachme-bench"
$created = $false
$mutex = New-Object Threading.Mutex($true, "Global\CoachMeWatcher", [ref]$created)
if (-not $created) { exit 0 }
function Log($m) { Add-Content -Encoding utf8 "$bench\watcher.log" "$(Get-Date -Format s) $m" }
function JobProcs {
    Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='powershell.exe' OR Name='yt-dlp.exe' OR Name='ffmpeg.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like "*coachme-bench*" -and $_.CommandLine -notlike "*watcher.ps1*" }
}
function StopJobs {
    $p = @(JobProcs)
    # jobs.ps1 first, so a killed python is not recorded as a failed step
    $p | Where-Object { $_.Name -eq 'powershell.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $p | Where-Object { $_.Name -ne 'powershell.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    return $p.Count
}
Log "watcher start pid $PID"
$state = ""
while ($true) {
    try {
        $game = @(Get-Process -Name "VALORANT", "VALORANT-Win64-Shipping" -ErrorAction SilentlyContinue).Count -gt 0
        $pause = Test-Path "$bench\PAUSE"
        if ($game -or $pause) {
            $n = StopJobs
            $s = "paused (" + $(if ($game) { "valorant" } else { "PAUSE file" }) + ")"
            if ($s -ne $state -or $n) { Log "$s, stopped $n processes"; $state = $s }
        } elseif ((Test-Path "$bench\jobs.done") -or (Test-Path "$bench\jobs.failed")) {
            $s = "idle (" + $(if (Test-Path "$bench\jobs.done") { "jobs.done" } else { "jobs.failed" }) + ")"
            if ($s -ne $state) { Log $s; $state = $s }
        } elseif (@(JobProcs).Count -eq 0) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$bench\winrun\jobs.ps1`""
            Log "started jobs.ps1"; $state = "running"
            Start-Sleep -Seconds 10
        } else { $state = "running" }
    } catch { Log "error $_" }
    Start-Sleep -Seconds 5
}
