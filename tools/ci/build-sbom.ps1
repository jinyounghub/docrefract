param(
    [Parameter(Mandatory = $true)]
    [string]$SyftPath,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$syft = if (Test-Path -LiteralPath $SyftPath) {
    (Resolve-Path $SyftPath).Path
}
else {
    (Get-Command $SyftPath -CommandType Application -ErrorAction Stop).Source
}
$package = (Resolve-Path $PackagePath).Path
$output = [IO.Path]::GetFullPath($OutputPath)
$payload = [IO.Path]::GetFullPath($WorkDirectory)

if (Test-Path -LiteralPath $payload) {
    throw "SBOM payload directory already exists: $payload"
}
if (Test-Path -LiteralPath $output) {
    throw "SBOM output already exists: $output"
}

New-Item -ItemType Directory -Path $payload | Out-Null
$outputDirectory = [IO.Path]::GetDirectoryName($output)
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
[IO.Compression.ZipFile]::ExtractToDirectory($package, $payload)

$env:SYFT_CHECK_FOR_APP_UPDATE = "false"
& $syft "dir:$payload" `
    --source-name "DocRefract.Tool" `
    --source-version $Version `
    --output "spdx-json=$output"
if ($LASTEXITCODE -ne 0) {
    throw "Syft failed with exit code $LASTEXITCODE."
}

& (Join-Path $PSScriptRoot "finalize-sbom.ps1") `
    -SbomPath $output `
    -PackagePath $package `
    -Version $Version `
    -RepositoryUrl $RepositoryUrl

Write-Host "Built packaged-payload SBOM at $output."
