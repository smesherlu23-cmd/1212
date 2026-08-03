<#
.SYNOPSIS
    Reproducible Windows build for Centurio, tuned to minimise antivirus
    heuristic false positives.

.DESCRIPTION
    A fresh, unsigned, no-history Flutter/Flet exe with a huge high-entropy
    overlay (the Flutter engine + Python runtime bundled after the PE's
    declared sections) is the single most common trigger for this class of
    app to get flagged by 1-5 heuristic/ML antivirus engines. None of that
    is fixable in the app's Python code - it's a property of how Flet
    packages a desktop build. This script controls what actually can be
    controlled:

      - Builds from a clean virtual environment with only the pinned
        dependencies in requirements.txt - no leftover dev/test packages,
        no stale caches bloating the bundle.
      - Passes full version/publisher metadata to the compiled exe (via
        pyproject.toml's [tool.flet] section) so it isn't an anonymous
        "no version info" binary - another heuristic signal.
      - Excludes tests, VCS metadata, and caches from the packaged app.
      - Code-signs the exe if SIGNING_PFX_PATH (and SIGNING_PFX_PASSWORD,
        if the PFX needs one) are set in the environment. This is the one
        step that actually stops the detections from recurring on every
        rebuild: an unsigned, always-new binary has zero reputation with
        SmartScreen and AV heuristics no matter how clean the build is
        otherwise. Without a certificate, skip this and expect occasional
        false positives on fresh builds until the binary accumulates
        install-base reputation on its own.
      - Prints a SHA-256 of the result, for filing false-positive reports
        with whichever vendor flags a given build.
      - Optionally compiles installer/centurio.iss with Inno Setup if
        ISCC.exe is available.

.NOTES
    Must run on Windows with the Visual Studio "Desktop development with
    C++" workload installed. Flutter's Windows target is compiled with
    MSVC and cannot be cross-built from Linux or macOS.

.EXAMPLE
    .\scripts\build_windows.ps1
    .\scripts\build_windows.ps1 -BuildVersion 1.1.0 -BuildNumber 2
    $env:SIGNING_PFX_PATH = "C:\certs\centurio.pfx"
    $env:SIGNING_PFX_PASSWORD = "..."
    .\scripts\build_windows.ps1
#>

[CmdletBinding()]
param(
    [string]$BuildVersion = "1.0.0",
    [int]$BuildNumber = 1,
    [switch]$SkipSign,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
Step "Checking prerequisites"

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python not found on PATH."
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Warning ("Visual Studio not detected via vswhere. The Windows build " +
                   "needs the 'Desktop development with C++' workload installed.")
}

# ---------------------------------------------------------------------------
Step "Creating a clean virtual environment (.build-venv)"

$venvDir = Join-Path $RepoRoot ".build-venv"
if (Test-Path $venvDir) { Remove-Item -Recurse -Force $venvDir }
python -m venv $venvDir

$venvPython = Join-Path $venvDir "Scripts\python.exe"
$venvFlet = Join-Path $venvDir "Scripts\flet.exe"

& $venvPython -m pip install --upgrade pip --quiet
& $venvPython -m pip install --quiet -r (Join-Path $RepoRoot "requirements.txt")
& $venvPython -m pip install --quiet flet-cli==0.28.3

# ---------------------------------------------------------------------------
Step "Clearing previous build output"

$buildDir = Join-Path $RepoRoot "build"
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }

# ---------------------------------------------------------------------------
Step "Building the Windows package (flet build windows)"

& $venvFlet build windows `
    --clear-cache `
    --build-version $BuildVersion `
    --build-number $BuildNumber `
    --exclude tests scripts installer .git .github .build-venv __pycache__

if ($LASTEXITCODE -ne 0) {
    throw "flet build windows failed (exit code $LASTEXITCODE) - see the log above."
}

$exePath = Join-Path $RepoRoot "build\windows\Centurio.exe"
if (-not (Test-Path $exePath)) {
    throw "Build finished but $exePath was not produced - check the flet build log above."
}

# ---------------------------------------------------------------------------
if (-not $SkipSign) {
    if ($env:SIGNING_PFX_PATH) {
        Step "Signing $exePath"
        $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Windows Kits\10\bin" `
            -Recurse -Filter "signtool.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*x64*" } |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $signtool) {
            throw "signtool.exe not found - install the Windows SDK, or pass -SkipSign."
        }
        $signArgs = @("sign", "/f", $env:SIGNING_PFX_PATH)
        if ($env:SIGNING_PFX_PASSWORD) { $signArgs += @("/p", $env:SIGNING_PFX_PASSWORD) }
        $signArgs += @("/tr", "http://timestamp.digicert.com", "/td", "sha256", "/fd", "sha256", $exePath)
        & $signtool @signArgs
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed (exit code $LASTEXITCODE)." }
        & $signtool verify /pa $exePath
    } else {
        Write-Warning ("SIGNING_PFX_PATH not set - shipping an UNSIGNED exe. This is the " +
                        "single biggest reason fresh builds get flagged by AV heuristics " +
                        "and Windows SmartScreen. Set SIGNING_PFX_PATH (and " +
                        "SIGNING_PFX_PASSWORD if the PFX needs one) to sign automatically, " +
                        "or pass -SkipSign to silence this warning.")
    }
}

# ---------------------------------------------------------------------------
Step "Computing checksum"

$hash = Get-FileHash $exePath -Algorithm SHA256
Write-Host "SHA-256: $($hash.Hash)"
Set-Content -Path "$exePath.sha256" -Value "$($hash.Hash)  Centurio.exe"

# ---------------------------------------------------------------------------
if (-not $SkipInstaller) {
    $isccCmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    $iscc = if ($isccCmd) { $isccCmd.Source } else { "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
    if (-not (Test-Path $iscc)) { $iscc = $null }
    if ($iscc) {
        Step "Compiling the installer (Inno Setup)"
        & $iscc (Join-Path $RepoRoot "installer\centurio.iss")
        if ($LASTEXITCODE -ne 0) { throw "ISCC.exe failed (exit code $LASTEXITCODE)." }
    } else {
        Write-Host "Inno Setup (ISCC.exe) not found - skipping installer compilation." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
Step "Done: $exePath"
