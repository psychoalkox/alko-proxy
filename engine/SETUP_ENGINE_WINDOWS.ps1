<#
ALKO Proxy optional native C++ engine builder. Run on Windows 10/11 x64
with VS 2022 C++ Desktop Build Tools, Git, CMake and Python 3.12 available.

From the extracted ALKO folder:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\SETUP_ENGINE_WINDOWS.ps1

The dashboard ALKOProxy.exe remains a separate executable. This builder has
NOT been live-tested against Growtopia 5.61. It never modifies system hosts.
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $root 'vendor\GTProxy'
$build = Join-Path $source 'build'
$out = Join-Path $root 'ALKO-native-engine'

function Run-Native {
  param([string]$Purpose, [string]$Executable, [string[]]$Arguments)
  Write-Host "==> $Purpose" -ForegroundColor Cyan
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Purpose failed (exit $LASTEXITCODE)" }
}

Write-Host 'ALKO engine source build (v5.61 connection NOT verified)' -ForegroundColor Yellow
foreach ($exe in @('git', 'cmake', 'python')) {
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
    throw "Missing $exe. Install Git, CMake and Python 3.12 first."
  }
}

Run-Native -Purpose 'Install Conan 2' -Executable 'python' -Arguments @('-m','pip','install','conan>=2,<3')
if (-not (Get-Command conan -ErrorAction SilentlyContinue)) {
  # pip can install the Conan entry point into a Scripts folder not yet on PATH.
  $pythonScripts = (& python -c 'import sysconfig; print(sysconfig.get_path("scripts"))').Trim()
  if ($pythonScripts -and (Test-Path $pythonScripts)) {
    $env:PATH = "$pythonScripts;$env:PATH"
  }
}
if (-not (Get-Command conan -ErrorAction SilentlyContinue)) {
  throw 'Conan installed but its executable was not found. Open a new PowerShell and retry.'
}
Run-Native -Purpose 'Detect MSVC profile' -Executable 'conan' -Arguments @('profile', 'detect', '--force')

if (-not (Test-Path (Join-Path $source '.git'))) {
  New-Item -ItemType Directory -Path (Join-Path $root 'vendor') -Force | Out-Null
  Run-Native -Purpose 'Fetch upstream GTProxy source and submodules' -Executable 'git' -Arguments @('clone', '--depth','1','--recurse-submodules','https://github.com/vinskeeper/GTProxy.git',$source)
}
Run-Native -Purpose 'Patch GTProxy with ALKO bridge' -Executable 'python' -Arguments @((Join-Path $root 'engine\patch_engine.py'), $source)

# Dot-source to keep ALKO_LUA_ARCHIVE set for subsequent cmake/conan runs.
. (Join-Path $PSScriptRoot 'PREPARE_LUA_WINDOWS.ps1') -ProjectRoot $root

Run-Native -Purpose 'Configure GTProxy with MSVC' -Executable 'cmake' -Arguments @(
  '-S', $source, '-B', $build, '-G', 'Visual Studio 17 2022', '-A', 'x64',
  '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CONFIGURATION_TYPES=Release', '-DBUILD_TESTING=OFF'
)
Run-Native -Purpose 'Compile native GTProxy engine' -Executable 'cmake' -Arguments @('--build',$build,'--config','Release','--parallel','2')

# Bundle dependent non-system DLLs as well as Proxy.exe.
& (Join-Path $PSScriptRoot 'PACKAGE_ENGINE_WINDOWS.ps1') -ProjectRoot $root
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Native engine packaging failed' }

Write-Host "Compiled engine: $(Join-Path $out 'Proxy.exe')" -ForegroundColor Green
Write-Host 'Dashboard: run ALKOProxy.exe. Set the Engine path to this Proxy.exe.'
Write-Host 'Compiled does not imply Growtopia 5.61 works or that a game account is ban-safe.' -ForegroundColor Yellow
