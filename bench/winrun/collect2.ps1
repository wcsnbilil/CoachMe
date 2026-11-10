# Side-view top-up for hd_swings (Niko 2026-11-09 footage ask). Resumable; exits on first failure so the watcher can pause it.
$bench = "C:\Users\49907\coachme-bench"
$py = "$bench\venv\Scripts\python.exe"
$env:PYTHONIOENCODING = "utf-8"
foreach ($s in "search", "meta", "select", "download", "report") {
    Add-Content -Encoding utf8 "$bench\hd_collect.log" "== collect2 $s $(Get-Date -Format s)"
    & $py "$bench\winrun\hd_collect.py" $s 2>&1 | Out-File -Append -Encoding utf8 "$bench\hd_collect.log"
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
Set-Content "$bench\step_collect2.done" (Get-Date -Format s)
