param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$ExpectedSha256,

    [Parameter(Mandatory = $true)]
    [string]$DestinationDirectory
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [Runtime.InteropServices.OSPlatform]::Linux
)) {
    throw "The pinned Syft release asset installer supports Linux runners only."
}
if (
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
    [Runtime.InteropServices.Architecture]::X64
) {
    throw "The pinned Syft release asset installer supports x64 runners only."
}
if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Syft Version must be a stable semantic version."
}

$destination = [IO.Path]::GetFullPath($DestinationDirectory)
$archive = "$destination.tar.gz"
if (Test-Path -LiteralPath $destination) {
    throw "Syft destination already exists: $destination"
}
if (Test-Path -LiteralPath $archive) {
    throw "Syft archive already exists: $archive"
}

$assetName = "syft_${Version}_linux_amd64.tar.gz"
$uri = "https://github.com/anchore/syft/releases/download/v$Version/$assetName"
Invoke-WebRequest -Uri $uri -OutFile $archive

$actualSha256 = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($actualSha256 -cne $ExpectedSha256) {
    throw "Syft archive checksum mismatch: expected $ExpectedSha256, found $actualSha256."
}

New-Item -ItemType Directory -Path $destination | Out-Null
$tar = (
    Get-Command tar -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
).Source
& $tar -xzf $archive -C $destination syft
if ($LASTEXITCODE -ne 0) {
    throw "Extracting Syft failed with exit code $LASTEXITCODE."
}

$binary = Join-Path $destination "syft"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "The verified Syft archive did not contain the expected binary."
}

$versionOutput = @(& $binary version 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Running Syft failed with exit code $LASTEXITCODE."
}
$versionText = $versionOutput -join "`n"
$escapedVersion = [regex]::Escape($Version)
if ($versionText -notmatch "(?m)^Version:\s*$escapedVersion\s*$") {
    throw "The Syft binary did not report version $Version."
}

Write-Host $versionText
Write-Output $binary
