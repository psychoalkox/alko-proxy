<#
  Package ALKO native engine and scan Windows DLL imports.
  Requires a successful Release build. With an MSVC developer environment,
  dumpbin /DEPENDENTS is used to resolve runtime DLLs from the build tree
  and Conan's package cache. This avoids shipping only Proxy.exe.
  VC++ runtime is installed separately via Microsoft's supported redistributable.
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$BuiltExe = ''
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $ProjectRoot 'vendor\GTProxy'
$build = Join-Path $source 'build'
$out = Join-Path $ProjectRoot 'ALKO-native-engine'
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

# Candidate non-system DLLs: actual Release build files and Conan package bin directories.
# Do NOT copy arbitrary Windows or MSVC system DLLs; use the supported VC++ redist.
$candidates = @{}
$roots = @($build)
$conanRoot = Join-Path $env:USERPROFILE '.conan2\p'
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
$report.Add('VC++ runtime: install https://aka.ms/vc14/vc_redist.x64.exe on the target PC')
$report.Add('')

function Import-Dlls([string]$binary) {
  $lines = & dumpbin.exe /DEPENDENTS $binary 2>&1
  if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $binary : $lines" }
  $imports = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if ([string]$line -match '^\s*([a-zA-Z0-9_.+\-]+\.dll)\s*$') {
      $imports.Add($Matches[1])
    }
  }
  return @($imports | Sort-Object -Unique)
}

$dumpbin = Get-Command 'dumpbin.exe' -ErrorAction SilentlyContinue
if (-not $dumpbin) {
  $report.Add('WARNING: dumpbin.exe unavailable; scanning only local build DLLs.')
  foreach ($dll in @(Get-ChildItem -LiteralPath (Split-Path $BuiltExe) -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
    Copy-Item -LiteralPath $dll.FullName -Destination (Join-Path $out $dll.Name) -Force
    $report.Add("COPIED $($dll.Name) from $($dll.FullName)")
  }
} else {
  $visited = @{}
  $queued = [System.Collections.Generic.Queue[string]]::new()
  $queued.Enqueue((Join-Path $out 'Proxy.exe'))
  $missing = [System.Collections.Generic.List[string]]::new()
  $runtimePrefixes = @('msvcp', 'vcruntime', 'concrt', 'vcomp', 'ucrtbase')
  while ($queued.Count -gt 0) {
    $binary = $queued.Dequeue()
    $key = $binary.ToLowerInvariant()
    if ($visited.ContainsKey($key)) { continue }
    $visited[$key] = $true
    $report.Add("INSPECT $binary")
    foreach ($dllName in @(Import-Dlls $binary)) {
      $name = $dllName.ToLowerInvariant()
      $local = Join-Path $out $dllName
      if (Test-Path -LiteralPath $local) {
        $queued.Enqueue($local)
        continue
      }
      if ($name.StartsWith('api-ms-win-') -or $name.StartsWith('ext-ms-win-')) {
        $report.Add("WINDOWS API SET $dllName")
        continue
      }
      $systemPath = Join-Path $env:SystemRoot ('System32\' + $dllName)
      if (Test-Path -LiteralPath $systemPath) {
        $report.Add("WINDOWS SYSTEM/INSTALLED $dllName")
        continue
      }
      if (($runtimePrefixes | Where-Object { $name.StartsWith($_) }).Count -gt 0) {
        $report.Add("MICROSOFT VC RUNTIME $dllName (install vc_redist.x64.exe)")
        continue
      }
      $foundDlls = if ($candidates.ContainsKey($name)) { @($candidates[$name]) } else { @() }
      if ($foundDlls.Count -gt 0) {
        # Prefer DLLs next to built Proxy.exe, then Release, then Conan package bin.
        $preferred = $foundDlls | Sort-Object @{ Expression={ if ((Split-Path $_) -eq (Split-Path $BuiltExe)) { 0 } elseif ($_ -match '[\\/]Release[\\/]') { 1 } elseif ($_ -match '[\\/]p[\\/]bin[\\/]') { 2 } else { 3 } } }, @{ Expression={ $_ } } | Select-Object -First 1
        Copy-Item -LiteralPath $preferred -Destination $local -Force
        $queued.Enqueue($local)
        $report.Add("BUNDLED $dllName from $preferred")
      } else {
        $missing.Add($dllName)
        $report.Add("UNRESOLVED $dllName")
      }
    }
  }
  if ($missing.Count -gt 0) {
    $report.Add('')
    $report.Add('Unresolved non-system DLLs: ' + (($missing | Sort-Object -Unique) -join ', '))
  }
}
$report.Add('')
$report.Add('This check cannot prove Growtopia v5.61 connectivity or ban safety.')
$reportFile = Join-Path $out 'ENGINE_DLL_REPORT.txt'
$report | Set-Content -LiteralPath $reportFile -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
Write-Host "Portable engine packaged in: $out" -ForegroundColor Green
