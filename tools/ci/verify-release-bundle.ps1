param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl
)

$ErrorActionPreference = "Stop"

$bundle = (Resolve-Path $BundleDirectory).Path
$packageName = "DocRefract.Tool.$Version.nupkg"
$sbomName = "DocRefract.Tool.$Version.spdx.json"
$noticeName = "THIRD_PARTY_NOTICES.md"
$checksumName = "SHA256SUMS"
$expectedNames = @($packageName, $sbomName, $noticeName, $checksumName) |
    Sort-Object
$actualNames = @(Get-ChildItem -LiteralPath $bundle -File | ForEach-Object Name) |
    Sort-Object

if (($actualNames -join "`n") -ne ($expectedNames -join "`n")) {
    throw "Release bundle files do not match the four-file whitelist. Found: $($actualNames -join ', ')"
}

$manifestPath = Join-Path $bundle $checksumName
$manifestLines = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8)
$expectedChecksummedNames = @($packageName, $sbomName, $noticeName) |
    Sort-Object
if ($manifestLines.Count -ne $expectedChecksummedNames.Count) {
    throw "Expected three checksum entries, found $($manifestLines.Count)."
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

$manifestNames = @($manifest.Keys) | Sort-Object
if (($manifestNames -join "`n") -ne ($expectedChecksummedNames -join "`n")) {
    throw "SHA256SUMS entries do not match the release asset whitelist."
}

foreach ($name in $expectedChecksummedNames) {
    $path = Join-Path $bundle $name
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne $manifest[$name]) {
        throw "Checksum mismatch for $name."
    }
}

$sbomPath = Join-Path $bundle $sbomName
$sbom = Get-Content -LiteralPath $sbomPath -Raw -Encoding UTF8 | ConvertFrom-Json
$describedIds = @(
    $sbom.relationships |
        Where-Object {
            $_.spdxElementId -eq "SPDXRef-DOCUMENT" -and
            $_.relationshipType -eq "DESCRIBES"
        } |
        ForEach-Object relatedSpdxElement
)
if ($describedIds.Count -ne 1) {
    throw "Expected one SPDX document root, found $($describedIds.Count)."
}

$roots = @($sbom.packages | Where-Object { $_.SPDXID -eq $describedIds[0] })
if ($roots.Count -ne 1) {
    throw "Expected one described SPDX root package, found $($roots.Count)."
}

$root = $roots[0]
$packageHash = $manifest[$packageName]
$repository = $RepositoryUrl.TrimEnd("/")
$downloadUrl = "$repository/releases/download/v$Version/$packageName"
$purl = "pkg:nuget/DocRefract.Tool@$Version"
$matchingChecksums = @(
    $root.checksums |
        Where-Object {
            $_.algorithm -eq "SHA256" -and
            $_.checksumValue -eq $packageHash
        }
)
$matchingPurls = @(
    $root.externalRefs |
        Where-Object {
            $null -ne $_ -and
            $_.referenceType -eq "purl" -and
            $_.referenceLocator -eq $purl
        }
)

if (
    $root.name -ne "DocRefract.Tool" -or
    $root.versionInfo -ne $Version -or
    $root.packageFileName -ne $packageName -or
    $root.supplier -ne "Organization: DocRefract contributors" -or
    $root.downloadLocation -ne $downloadUrl -or
    $root.homepage -ne $repository -or
    $root.filesAnalyzed -ne $false -or
    $root.licenseDeclared -ne "Apache-2.0" -or
    $root.licenseConcluded -ne "Apache-2.0" -or
    $root.primaryPackagePurpose -ne "APPLICATION" -or
    $matchingChecksums.Count -ne 1 -or
    $matchingPurls.Count -ne 1
) {
    throw "Release SBOM root does not match the packaged artifact."
}

if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
$archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $bundle $packageName))
try {
    $depsEntries = @(
        $archive.Entries |
            Where-Object { $_.FullName -match "^tools/[^/]+/[^/]+/docrefract[.]deps[.]json$" }
    )
    if ($depsEntries.Count -ne 1) {
        throw "Expected one packaged docrefract.deps.json, found $($depsEntries.Count)."
    }
    $reader = [IO.StreamReader]::new(
        $depsEntries[0].Open(),
        [Text.Encoding]::UTF8,
        $true
    )
    try {
        $depsJson = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}
finally {
    $archive.Dispose()
}

$deps = $depsJson | ConvertFrom-Json
$expectedInternalProjects = @("docrefract", "DocRefract.Core")
foreach ($internalName in $expectedInternalProjects) {
    $expectedIdentity = "$internalName/$Version"
    $matches = @(
        $deps.libraries.PSObject.Properties |
            Where-Object {
                $_.Name -ceq $expectedIdentity -and
                $_.Value.type -eq "project"
            }
    )
    if ($matches.Count -ne 1) {
        throw "Packaged dependency graph must contain project $expectedIdentity exactly once."
    }
}
$expectedRuntimePackages = @(
    $deps.libraries.PSObject.Properties |
        Where-Object { $_.Value.type -eq "package" } |
        ForEach-Object {
            $separator = $_.Name.LastIndexOf("/", [StringComparison]::Ordinal)
            if ($separator -le 0 -or $separator -eq $_.Name.Length - 1) {
                throw "Invalid packaged dependency identity: $($_.Name)"
            }
            [pscustomobject]@{
                Name = $_.Name.Substring(0, $separator)
                Version = $_.Name.Substring($separator + 1)
            }
        }
)
if ($expectedRuntimePackages.Count -eq 0) {
    throw "Packaged dependency graph is empty."
}

foreach ($expected in $expectedRuntimePackages) {
    $matches = @(
        $sbom.packages |
            Where-Object {
                $_.name -eq $expected.Name -and
                $_.versionInfo -eq $expected.Version
            }
    )
    $expectedPurl = "pkg:nuget/$([Uri]::EscapeDataString($expected.Name))@$([Uri]::EscapeDataString($expected.Version))"
    $purlMatches = @(
        $matches.externalRefs |
            Where-Object {
                $null -ne $_ -and
                $_.referenceType -eq "purl" -and
                $_.referenceLocator -eq $expectedPurl
            }
    )
    if ($matches.Count -eq 0 -or $purlMatches.Count -eq 0) {
        throw "Release SBOM is missing packaged dependency $($expected.Name) $($expected.Version)."
    }
}

Write-Host "Verified four-file release bundle and packaged-artifact SBOM for $packageName."
