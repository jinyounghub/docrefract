param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Version must be a stable semantic version."
}

$bundle = (Resolve-Path $BundleDirectory).Path
$runtimeIdentifiers = @(
    "linux-x64",
    "linux-arm64",
    "osx-x64",
    "osx-arm64",
    "win-x64",
    "win-arm64"
)

$nativeArchives = @(
    $runtimeIdentifiers | ForEach-Object {
        $extension = if ($_.StartsWith("win-", [StringComparison]::Ordinal)) {
            ".zip"
        }
        else {
            ".tar.gz"
        }
        "docrefract-$Version-$_$extension"
    }
)
$nativeSboms = @(
    $runtimeIdentifiers | ForEach-Object {
        "docrefract-$Version-$_.spdx.json"
    }
)

$checksumName = "SHA256SUMS"
$expectedChecksummedNames = @(
    "DocRefract.Tool.$Version.nupkg"
    "DocRefract.Tool.$Version.spdx.json"
    "THIRD_PARTY_NOTICES.md"
    $nativeArchives
    $nativeSboms
) | Sort-Object
$expectedNames = @($expectedChecksummedNames + $checksumName) | Sort-Object

$directories = @(Get-ChildItem -LiteralPath $bundle -Directory -Force)
if ($directories.Count -ne 0) {
    throw "Release bundle must be flat; found directories: $($directories.Name -join ', ')"
}

$actualNames = @(
    Get-ChildItem -LiteralPath $bundle -File -Force |
        ForEach-Object Name |
        Sort-Object
)
if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
    throw @"
Release bundle does not match the exact 16-file whitelist.
Expected: $($expectedNames -join ', ')
Found: $($actualNames -join ', ')
"@
}

$manifestPath = Join-Path $bundle $checksumName
$manifestLines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
if ($manifestLines.Count -ne $expectedChecksummedNames.Count) {
    throw "Expected 15 checksum entries, found $($manifestLines.Count)."
}

$manifest = @{}
foreach ($line in $manifestLines) {
    if ($line -cnotmatch "^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$") {
        throw "Invalid SHA256SUMS line: $line"
    }
    if ($manifest.ContainsKey($Matches.name)) {
        throw "Duplicate SHA256SUMS entry: $($Matches.name)"
    }
    $manifest.Add($Matches.name, $Matches.hash)
}

$manifestNames = @($manifest.Keys | Sort-Object)
if (($manifestNames -join "`n") -cne ($expectedChecksummedNames -join "`n")) {
    throw "SHA256SUMS entries do not match the 15 checksummed release assets."
}

foreach ($name in $expectedChecksummedNames) {
    $path = Join-Path $bundle $name
    $actualHash = (
        Get-FileHash -LiteralPath $path -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualHash -cne $manifest[$name]) {
        throw "Checksum mismatch for $name."
    }
}

Write-Host "Verified exact 16-file release set and 15 SHA-256 entries for $Version."
