param(
    [Parameter(Mandatory = $true)]
    [string]$SyftPath,

    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory,

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
    [string]$RepositoryUrl
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Version must be a stable semantic version."
}

$syft = if (Test-Path -LiteralPath $SyftPath) {
    (Resolve-Path $SyftPath).Path
}
else {
    (Get-Command $SyftPath -CommandType Application -ErrorAction Stop).Source
}
$archive = (Resolve-Path $ArchivePath).Path
$output = [IO.Path]::GetFullPath($OutputPath)
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) {
    throw "Native SBOM work directory already exists: $work"
}
if (Test-Path -LiteralPath $output) {
    throw "Native SBOM output already exists: $output"
}

$isWindowsRuntime = $RuntimeIdentifier.StartsWith(
    "win-",
    [StringComparison]::Ordinal
)
$extension = if ($isWindowsRuntime) { ".zip" } else { ".tar.gz" }
$rootName = "docrefract-$Version-$RuntimeIdentifier"
$archiveName = "$rootName$extension"
if ([IO.Path]::GetFileName($archive) -cne $archiveName) {
    throw "Expected native archive $archiveName."
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

$outputDirectory = [IO.Path]::GetDirectoryName($output)
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$env:SYFT_CHECK_FOR_APP_UPDATE = "false"
& $syft "dir:$payload" `
    --source-name "DocRefract" `
    --source-version $Version `
    --output "spdx-json=$output"
if ($LASTEXITCODE -ne 0) {
    throw "Syft failed for $archiveName with exit code $LASTEXITCODE."
}

$sbom = Get-Content -LiteralPath $output -Raw -Encoding UTF8 |
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
    throw "Syft native SBOM must describe exactly one root package."
}
$roots = @($sbom.packages | Where-Object SPDXID -eq $describedIds[0])
if ($roots.Count -ne 1) {
    throw "Syft native SBOM root package is missing or duplicated."
}
$root = $roots[0]
if ($root.name -ne "DocRefract" -or $root.versionInfo -ne $Version) {
    throw "Syft native root identity does not match DocRefract $Version."
}

$archiveHash = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
$repository = $RepositoryUrl.TrimEnd("/")
$downloadUrl = "$repository/releases/download/v$Version/$archiveName"
$purl = "pkg:github/jinyounghub/docrefract@$Version`?rid=$RuntimeIdentifier"

$root | Add-Member -NotePropertyName packageFileName -NotePropertyValue $archiveName -Force
$root | Add-Member `
    -NotePropertyName supplier `
    -NotePropertyValue "Organization: DocRefract contributors" `
    -Force
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
        checksumValue = $archiveHash
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

$json = $sbom | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText(
    $output,
    "$json`n",
    [Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot "verify-native-release-asset.ps1") `
    -ArchivePath $archive `
    -SbomPath $output `
    -Version $Version `
    -RuntimeIdentifier $RuntimeIdentifier `
    -RepositoryUrl $repository `
    -WorkDirectory (Join-Path $work "contract-verification")

Write-Host "Built clean-extracted native SPDX SBOM for $archiveName."
Write-Output $output
