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
$psi.EnvironmentVariables['ALKO_TLS_DIR'] = $testDir
$session = [guid]::NewGuid().ToString('N')
$jobId = [guid]::NewGuid().ToString('N')
$psi.EnvironmentVariables['ALKO_BRIDGE_SESSION'] = $session
try {
  & (Join-Path $PSScriptRoot 'NEW_ENGINE_TLS_WINDOWS.ps1') -Directory $testDir
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
  if ($state.bridge -ne 'online' -or $state.engine -ne 'GTProxy' -or
      $state.session -ne $session -or $state.connection -ne 'disconnected' -or $state.bootstrap -ne 'waiting') {
    throw 'Unexpected ALKO bridge heartbeat before the game connects.'
  }
  $udp = Get-NetUDPEndpoint -LocalAddress 127.0.0.1 -LocalPort 16999 -OwningProcess $proc.Id
  if (!$udp -or $listener.LocalAddress -ne '127.0.0.1') {
    throw 'Expected local-only HTTPS and ENet listeners.'
  }

  $verify = @'
import http.client
import ssl
import sys
context = ssl.create_default_context(cafile=sys.argv[1])
conn = http.client.HTTPSConnection("127.0.0.1", context=context, timeout=5)
conn.request("GET", "/healthz")
response = conn.getresponse()
assert response.status == 200 and response.read() == b"ok", response.status
conn.close()
'@
  $verify | python - (Join-Path $testDir 'cert.pem')
  if ($LASTEXITCODE -ne 0) { throw 'Verified HTTPS health request failed.' }

  $job = Join-Path $testDir "inbox/$session/$jobId.cmd"
  $receipt = Join-Path $testDir "outbox/$jobId.json"
  [IO.File]::WriteAllText($job, '/proxy')
  $deadline = [DateTime]::UtcNow.AddSeconds(5)
  while (!(Test-Path -LiteralPath $receipt) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
  }
  if (!(Test-Path -LiteralPath $receipt)) { throw 'Disconnected job did not receive a receipt.' }
  $result = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
  while ((Test-Path -LiteralPath $job) -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
  }
  if ($result.ok -ne $false -or $result.message -notmatch 'relay disconnected' -or (Test-Path -LiteralPath $job)) {
    throw 'Bridge did not discard the job while disconnected.'
  }
  Write-Host 'Verified local HTTPS, local ENet listener, disconnected heartbeat and disconnected queue rejection.'
} finally {
  if ($proc) {
    if (!$proc.HasExited) { $proc.Kill() }
    $proc.WaitForExit()
    Write-Host $stdout.GetAwaiter().GetResult()
    Write-Host $stderr.GetAwaiter().GetResult()
    $proc.Dispose()
  }
  $heartbeatDir = Join-Path $testDir 'telemetry'
  $outbox = Join-Path $testDir 'outbox'
  foreach ($file in @('cert.pem', 'key.pem', 'telemetry/heartbeat.json', 'telemetry/heartbeat.json.tmp',
                      "outbox/$jobId.json", "outbox/$jobId.json.tmp", "inbox/$session/$jobId.cmd")) {
    $filePath = Join-Path $testDir $file
    if (Test-Path -LiteralPath $filePath -PathType Leaf) { Remove-Item -LiteralPath $filePath }
  }
  foreach ($dir in @($heartbeatDir, $outbox, (Join-Path $testDir "inbox/$session"), (Join-Path $testDir 'inbox'), $testDir)) {
    if (Test-Path -LiteralPath $dir) { [IO.Directory]::Delete($dir) }
  }
}
