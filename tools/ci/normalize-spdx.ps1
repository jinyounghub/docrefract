param(
    [Parameter(Mandatory = $true)]
    [string]$SbomPath,

    [Parameter(Mandatory = $true)]
    [string]$DocumentNamespace,

    [Parameter(Mandatory = $true)]
    [string]$CreatedUtc
)

$ErrorActionPreference = "Stop"

$sbomFile = (Resolve-Path $SbomPath).Path
$namespaceUri = $null
if (
    -not [Uri]::TryCreate(
        $DocumentNamespace,
        [UriKind]::Absolute,
        [ref]$namespaceUri
    ) -or
    $namespaceUri.Scheme -ne "https"
) {
    throw "DocumentNamespace must be an absolute HTTPS URI."
}

$created = [DateTimeOffset]::MinValue
if (
    -not [DateTimeOffset]::TryParse(
        $CreatedUtc,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$created
    )
) {
    throw "CreatedUtc must be a valid timestamp."
}
$normalizedCreated = $created.ToUniversalTime().ToString(
    "yyyy-MM-ddTHH:mm:ssZ",
    [Globalization.CultureInfo]::InvariantCulture
)

$sbom = Get-Content -LiteralPath $sbomFile -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ($null -eq $sbom.creationInfo) {
    throw "SPDX document is missing creationInfo."
}

$sbom.documentNamespace = $namespaceUri.AbsoluteUri
$sbom.creationInfo.created = $normalizedCreated

$json = $sbom | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText(
    $sbomFile,
    "$json`n",
    [Text.UTF8Encoding]::new($false)
)

$verified = Get-Content -LiteralPath $sbomFile -Raw -Encoding UTF8 |
    ConvertFrom-Json
if (
    $verified.documentNamespace -cne $namespaceUri.AbsoluteUri -or
    $verified.creationInfo.created -cne $normalizedCreated
) {
    throw "Normalized SPDX provenance did not round-trip."
}

Write-Host (
    "Normalized SPDX namespace and creation time for " +
    [IO.Path]::GetFileName($sbomFile)
)
