<#
  Package ALKO native engine and scan Windows DLL imports.
  Run in an x64 Visual Studio developer shell after building Release.
  Resolve OpenSSL from the SDK selected by CMake and the VC++ runtime from
  the toolchain's redistributable directory.
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BuiltExe = ''
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $ProjectRoot 'vendor\GTProxy'
$build = Join-Path $source 'build'
$out = Join-Path $ProjectRoot 'ALKO-native-engine'
$dumpbin = (Get-Command 'dumpbin.exe' -ErrorAction Stop).Source
if (-not $BuiltExe) {
  $proxies = @(Get-ChildItem -LiteralPath $build -Recurse -Filter 'Proxy.exe' -File -ErrorAction Stop)
  $release = @($proxies | Where-Object { $_.FullName -match '[\\/]Release[\\/]' })
  if ($release.Count -gt 0) { $BuiltExe = $release[0].FullName }
  elseif ($proxies.Count -gt 0) { $BuiltExe = $proxies[0].FullName }
  else { throw 'Proxy.exe not found. The C++ build must finish first.' }
}
$BuiltExe = (Resolve-Path -LiteralPath $BuiltExe).Path
New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $out 'Proxy.exe') -Force
foreach ($dirname in @('scripts', 'resources')) {
  $origin = Join-Path $source $dirname
  if (Test-Path -LiteralPath $origin) { Copy-Item -LiteralPath $origin -Destination (Join-Path $out $dirname) -Recurse -Force }
}
New-Item -ItemType Directory -Path (Join-Path $out 'scripts') -Force | Out-Null
Copy-Item (Join-Path $ProjectRoot 'engine\alko_features.lua') (Join-Path $out 'scripts\alko_features.lua') -Force
$config = Join-Path $source 'config.json'
if (Test-Path -LiteralPath $config) { Copy-Item -LiteralPath $config -Destination (Join-Path $out 'config.json') -Force }
$commitFile = Join-Path $ProjectRoot 'upstream-commit.txt'
if (Test-Path -LiteralPath $commitFile) { Copy-Item -LiteralPath $commitFile -Destination (Join-Path $out 'upstream-commit.txt') -Force }

# Find the SDK used at configure time, even when it isn't in the Conan cache.
$cache = Join-Path $build 'CMakeCache.txt'
$opensslRoot = $null
if (Test-Path -LiteralPath $cache) {
  $opensslInclude = Select-String -LiteralPath $cache -Pattern '^OPENSSL_INCLUDE_DIR:PATH=(.+)$'
  if ($opensslInclude) {
    $opensslRoot = Split-Path $opensslInclude.Matches[0].Groups[1].Value
    Write-Host "OpenSSL SDK selected by CMake: $opensslRoot"
  }
}
$crtDirs = @()
if ($env:VCToolsRedistDir) {
  $crtDirs = @(Get-ChildItem -LiteralPath (Join-Path $env:VCToolsRedistDir 'x64') -Directory -Filter 'Microsoft.VC*.CRT')
}

# Candidate DLLs for dependencies supplied by the build or Conan.
$candidates = @{}
$roots = @()
$conanHome = if ($env:CONAN_HOME) { $env:CONAN_HOME } else { Join-Path $env:USERPROFILE '.conan2' }
$conanRoot = Join-Path $conanHome 'p'
if (Test-Path -LiteralPath $conanRoot) { $roots += $conanRoot }
foreach ($rootPath in $roots) {
  foreach ($dll in @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue)) {
    $name = $dll.Name.ToLowerInvariant()
    if (-not $candidates.ContainsKey($name)) { $candidates[$name] = @() }
    $candidates[$name] += $dll.FullName
  }
}
$report = [System.Collections.Generic.List[string]]::new()
$report.Add("Native ALKO engine runtime dependency report (Windows x64)")
$report.Add("Built executable: $BuiltExe")
$report.Add("Run-time target: $(Join-Path $out 'Proxy.exe')")
$report.Add('')

function Import-Dlls([string]$binary) {
  $lines = & $dumpbin /DEPENDENTS $binary 2>&1
  if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $binary : $lines" }
  $imports = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if ([string]$line -match '^\s*([a-zA-Z0-9_.+\-]+\.dll)\s*$') {
      $imports.Add($Matches[1])
    }
  }
  return @($imports | Sort-Object -Unique)
}

$queued = [System.Collections.Generic.Queue[string]]::new()
$queued.Enqueue((Join-Path $out 'Proxy.exe'))
$checked = @{}
$missing = [System.Collections.Generic.List[string]]::new()
$hasOpenSSL = $false
while ($queued.Count -gt 0) {
  $binary = $queued.Dequeue()
  $report.Add("INSPECT $(Split-Path -Leaf $binary)")
  foreach ($dllName in @(Import-Dlls $binary)) {
    if ($checked.ContainsKey($dllName)) { continue }
    $checked[$dllName] = $true
    $preferred = $null
    $buildLocal = Join-Path (Split-Path $BuiltExe) $dllName
    if ($dllName -match '^(api|ext)-ms-win-') {
      $report.Add("WINDOWS API SET $dllName")
      continue
    }
    if ($dllName -match '^lib(ssl|crypto)-') {
      $hasOpenSSL = $true
      if ($opensslRoot) { $preferred = Join-Path $opensslRoot "bin\$dllName" }
    } elseif ($dllName -match '^(msvcp|vcruntime|concrt|vcomp)\d') {
      $preferred = $crtDirs | ForEach-Object { Join-Path $_.FullName $dllName } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    } elseif (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$dllName") -PathType Leaf) {
      $report.Add("WINDOWS SYSTEM $dllName")
      continue
    } elseif (Test-Path -LiteralPath $buildLocal -PathType Leaf) {
      $preferred = $buildLocal
    } elseif ($candidates[$dllName].Count -eq 1) {
      $preferred = $candidates[$dllName][0]
    }
    if ($preferred -and (Test-Path -LiteralPath $preferred -PathType Leaf)) {
      $local = Join-Path $out $dllName
      Copy-Item -LiteralPath $preferred -Destination $local -Force
      $queued.Enqueue($local)
      $report.Add("BUNDLED $dllName from $preferred")
    } else {
      $missing.Add($dllName)
      $report.Add("UNRESOLVED $dllName (missing or ambiguous runtime source)")
    }
  }
}
$reportFile = Join-Path $out 'ENGINE_DLL_REPORT.txt'
$report | Set-Content -LiteralPath $reportFile -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
if ($missing.Count -gt 0) {
  throw "Unresolved runtime DLLs: $($missing -join ', ')"
}
if ($hasOpenSSL) {
  $license = Join-Path $opensslRoot 'LICENSE.txt'
  Copy-Item -LiteralPath $license -Destination (Join-Path $out 'LICENSE-OpenSSL.txt') -Force
}
Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $out 'LICENSE-GTProxy.txt') -Force
Write-Host "Portable engine packaged in: $out" -ForegroundColor Green
