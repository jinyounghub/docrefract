param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$SbomPath,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "linux-x64",
        "linux-arm64",
        "osx-x64",
        "osx-arm64",
        "win-x64",
        "win-arm64"
    )]
    [string]$RuntimeIdentifier,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Version must be a stable semantic version."
}

$archive = (Resolve-Path $ArchivePath).Path
$sbomFile = (Resolve-Path $SbomPath).Path
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) {
    throw "Native verification work directory already exists: $work"
}

$isWindowsRuntime = $RuntimeIdentifier.StartsWith(
    "win-",
    [StringComparison]::Ordinal
)
$extension = if ($isWindowsRuntime) { ".zip" } else { ".tar.gz" }
$rootName = "docrefract-$Version-$RuntimeIdentifier"
$archiveName = "$rootName$extension"
$sbomName = "$rootName.spdx.json"
$executableName = if ($isWindowsRuntime) { "docrefract.exe" } else { "docrefract" }

if ([IO.Path]::GetFileName($archive) -cne $archiveName) {
    throw "Expected native archive $archiveName."
}
if ([IO.Path]::GetFileName($sbomFile) -cne $sbomName) {
    throw "Expected native SBOM $sbomName."
}

function Assert-SafeArchiveEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    $normalized = $EntryName.Replace("\", "/").TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }
    if (
        $normalized.StartsWith("/", [StringComparison]::Ordinal) -or
        $normalized -match "^[A-Za-z]:" -or
        $normalized.IndexOf([char]0) -ge 0
    ) {
        throw "Unsafe absolute archive entry: $EntryName"
    }

    $segments = @($normalized.Split("/") | Where-Object Length -gt 0)
    if ($segments.Count -eq 0 -or $segments[0] -cne $rootName) {
        throw "Archive entry is outside the single expected root: $EntryName"
    }
    if (@($segments | Where-Object { $_ -eq "." -or $_ -eq ".." }).Count -gt 0) {
        throw "Archive entry contains a traversal segment: $EntryName"
    }
}

$extract = Join-Path $work "extract"
New-Item -ItemType Directory -Path $extract -Force | Out-Null

if ($isWindowsRuntime) {
    if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        if ($zip.Entries.Count -eq 0) {
            throw "Native ZIP archive is empty."
        }
        foreach ($entry in $zip.Entries) {
            Assert-SafeArchiveEntry -EntryName $entry.FullName
        }
    }
    finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
}
else {
    $tar = (
        Get-Command tar -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    ).Source
    $entries = @(& $tar -tzf $archive)
    if ($LASTEXITCODE -ne 0) {
        throw "Listing $archiveName failed with exit code $LASTEXITCODE."
    }
    if ($entries.Count -eq 0) {
        throw "Native tar archive is empty."
    }
    foreach ($entry in $entries) {
        Assert-SafeArchiveEntry -EntryName $entry
    }
    & $tar -xzf $archive -C $extract
    if ($LASTEXITCODE -ne 0) {
        throw "Extracting $archiveName failed with exit code $LASTEXITCODE."
    }
}

$topLevel = @(Get-ChildItem -LiteralPath $extract -Force)
if (
    $topLevel.Count -ne 1 -or
    -not $topLevel[0].PSIsContainer -or
    $topLevel[0].Name -cne $rootName
) {
    throw "Native archive must contain exactly one top-level directory named $rootName."
}
$payload = $topLevel[0].FullName

$links = @(
    Get-ChildItem -LiteralPath $payload -Recurse -Force |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        }
)
if ($links.Count -ne 0) {
    throw "Native archive must not contain symbolic links or reparse points."
}

foreach ($requiredName in @(
    $executableName,
    "README.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "VERSION",
    "docrefract.deps.json",
    "docrefract.runtimeconfig.json"
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $payload $requiredName) -PathType Leaf)) {
        throw "Native archive is missing $requiredName."
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $payload "licenses") -PathType Container)) {
    throw "Native archive is missing the licenses directory."
}

$reportedVersion = (
    Get-Content -LiteralPath (Join-Path $payload "VERSION") -Raw -Encoding UTF8
).Trim()
if ($reportedVersion -cne $Version) {
    throw "Native VERSION file reports $reportedVersion; expected $Version."
}

$pdbFiles = @(
    Get-ChildItem -LiteralPath $payload -Recurse -File -Filter *.pdb
)
if ($pdbFiles.Count -ne 0) {
    throw "Native archive unexpectedly contains debug symbols."
}

