param([Parameter(Mandatory = $true)][string]$Directory)
$ErrorActionPreference = 'Stop'
$openssl = (Get-Command openssl.exe -ErrorAction SilentlyContinue).Source
if (!$openssl) {
  $openssl = @("$env:ProgramFiles\OpenSSL\bin\openssl.exe", "$env:ProgramFiles\Git\usr\bin\openssl.exe") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (!$openssl) { throw 'OpenSSL is required to create local HTTPS credentials.' }

$dir = (Resolve-Path -LiteralPath $Directory).Path
$cert = Join-Path $dir 'cert.pem'
$key = Join-Path $dir 'key.pem'
if ((Test-Path -LiteralPath $cert) -or (Test-Path -LiteralPath $key)) {
  throw 'Choose a directory without existing cert.pem or key.pem.'
}
$argsForOpenSSL = @(
  'req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-days', '14', '-subj', '/CN=ALKO local test',
  '-addext', 'basicConstraints=critical,CA:FALSE',
  '-addext', 'keyUsage=critical,digitalSignature,keyEncipherment',
  '-addext', 'extendedKeyUsage=serverAuth',
  '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1,DNS:growtopia1.com,DNS:www.growtopia1.com,DNS:growtopia2.com,DNS:www.growtopia2.com',
  '-keyout', $key, '-out', $cert
)
& $openssl @argsForOpenSSL
if ($LASTEXITCODE -ne 0) { throw 'OpenSSL could not create the HTTPS credentials.' }
Write-Host "Created $cert and $key."
