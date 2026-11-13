param(
  [Parameter(Mandatory = $true)][string]$EngineExe
)

$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $EngineExe).Path
$testDir = Join-Path ([IO.Path]::GetTempPath()) ("alko-startup-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testDir | Out-Null
$proc = $null
$listener = $null
$psi = [Diagnostics.ProcessStartInfo]::new($exe)
$psi.WorkingDirectory = Split-Path $exe
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
$psi.EnvironmentVariables['ALKO_BRIDGE_DIR'] = $testDir
try {
  $proc = [Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEndAsync()
  $heartbeat = Join-Path $testDir 'telemetry\heartbeat.json'
  $deadline = [DateTime]::UtcNow.AddSeconds(20)
  do {
    if ($proc.WaitForExit(250)) {
      throw ('Proxy.exe exited during startup (0x{0:X8})' -f $proc.ExitCode)
    }
    $listener = Get-NetTCPConnection -LocalPort 443 -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue
    if ($listener -and (Test-Path -LiteralPath $heartbeat)) { break }
  } while ([DateTime]::UtcNow -lt $deadline)

  if (!$listener -or !(Test-Path -LiteralPath $heartbeat)) {
    throw 'GTProxy did not open HTTPS port 443 and produce an ALKO bridge heartbeat.'
  }
  $state = Get-Content -LiteralPath $heartbeat -Raw | ConvertFrom-Json
  if ($state.bridge -ne 'online' -or $state.engine -ne 'GTProxy') {
    throw 'Unexpected ALKO bridge heartbeat.'
  }
  Write-Host 'GTProxy opened HTTPS port 443 and produced an ALKO bridge heartbeat with the Windows-only PATH.'
} finally {
  if ($proc) {
    if (!$proc.HasExited) { $proc.Kill() }
    $proc.WaitForExit()
    Write-Host $stdout.GetAwaiter().GetResult()
    Write-Host $stderr.GetAwaiter().GetResult()
    $proc.Dispose()
  }
  $heartbeatDir = Join-Path $testDir 'telemetry'
  foreach ($file in @('heartbeat.json', 'heartbeat.json.tmp')) {
    $path = Join-Path $heartbeatDir $file
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
  }
  foreach ($dir in @($heartbeatDir, (Join-Path $testDir 'outbox'), (Join-Path $testDir 'inbox'), $testDir)) {
    if (Test-Path -LiteralPath $dir) { [IO.Directory]::Delete($dir) }
  }
}
