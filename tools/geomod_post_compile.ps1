# Launched by the "GeoMod - Full" Hammer++ preset after VRAD. Finds a working
# Python, then hands over to geomod_post_compile.py, which installs NumPy if
# it is missing.
param(
    [string]$BspPath,
    [string]$GameDir,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'

function Find-GeoModPython {
    $attempts = @()
    if ($env:PYTHON) { $attempts += ,@($env:PYTHON) }
    $attempts += ,@('python')
    $attempts += ,@('py', '-3')
    foreach ($attempt in $attempts) {
        $command = Get-Command $attempt[0] -CommandType Application -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        $extra = @($attempt | Select-Object -Skip 1)
        # The Microsoft Store placeholder exists on PATH but cannot run code.
        $path = & $command.Source @extra -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $path) { return @{ Path = ($path | Select-Object -Last 1).Trim() } }
    }
    return $null
}

$python = Find-GeoModPython
if (-not $python) {
    throw 'GeoMod needs Python 3 to repair map lighting. Install Python 3.12 or 3.13 from https://www.python.org/downloads/ (tick "Add python.exe to PATH"), or set the PYTHON environment variable to a python.exe, then compile again.'
}
$arguments = @((Join-Path $PSScriptRoot 'geomod_post_compile.py'))
if ($Check) { $arguments += '--check' } else {
    if (-not $BspPath) { throw 'Pass -BspPath, or -Check to test the installation.' }
    $arguments += $BspPath
}
if ($GameDir) { $arguments += @('--game-dir', $GameDir) }
& $python.Path @arguments
if ($LASTEXITCODE -ne 0) { throw 'GeoMod post-compile step failed; see the messages above.' }