$depsPath = Join-Path $payload "docrefract.deps.json"
$deps = Get-Content -LiteralPath $depsPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runtimeTargetName = [string]$deps.runtimeTarget.name
if (
    [string]::IsNullOrWhiteSpace($runtimeTargetName) -or
    -not $runtimeTargetName.EndsWith(
        "/$RuntimeIdentifier",
        [StringComparison]::Ordinal
    )
) {
    throw "Native dependency graph target '$runtimeTargetName' does not match $RuntimeIdentifier."
}
if ($null -eq $deps.targets.PSObject.Properties[$runtimeTargetName]) {
    throw "Native dependency graph is missing target $runtimeTargetName."
}

foreach ($internalName in @("docrefract", "DocRefract.Core")) {
    $identity = "$internalName/$Version"
    $projectMatches = @(
        $deps.libraries.PSObject.Properties |
            Where-Object {
                $_.Name -ceq $identity -and
                $_.Value.type -eq "project"
            }
    )
    if ($projectMatches.Count -ne 1) {
        throw "Native dependency graph must contain project $identity exactly once."
    }
}

$escapedRid = [Regex]::Escape($RuntimeIdentifier)
$runtimePacks = @(
    $deps.libraries.PSObject.Properties |
        Where-Object {
            $_.Name -match (
                "(?i)(?:^|[.])Microsoft[.]NETCore[.]App[.]Runtime[.]" +
                "$escapedRid/"
            )
        }
)
if ($runtimePacks.Count -eq 0) {
    throw "Native dependency graph does not identify the $RuntimeIdentifier .NET runtime pack."
}

$runtimePackages = @(
    $deps.libraries.PSObject.Properties |
        Where-Object {
            $_.Value.type -eq "package" -and
            $_.Name -notmatch "^(?i:runtimepack[.])" -and
            $_.Name -notmatch "^(?i:Microsoft[.]NETCore[.](?:App|DotNetAppHost)[.])"
        } |
        ForEach-Object {
            $separator = $_.Name.LastIndexOf("/", [StringComparison]::Ordinal)
            if ($separator -le 0 -or $separator -eq $_.Name.Length - 1) {
                throw "Invalid native dependency identity: $($_.Name)"
            }
            [pscustomobject]@{
                Name = $_.Name.Substring(0, $separator)
                Version = $_.Name.Substring($separator + 1)
            }
        }
)
if ($runtimePackages.Count -eq 0) {
    throw "Native dependency graph contains no external runtime packages."
}
foreach ($requiredPackage in @("DocumentFormat.OpenXml", "PdfPig")) {
    if (@($runtimePackages | Where-Object Name -eq $requiredPackage).Count -ne 1) {
        throw "Native dependency graph must contain $requiredPackage exactly once."
    }
}

$forbiddenDependencies = @(
    $runtimePackages |
        Where-Object {
            $_.Name -match "^(xunit|coverlet)" -or
            $_.Name -eq "Microsoft.NET.Test.Sdk"
        }
)
if ($forbiddenDependencies.Count -ne 0) {
    throw "Native dependency graph contains development dependencies."
}

$sbom = Get-Content -LiteralPath $sbomFile -Raw -Encoding UTF8 |
    ConvertFrom-Json
$describedIds = @(
    $sbom.relationships |
        Where-Object {
            $_.spdxElementId -eq "SPDXRef-DOCUMENT" -and
            $_.relationshipType -eq "DESCRIBES"
        } |
        ForEach-Object relatedSpdxElement
)
if ($describedIds.Count -ne 1) {
    throw "Native SBOM must describe exactly one root package."
}
$roots = @($sbom.packages | Where-Object SPDXID -eq $describedIds[0])
if ($roots.Count -ne 1) {
    throw "Native SBOM root package is missing or duplicated."
}

$root = $roots[0]
$archiveHash = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
$repository = $RepositoryUrl.TrimEnd("/")
$downloadUrl = "$repository/releases/download/v$Version/$archiveName"
$purl = "pkg:github/jinyounghub/docrefract@$Version`?rid=$RuntimeIdentifier"
$matchingChecksums = @(
    $root.checksums |
        Where-Object {
            $_.algorithm -eq "SHA256" -and
            $_.checksumValue -eq $archiveHash
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
    $root.name -ne "DocRefract" -or
    $root.versionInfo -ne $Version -or
    $root.packageFileName -ne $archiveName -or
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
    throw "Native SBOM root does not match $archiveName."
}

$sbomDevelopmentDependencies = @(
    $sbom.packages |
        Where-Object {
            $_.name -match "^(xunit|coverlet)" -or
            $_.name -eq "Microsoft.NET.Test.Sdk"
        }
)
if ($sbomDevelopmentDependencies.Count -ne 0) {
    throw "Native SBOM unexpectedly contains development dependencies."
}

foreach ($expected in $runtimePackages) {
    $packageMatches = @(
        $sbom.packages |
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
        throw "Native SBOM is missing runtime package $($expected.Name) $($expected.Version)."
    }
}

$global:LASTEXITCODE = 0
Write-Host "Verified native archive, RID dependency graph, and SBOM for $archiveName."
