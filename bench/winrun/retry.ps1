# CoachMe retry guard (computer B). Independent of watcher.ps1 / jobs.ps1, which it never edits.
# Every 60 s: if jobs.failed exists and the failed step is split / bench_* / club4_sample and that step has been
# retried fewer than 5 times, wait until the commit charge is under 92 % of the limit (30 min at most), back up
# split_p*.err, and rename jobs.failed to jobs.failed.<timestamp>. watcher.ps1 then restarts jobs.ps1 and every
# script resumes from its cached outputs.
# Lives outside the bench folder and builds the bench path from parts, so its command line never contains the
# bench folder name and the watcher's pause logic does not kill it.
param([string]$Bench = "", [switch]$Once, [int]$MaxWaitMin = 30, [int]$PollSec = 60)
if (-not $Bench) { $Bench = Join-Path $env:USERPROFILE ("coachme-" + "bench") }
$MaxRetries = 5
$CommitMax = 0.92
if (-not $Once) {
    $created = $false
    $mutex = New-Object Threading.Mutex($true, "Global\CoachMeRetry", [ref]$created)
    if (-not $created) { exit 0 }
}
function Log($m) { Add-Content -Encoding utf8 (Join-Path $Bench "retry.log") "$(Get-Date -Format s) $m" }
function CommitFrac {
    $os = Get-CimInstance Win32_OperatingSystem
    return 1.0 - ($os.FreeVirtualMemory / $os.TotalVirtualMemorySize)
}
function Counts {
    $p = Join-Path $Bench "retry_count.json"
    $h = @{}
    if (Test-Path $p) {
        try { (Get-Content $p -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = [int]$_.Value } } catch {}
    }
    return $h
}
function Check {
    $f = Join-Path $Bench "jobs.failed"
    if (-not (Test-Path $f)) { return "none" }
    $step = ((Get-Content $f -TotalCount 1) -split '\s+')[0]
    if ($step -notmatch '^(split|bench_\w+|club4_sample)$') {
        if ($script:lastSkip -ne $step) { Log "jobs.failed for step '$step': not a retryable step, leaving it"; $script:lastSkip = $step }
        return "skip"
    }
    $c = Counts
    $n = 0; if ($c.ContainsKey($step)) { $n = $c[$step] }
    if ($n -ge $MaxRetries) {
        if ($script:lastSkip -ne "max $step") { Log "step '$step' already retried $n times, giving up"; $script:lastSkip = "max $step" }
        return "max"
    }
    $deadline = (Get-Date).AddMinutes($MaxWaitMin)
    $frac = CommitFrac
    while ($frac -ge $CommitMax -and (Get-Date) -lt $deadline) {
        Log ("commit {0:P0} >= {1:P0}, waiting before retrying '{2}'" -f $frac, $CommitMax, $step)
        Start-Sleep -Seconds 60
        $frac = CommitFrac
    }
    if (-not (Test-Path $f)) { return "none" }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    Get-ChildItem $Bench -Filter "split_p*.err" -File | Where-Object { $_.Name -match '^split_p\d\.err$' } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $Bench ($_.BaseName + ".$ts.err"))
    }
    $c[$step] = $n + 1
    ($c | ConvertTo-Json) | Set-Content -Encoding utf8 (Join-Path $Bench "retry_count.json")
    Rename-Item $f "jobs.failed.$ts"
    Log ("retry {0}/{1} of '{2}' (commit {3:P0}): jobs.failed -> jobs.failed.{4}" -f ($n + 1), $MaxRetries, $step, $frac, $ts)
    return "retried"
}
if ($Once) { Check; exit 0 }
Log "retry guard start pid $PID"
while ($true) {
    try { [void](Check) } catch { Log "error $_" }
    Start-Sleep -Seconds $PollSec
}
