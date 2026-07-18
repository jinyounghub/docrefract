param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryCommit,

    [Parameter(Mandatory = $true)]
    [string]$CreatedUtc
)

$ErrorActionPreference = "Stop"

if ($RepositoryCommit -notmatch "^[0-9a-fA-F]{40}$") {
    throw "RepositoryCommit must be a full 40-character Git commit SHA."
}
$repositoryCommitNormalized = $RepositoryCommit.ToLowerInvariant()
$bundle = (Resolve-Path $BundleDirectory).Path

& (Join-Path $PSScriptRoot "verify-release-file-set.ps1") `
    -BundleDirectory $bundle `
    -Version $Version

$manifest = @{}
foreach ($line in @(Get-Content -LiteralPath (Join-Path $bundle "SHA256SUMS") -Encoding UTF8)) {
    if ($line -cnotmatch "^(?<hash>[0-9a-f]{64})  (?<name>[^\\/]+)$") {
        throw "Invalid SHA256SUMS line after file-set verification: $line"
    }
    $manifest.Add($Matches.name, $Matches.hash)
}

$packageName = "DocRefract.Tool.$Version.nupkg"
$packagePath = Join-Path $bundle $packageName
$packageSbomName = "DocRefract.Tool.$Version.spdx.json"
$packageSbomPath = Join-Path $bundle $packageSbomName
$repository = $RepositoryUrl.TrimEnd("/")
$created = [DateTimeOffset]::Parse(
    $CreatedUtc,
    [Globalization.CultureInfo]::InvariantCulture
)
$normalizedCreated = $created.ToUniversalTime().ToString(
    "yyyy-MM-ddTHH:mm:ssZ",
    [Globalization.CultureInfo]::InvariantCulture
)

function Assert-NormalizedSpdx {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sbom,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $expectedNamespace = "$repository/releases/download/v$Version/$FileName"
    if (
        $Sbom.documentNamespace -cne $expectedNamespace -or
        $Sbom.creationInfo.created -cne $normalizedCreated
    ) {
        throw "SPDX namespace or creation time is not reproducibly normalized for $FileName."
    }
}

$packageSbom = Get-Content -LiteralPath $packageSbomPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-NormalizedSpdx -Sbom $packageSbom -FileName $packageSbomName
$describedIds = @(
    $packageSbom.relationships |
        Where-Object {
            $_.spdxElementId -eq "SPDXRef-DOCUMENT" -and
            $_.relationshipType -eq "DESCRIBES"
        } |
        ForEach-Object relatedSpdxElement
)
if ($describedIds.Count -ne 1) {
    throw "Package SBOM must describe exactly one root package."
}
$roots = @(
    $packageSbom.packages |
        Where-Object { $_.SPDXID -eq $describedIds[0] }
)
if ($roots.Count -ne 1) {
    throw "Package SBOM root package is missing or duplicated."
}

$packageRoot = $roots[0]
$packageDownloadUrl = "$repository/releases/download/v$Version/$packageName"
$packagePurl = "pkg:nuget/DocRefract.Tool@$Version"
$matchingChecksums = @(
    $packageRoot.checksums |
        Where-Object {
            $_.algorithm -eq "SHA256" -and
            $_.checksumValue -eq $manifest[$packageName]
        }
)
$matchingPurls = @(
    $packageRoot.externalRefs |
        Where-Object {
            $null -ne $_ -and
            $_.referenceType -eq "purl" -and
            $_.referenceLocator -eq $packagePurl
        }
)
if (
    $packageRoot.name -ne "DocRefract.Tool" -or
    $packageRoot.versionInfo -ne $Version -or
    $packageRoot.packageFileName -ne $packageName -or
    $packageRoot.supplier -ne "Organization: DocRefract contributors" -or
    $packageRoot.downloadLocation -ne $packageDownloadUrl -or
    $packageRoot.homepage -ne $repository -or
    $packageRoot.filesAnalyzed -ne $false -or
    $packageRoot.licenseDeclared -ne "Apache-2.0" -or
    $packageRoot.licenseConcluded -ne "Apache-2.0" -or
    $packageRoot.primaryPackagePurpose -ne "APPLICATION" -or
    $matchingChecksums.Count -ne 1 -or
    $matchingPurls.Count -ne 1
) {
    throw "Package SBOM root does not match the release nupkg."
}

