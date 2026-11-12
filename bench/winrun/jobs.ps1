# CoachMe long-running jobs on computer B. Resumable: each step leaves step_<name>.done; every script skips finished outputs.
# Started (hidden) by watcher.ps1. Ends with jobs.done, or jobs.failed on the first failing step.
$bench = "C:\Users\k8881\coachme-bench"
$py = "$bench\venv\Scripts\python.exe"
$w = "$bench\winrun"
$env:PYTHONUTF8 = "1"; $env:PYTHONIOENCODING = "utf-8"
$log = "$bench\jobs.log"
function Log($m) { Add-Content -Encoding utf8 $log "$(Get-Date -Format s) $m" }
function Step($name, [scriptblock]$body) {
    if (Test-Path "$bench\step_$name.done") { return }
    Log "== start $name"
    $ok = & $body
    if ($ok -ne $true) { Log "== FAILED $name"; Set-Content "$bench\jobs.failed" "$name $(Get-Date -Format s)"; exit 1 }
    Set-Content "$bench\step_$name.done" (Get-Date -Format s); Log "== done $name"
}
function Py([string[]]$a, $logfile) {
    & $py @a 2>&1 | Out-File -Append -Encoding utf8 "$bench\$logfile"
    return ($LASTEXITCODE -eq 0)
}

# 1. footage: search -> meta (+select) -> select -> download
foreach ($s in "search", "meta", "select", "download") {
    Step "collect_$s" { Py @("$w\hd_collect.py", $s) "hd_collect.log" }
}
Step "collect_report" { Py @("$w\hd_collect.py", "report") "hd_collect.log" }

# 2. pose + single-swing split (swing_split at real fps), 4 parallel workers
Step "split" {
    if (-not (Py @("$w\seg_lists.py") "split.log")) { return $false }
    $ps = 0..3 | ForEach-Object {
        Start-Process -FilePath $py -ArgumentList "`"$w\hd_split.py`" `"$bench\hd_swings\seg_list$_.txt`" --out `"$bench\hd_swings\seg_p$_`"" `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput "$bench\split_p$_.log" -RedirectStandardError "$bench\split_p$_.err"
    }
    $ps | Wait-Process
    return (@($ps | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0)
}

# 3. skeleton model comparison (~300 frames)
Step "bench_select" { Py @("$w\bench_select.py") "bench.log" }
Step "bench_models" { Py @("$w\bench_models.py") "bench.log" }
Step "bench_report" { Py @("$w\bench_report.py") "bench.log" }

# 4. club 4-point pseudo labels: small sample first (overlays are checked by hand before the full run is queued)
Step "club4_sample" {
    Py @("$w\club4.py", "$bench\hd_swings\seg_p0", "$bench\hd_swings\seg_p1", "--out", "$bench\club4_sample", "--limit", "12") "club4.log"
}

# 5. club 4-point pseudo labels, all swings, gated (club4b.py plan B): down-the-line clips first, then the rest.
#    Resumable per swing (<name>.club4.json); progress in progress\club4b.json.
Step "club4b_all" {
    Py @("$w\club4b.py", "$bench\hd_swings\seg_p0", "$bench\hd_swings\seg_p1", "$bench\hd_swings\seg_p2", "$bench\hd_swings\seg_p3",
         "--out", "$bench\club4b_all", "--keep", "$bench\hd_swings\keep.jsonl", "--progress", "$bench\progress\club4b.json") "club4b.log"
}

# 6. re-split + re-analyze from the cached keypoints (no MediaPipe): new swing_split, lead-in frames before the
#    address (hd_split.py as hd_pipeline.py at claude/camera-res a12272f). New folders seg2_p*; seg_p* is kept.
$code = "$bench\camres_wt"   # worktree at claude/camera-res a12272f: tools\split, tools\faults
Step "resplit_analyze" {
    $ps = 0..3 | ForEach-Object {
        Start-Process -FilePath $py -ArgumentList "`"$w\hd_split.py`" `"$bench\hd_swings\seg_list$_.txt`" --out `"$bench\hd_swings\seg2_p$_`" --code `"$code`" --landmarks `"$bench\hd_swings\seg_p$_\landmarks`"" `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput "$bench\resplit_p$_.log" -RedirectStandardError "$bench\resplit_p$_.err"
    }
    $ps | Wait-Process
    return (@($ps | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0)
}

# 7. club 4-point labels again on the re-split swings.
Step "club4b_all2" {
    Py @("$w\club4b.py", "$bench\hd_swings\seg2_p0", "$bench\hd_swings\seg2_p1", "$bench\hd_swings\seg2_p2", "$bench\hd_swings\seg2_p3",
         "--out", "$bench\club4b_all2", "--keep", "$bench\hd_swings\keep.jsonl", "--progress", "$bench\progress\club4b2.json") "club4b2.log"
}

Set-Content "$bench\jobs.done" (Get-Date -Format s); Log "== all done"
