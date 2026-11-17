# Set up the Python algorithm tools (tools/faults, tools/benchmark) on Windows.
# Usage, from the repo root in PowerShell:
#   powershell -ExecutionPolicy Bypass -File tools\setup-windows.ps1 [-Venv ..\venv]
# Needs Python 3.10-3.12 on PATH (py launcher or python.exe). The iOS app itself
# still needs a Mac; this only covers the pose -> phases -> path-fault pipeline.
param([string]$Venv = ".venv")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not (Test-Path "$Venv\Scripts\python.exe")) {
    if (Get-Command py -ErrorAction SilentlyContinue) { py -3 -m venv $Venv } else { python -m venv $Venv }
}
$py = Resolve-Path "$Venv\Scripts\python.exe"
& $py -m pip install --quiet --upgrade pip
& $py -m pip install --quiet mediapipe opencv-python-headless numpy pandas coremltools

$model = "CoachMe\Resources\pose_landmarker_heavy.task"
if (-not (Test-Path $model)) {
    Write-Host "Downloading $model ..."
    Invoke-WebRequest -Uri "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task" -OutFile $model
}

$env:PYTHONIOENCODING = "utf-8"
& $py tools\faults\test_path_fault.py
& $py tools\benchmark\test_app_selector.py
Write-Host "`nReady. Example:`n  $py tools\faults\run_path.py --video my_swing.mp4 --out report_me"