if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
$packageArchive = [IO.Compression.ZipFile]::OpenRead($packagePath)
try {
    $depsEntries = @(
        $packageArchive.Entries |
            Where-Object {
                $_.FullName -match "^tools/[^/]+/[^/]+/docrefract[.]deps[.]json$"
            }
    )
    if ($depsEntries.Count -ne 1) {
        throw "Expected one packaged docrefract.deps.json, found $($depsEntries.Count)."
    }
    $depsReader = [IO.StreamReader]::new(
        $depsEntries[0].Open(),
        [Text.Encoding]::UTF8,
        $true
    )
    try {
        $depsJson = $depsReader.ReadToEnd()
    }
    finally {
        $depsReader.Dispose()
    }

    $nuspecEntries = @(
        $packageArchive.Entries |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.Name) -and
                $_.FullName.EndsWith(
                    ".nuspec",
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($nuspecEntries.Count -ne 1) {
        throw "Expected one package nuspec, found $($nuspecEntries.Count)."
    }
    $xmlSettings = [Xml.XmlReaderSettings]::new()
    $xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $xmlSettings.XmlResolver = $null
    $nuspecStream = $nuspecEntries[0].Open()
    try {
        $xmlReader = [Xml.XmlReader]::Create($nuspecStream, $xmlSettings)
        try {
            $nuspec = [Xml.XmlDocument]::new()
            $nuspec.XmlResolver = $null
            $nuspec.Load($xmlReader)
        }
        finally {
            $xmlReader.Dispose()
        }
    }
    finally {
        $nuspecStream.Dispose()
    }
}
finally {
    $packageArchive.Dispose()
}

$metadata = $nuspec.SelectSingleNode(
    "/*[local-name()='package']/*[local-name()='metadata']"
)
$repositoryNode = $metadata.SelectSingleNode("*[local-name()='repository']")
if ($null -eq $metadata -or $null -eq $repositoryNode) {
    throw "Package nuspec is missing metadata or repository provenance."
}
$nuspecId = [string](
    $metadata.SelectSingleNode("*[local-name()='id']").InnerText
)
$nuspecVersion = [string](
    $metadata.SelectSingleNode("*[local-name()='version']").InnerText
)
if (
    $nuspecId -cne "DocRefract.Tool" -or
    $nuspecVersion -cne $Version -or
    [string]$repositoryNode.GetAttribute("type") -cne "git" -or
    ([string]$repositoryNode.GetAttribute("url")).TrimEnd("/") -cne $repository -or
    [string]$repositoryNode.GetAttribute("commit") -cne $repositoryCommitNormalized
) {
    throw "Package nuspec provenance does not match the tagged release commit."
}

$deps = $depsJson | ConvertFrom-Json
foreach ($internalName in @("docrefract", "DocRefract.Core")) {
    $expectedIdentity = "$internalName/$Version"
    $projectMatches = @(
        $deps.libraries.PSObject.Properties |
            Where-Object {
                $_.Name -ceq $expectedIdentity -and
                $_.Value.type -eq "project"
            }
    )
    if ($projectMatches.Count -ne 1) {
        throw "Packaged dependency graph must contain project $expectedIdentity exactly once."
    }
}

$runtimePackages = @(
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
if ($runtimePackages.Count -eq 0) {
    throw "Packaged dependency graph is empty."
}
foreach ($expected in $runtimePackages) {
    $packageMatches = @(
        $packageSbom.packages |
            Where-Object {
                $_.name -eq $expected.Name -and
                $_.versionInfo -eq $expected.Version
            }
    )
    $expectedPurl = (
        "pkg:nuget/$([Uri]::EscapeDataString($expected.Name))@" +
        "$([Uri]::EscapeDataString($expected.Version))"
    )
    $purlMatches = @(
        $packageMatches.externalRefs |
            Where-Object {
                $null -ne $_ -and
                $_.referenceType -eq "purl" -and
                $_.referenceLocator -eq $expectedPurl
            }
    )
    if ($packageMatches.Count -eq 0 -or $purlMatches.Count -eq 0) {
        throw "Package SBOM is missing runtime package $($expected.Name) $($expected.Version)."
    }
}

$runtimeIdentifiers = @(
    "linux-x64",
    "linux-arm64",
    "osx-x64",
    "osx-arm64",
    "win-x64",
    "win-arm64"
)
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$verificationRoot = Join-Path (
    $temporaryRoot
) "docrefract-release-verify-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $verificationRoot | Out-Null
try {
    foreach ($rid in $runtimeIdentifiers) {
        $extension = if ($rid.StartsWith("win-", [StringComparison]::Ordinal)) {
            ".zip"
        }
        else {
            ".tar.gz"
        }
        $rootName = "docrefract-$Version-$rid"
        $nativeSbomName = "$rootName.spdx.json"
        $nativeSbomPath = Join-Path $bundle $nativeSbomName
        & (Join-Path $PSScriptRoot "verify-native-release-asset.ps1") `
            -ArchivePath (Join-Path $bundle "$rootName$extension") `
            -SbomPath $nativeSbomPath `
            -Version $Version `
            -RuntimeIdentifier $rid `
            -RepositoryUrl $repository `
            -WorkDirectory (Join-Path $verificationRoot $rid)
        $nativeSbom = Get-Content -LiteralPath $nativeSbomPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        Assert-NormalizedSpdx -Sbom $nativeSbom -FileName $nativeSbomName
    }
}
finally {
    $expectedPrefix = $temporaryRoot.TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    if (-not $verificationRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a verification directory outside the system temp root."
    }
    if (Test-Path -LiteralPath $verificationRoot) {
        Remove-Item -LiteralPath $verificationRoot -Recurse -Force
    }
}

Write-Host (
    "Verified exact 16-asset release bundle, nupkg provenance/SBOM, and " +
    "six native archive/SBOM contracts for $Version."
)
