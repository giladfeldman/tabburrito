<#
.SYNOPSIS
    Creates a LOCAL, SELF-SIGNED code-signing certificate for Tabburrito builds.

.DESCRIPTION
    Run this ONCE. It creates a self-signed code-signing certificate and trusts
    it for the current user, so that every locally built tabburrito.exe can
    carry an Authenticode signature instead of being a bare unsigned binary.

    WHAT THIS IS NOT
    ----------------
    This is NOT a real, publicly trusted code-signing certificate. It is signed
    by itself and trusted only because this script puts it in YOUR OWN trust
    stores. Specifically:

      * On THIS machine, the exe becomes a signed binary from a trusted
        publisher. That helps SmartScreen / Smart App Control, and gives
        Defender's ML engine a signature to weigh instead of scoring a bare
        unsigned binary.
      * On ANY OTHER machine it is worse than useless: an untrusted publisher
        looks more suspicious than no signature at all. Never ship a build
        signed with this cert to anyone else.
      * It is NOT guaranteed to stop the `Trojan:Win32/Bearfoos.A!ml` false
        positive. Signature presence is one input to a machine-learning score,
        not an exemption. The verified fix for that on this machine is the
        Defender path exclusion (see install\README.md). Treat this as
        hardening, and as the plumbing that a real CA certificate can later
        drop into unchanged.

    WHAT IT CHANGES (this is why you run it, not Claude)
    ---------------------------------------------------
      * Creates a cert in   Cert:\CurrentUser\My
      * Copies it into      Cert:\CurrentUser\Root             (trusted root)
      * Copies it into      Cert:\CurrentUser\TrustedPublisher

    Those are trust-store changes. They apply to your user account only and need
    no elevation, but they are real security settings - read the script before
    running it.

.PARAMETER Subject
    Certificate subject. Must match the -CertSubject used by Sign-Tabburrito.ps1.

.PARAMETER YearsValid
    Lifetime in years (default 5).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\New-TabburritoSigningCert.ps1

.EXAMPLE
    # Remove it again:
    Get-ChildItem Cert:\CurrentUser\My, Cert:\CurrentUser\Root, Cert:\CurrentUser\TrustedPublisher |
        Where-Object { $_.Subject -eq 'CN=Tabburrito Local Build' } | Remove-Item
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=Tabburrito Local Build',
    [int]$YearsValid = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host 'Tabburrito local signing certificate' -ForegroundColor Cyan
Write-Host '====================================' -ForegroundColor Cyan
Write-Host ''
Write-Host 'This creates a SELF-SIGNED certificate and trusts it for your user account.' -ForegroundColor Yellow
Write-Host 'It is for local builds only. Never distribute a build signed with it.' -ForegroundColor Yellow
Write-Host ''

$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($cert) {
    Write-Host 'Reusing the existing certificate:' -ForegroundColor Green
    Write-Host "  Thumbprint : $($cert.Thumbprint)"
    Write-Host "  Expires    : $($cert.NotAfter)"
} else {
    Write-Host "Creating certificate: $Subject" -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Subject $Subject `
        -Type CodeSigningCert `
        -KeyUsage DigitalSignature `
        -KeyLength 3072 `
        -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotAfter (Get-Date).AddYears($YearsValid)

    Write-Host "  Thumbprint : $($cert.Thumbprint)" -ForegroundColor Green
}

# Trust it for this user so the signature actually validates locally.
#
# This runs on EVERY invocation, including when the certificate already exists.
# An earlier version returned early on "already exists" and so could never
# repair a half-finished run - which is exactly what happened on 2026-08-13,
# when creation succeeded and the trust import then crashed, leaving a cert
# that was permanently untrusted and unrepairable by re-running.
Write-Host ''
Write-Host 'Windows may show a security warning when trusting the certificate - that is' -ForegroundColor Yellow
Write-Host 'this script asking to add it to your own root store. Answer Yes to continue.' -ForegroundColor Yellow

# NOTE: -ArgumentList (,$bytes). Without the leading comma PowerShell UNROLLS
# the byte[] and passes one argument per byte, producing
# "Cannot find an overload for X509Certificate2 and the argument count: 1046".
$certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)

foreach ($storeName in @('Root', 'TrustedPublisher')) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        $storeName, [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $already = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if ($already) {
            Write-Host "  Already trusted in Cert:\CurrentUser\$storeName" -ForegroundColor DarkGray
        } else {
            # Import the PUBLIC cert only - the private key stays in CurrentUser\My.
            $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certBytes)
            $store.Add($pub)
            Write-Host "  Trusted in Cert:\CurrentUser\$storeName" -ForegroundColor Green
        }
    } finally {
        $store.Close()
    }
}

# Verify rather than assume: report what the stores ACTUALLY contain now.
Write-Host ''
$trusted = $true
foreach ($storeName in @('Root', 'TrustedPublisher')) {
    $hit = Get-ChildItem "Cert:\CurrentUser\$storeName" -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if ($hit) {
        Write-Host "  VERIFIED present in Cert:\CurrentUser\$storeName" -ForegroundColor Green
    } else {
        Write-Host "  MISSING from Cert:\CurrentUser\$storeName - signing will still work," -ForegroundColor Red
        Write-Host "  but the signature will not validate as trusted on this machine." -ForegroundColor Red
        $trusted = $false
    }
}
if (-not $trusted) { exit 1 }

Write-Host ''
Write-Host 'Done. Future installs will sign tabburrito.exe automatically.' -ForegroundColor Green
Write-Host 'Sign the current build now with:' -ForegroundColor DarkGray
Write-Host '  powershell -ExecutionPolicy Bypass -File .\install\Install-Tabburrito.ps1' -ForegroundColor DarkGray
Write-Host ''
