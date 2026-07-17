param(
    [Parameter(Mandatory = $true)]
    [string]$SbomPath,

    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl
)

$ErrorActionPreference = "Stop"

$sbomFile = (Resolve-Path $SbomPath).Path
$packageFile = (Resolve-Path $PackagePath).Path
$packageName = [IO.Path]::GetFileName($packageFile)
$expectedPackageName = "DocRefract.Tool.$Version.nupkg"
if ($packageName -ne $expectedPackageName) {
    throw "Expected package $expectedPackageName, found $packageName."
}

$sbom = Get-Content -LiteralPath $sbomFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
    throw "Expected one described root package, found $($roots.Count)."
}

$root = $roots[0]
if ($root.name -ne "DocRefract.Tool" -or $root.versionInfo -ne $Version) {
    throw "Syft root identity does not match DocRefract.Tool $Version."
}

$sha256 = (Get-FileHash -LiteralPath $packageFile -Algorithm SHA256).Hash.ToLowerInvariant()
$repository = $RepositoryUrl.TrimEnd("/")
$downloadUrl = "$repository/releases/download/v$Version/$packageName"
$purl = "pkg:nuget/DocRefract.Tool@$Version"

$root | Add-Member -NotePropertyName packageFileName -NotePropertyValue $packageName -Force
$root | Add-Member -NotePropertyName supplier -NotePropertyValue "Organization: DocRefract contributors" -Force
$root | Add-Member -NotePropertyName downloadLocation -NotePropertyValue $downloadUrl -Force
$root | Add-Member -NotePropertyName homepage -NotePropertyValue $repository -Force
$root | Add-Member -NotePropertyName filesAnalyzed -NotePropertyValue $false -Force
$root | Add-Member -NotePropertyName licenseConcluded -NotePropertyValue "Apache-2.0" -Force
$root | Add-Member -NotePropertyName licenseDeclared -NotePropertyValue "Apache-2.0" -Force
$root | Add-Member -NotePropertyName copyrightText -NotePropertyValue "NOASSERTION" -Force
$root | Add-Member -NotePropertyName primaryPackagePurpose -NotePropertyValue "APPLICATION" -Force
$root | Add-Member -NotePropertyName checksums -NotePropertyValue @(
    [pscustomobject]@{
        algorithm = "SHA256"
        checksumValue = $sha256
    }
) -Force

$externalRefs = @(
    $root.externalRefs |
        Where-Object {
            $null -ne $_ -and
            ($_.referenceType -ne "purl" -or $_.referenceLocator -ne $purl)
        }
)
$externalRefs += [pscustomobject]@{
    referenceCategory = "PACKAGE-MANAGER"
    referenceType = "purl"
    referenceLocator = $purl
}
$root | Add-Member -NotePropertyName externalRefs -NotePropertyValue @($externalRefs) -Force

$forbiddenPackages = @(
    $sbom.packages |
        Where-Object {
            $_.name -match "^(xunit|coverlet)" -or
            $_.name -eq "Microsoft.NET.Test.Sdk"
        }
)
if ($forbiddenPackages.Count -gt 0) {
    $names = $forbiddenPackages.name -join ", "
    throw "Packaged-payload SBOM unexpectedly contains development dependencies: $names"
}

if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
$archive = [IO.Compression.ZipFile]::OpenRead($packageFile)
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
        throw "SBOM is missing packaged dependency $($expected.Name) $($expected.Version)."
    }
}


$rootChecksum = @(
    $root.checksums |
        Where-Object {
            $_.algorithm -eq "SHA256" -and
            $_.checksumValue -eq $sha256
        }
)
$rootPurl = @(
    $root.externalRefs |
        Where-Object {
            $_.referenceType -eq "purl" -and
            $_.referenceLocator -eq $purl
        }
)
if (
    $root.packageFileName -ne $packageName -or
    $root.supplier -ne "Organization: DocRefract contributors" -or
    $root.downloadLocation -ne $downloadUrl -or
    $root.homepage -ne $repository -or
    $root.filesAnalyzed -ne $false -or
    $root.licenseDeclared -ne "Apache-2.0" -or
    $root.licenseConcluded -ne "Apache-2.0" -or
    $root.primaryPackagePurpose -ne "APPLICATION" -or
    $rootChecksum.Count -ne 1 -or
    $rootPurl.Count -ne 1
) {
    throw "Final SPDX root package validation failed."
}

$json = $sbom | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($sbomFile, "$json`n", [Text.UTF8Encoding]::new($false))
Write-Host "Finalized packaged-payload SPDX SBOM for $packageName ($sha256)."
