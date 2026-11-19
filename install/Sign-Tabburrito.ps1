<#
.SYNOPSIS
    Authenticode-signs a built tabburrito.exe, if a signing certificate exists.

.DESCRIPTION
    Looks for a code-signing certificate in Cert:\CurrentUser\My matching
    -CertSubject and signs the given file with it.

    NEVER FAILS THE BUILD. When no certificate is present this reports plainly
    that the binary is UNSIGNED and exits 0, so a machine without a cert still
    gets a working install. It does not claim success for a signature it did
    not apply - "unsigned" is stated, not silently swallowed.

    Create the certificate with New-TabburritoSigningCert.ps1 (read its header
    first: it is self-signed and local-only, not a publicly trusted cert).

.PARAMETER Path
    The exe to sign.

.PARAMETER CertSubject
    Subject of the signing certificate. Must match New-TabburritoSigningCert.ps1.

.PARAMETER TimestampUrl
    RFC-3161 timestamp server. Timestamping keeps a signature valid past the
    certificate's expiry. Failure to reach it is non-fatal.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Sign-Tabburrito.ps1 -Path .\tabburrito.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$CertSubject = 'CN=Tabburrito Local Build',
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "Sign: file not found: $Path" -ForegroundColor Red
    exit 1
}

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $CertSubject -and $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    Write-Host "Sign: SKIPPED - no signing certificate ($CertSubject)." -ForegroundColor Yellow
    Write-Host "      The installed binary is UNSIGNED. Create a local cert with:" -ForegroundColor Yellow
    Write-Host "      powershell -ExecutionPolicy Bypass -File .\install\New-TabburritoSigningCert.ps1" -ForegroundColor DarkGray
    exit 0
}

# Timestamping needs the network; a signature without one is still valid until
# the cert expires, so a failure here must not lose us the signature entirely.
$result = $null
try {
    $result = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimestampUrl -ErrorAction Stop
} catch {
    Write-Host "Sign: timestamping failed ($($_.Exception.Message.Trim())) - retrying without a timestamp." -ForegroundColor Yellow
    $result = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256
}

if ($result.Status -ne 'Valid') {
    # Report the real status rather than pretending the file is signed.
    Write-Host "Sign: FAILED - status '$($result.Status)': $($result.StatusMessage)" -ForegroundColor Red
    exit 1
}

Write-Host "Sign: OK - signed by $($cert.Subject) [$($cert.Thumbprint.Substring(0,12))...]" -ForegroundColor Green
exit 0
