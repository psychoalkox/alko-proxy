<#
Prepares verified Lua 5.4.6 source and a locally patched ConanCenter recipe.
Compatible with PowerShell 5.1 / PowerShell 7 on Windows.
Used by both local SETUP_ENGINE_WINDOWS.ps1 and GitHub Actions.
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$cii = Join-Path $ProjectRoot 'vendor\conan-center-index'
$recipe = Join-Path $cii 'recipes\lua\all'
$hash = '7d5ea1b9cb6aa0b59ca3dde1c6adcb57ef83a1ba8e5432c0ecd06bf439b3ad88'

function Run-Native {
  param([string]$Purpose, [string]$Executable, [string[]]$Arguments)
  Write-Host "==> $Purpose" -ForegroundColor Cyan
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Purpose failed (exit $LASTEXITCODE)" }
}

Run-Native -Purpose 'Download SHA256-verified Lua 5.4.6 archive' -Executable 'python' -Arguments @((Join-Path $ProjectRoot 'engine\prime_conan_lua.py'))

$cacheBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } elseif ($env:TEMP) { $env:TEMP } else { $ProjectRoot }
$archive = Join-Path (Join-Path $cacheBase 'alko-conan-source-cache') $hash
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Lua archive missing after prefetch: $archive" }
$actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $hash) { throw "Lua SHA256 mismatch: $actualHash" }

if (-not (Test-Path (Join-Path $cii '.git'))) {
  $vendor = Join-Path $ProjectRoot 'vendor'
  New-Item -ItemType Directory -Path $vendor -Force | Out-Null
  Run-Native -Purpose 'Clone ConanCenter Lua recipe' -Executable 'git' -Arguments @('clone', '--depth', '1', '--filter=blob:none', '--sparse', 'https://github.com/conan-io/conan-center-index.git', $cii)
}
Run-Native -Purpose 'Check out ConanCenter Lua recipe' -Executable 'git' -Arguments @('-C', $cii, 'sparse-checkout', 'set', 'recipes/lua/all')
Run-Native -Purpose 'Patch Lua recipe for correct .tar.gz extraction' -Executable 'python' -Arguments @((Join-Path $ProjectRoot 'engine\patch_lua_conan_recipe.py'), $recipe)

# Persist this path for later Conan invocations. GitHub Actions executes each
# step in a new process; without GITHUB_ENV, CMake can lose this variable.
$env:ALKO_LUA_ARCHIVE = (Resolve-Path -LiteralPath $archive).Path
if ($env:GITHUB_ENV) {
  Add-Content -LiteralPath $env:GITHUB_ENV -Value "ALKO_LUA_ARCHIVE=$env:ALKO_LUA_ARCHIVE" -Encoding UTF8
  Write-Host 'Saved ALKO_LUA_ARCHIVE to GITHUB_ENV for subsequent Actions steps'
}
Write-Host "ALKO Lua verified archive: $env:ALKO_LUA_ARCHIVE" -ForegroundColor Green

# Pre-build both configurations because the Conan/CMake MSVC provider can
# request Debug even when the user eventually builds Release.
foreach ($configuration in @('Release', 'Debug')) {
  Run-Native -Purpose "Build Lua 5.4.6 ($configuration) in Conan" -Executable 'conan' -Arguments @('create', $recipe, '--version=5.4.6', '-s', "build_type=$configuration", '--build=missing')
}
Write-Host 'Lua prebuild complete using a verified local archive, without relying on the Conan Lua source URL.' -ForegroundColor Green
