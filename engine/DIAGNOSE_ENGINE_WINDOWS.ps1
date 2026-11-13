<#
  ALKO Proxy native startup diagnostic, no game connection attempted.
  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\engine\DIAGNOSE_ENGINE_WINDOWS.ps1 -EngineExe 'C:\...\Proxy.exe'
#>
param([Parameter(Mandatory=$true)][string]$EngineExe)
$ErrorActionPreference='Stop'
$exe=(Resolve-Path -LiteralPath $EngineExe).Path
Write-Host "Inspecting: $exe" -ForegroundColor Cyan
Write-Host 'Windows 0xC0000135 = a required DLL was not found.'
$installed = Join-Path (Split-Path $exe) 'ENGINE_DLL_REPORT.txt'
if (Test-Path $installed) {
  Write-Host "Build dependency report: $installed" -ForegroundColor Cyan
  Get-Content -LiteralPath $installed
}
$dumpbin=Get-Command 'dumpbin.exe' -ErrorAction SilentlyContinue
if ($dumpbin) {
  Write-Host 'Direct native DLL imports:' -ForegroundColor Cyan
  & dumpbin.exe /DEPENDENTS $exe
} else {
  Write-Host 'dumpbin.exe is not on PATH. Use an x64 Developer PowerShell for VS or inspect with Dependencies.exe.' -ForegroundColor Yellow
}
Write-Host 'Look for VCRUNTIME140.dll, VCRUNTIME140_1.dll or MSVCP140.dll first.'
Write-Host 'Install official Microsoft x64 VC++ redistributable: https://aka.ms/vc14/vc_redist.x64.exe' -ForegroundColor Yellow
Write-Host 'Avoid random DLL download websites.'
