param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPackagePath,

    [Parameter(Mandatory = $true)]
    [string]$ActualPackagePath,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryUrl,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryCommit
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Version must be a stable semantic version."
}
if ($RepositoryCommit -notmatch "^[0-9a-fA-F]{40}$") {
    throw "RepositoryCommit must be a full 40-character Git commit SHA."
}

$expectedPackage = (Resolve-Path $ExpectedPackagePath).Path
$actualPackage = (Resolve-Path $ActualPackagePath).Path
if ($null -eq ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

function Get-PackageMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $nuspecs = @(
            $archive.Entries |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.Name) -and
                    $_.FullName.EndsWith(
                        ".nuspec",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        if ($nuspecs.Count -ne 1) {
            throw "Expected exactly one nuspec in $PackagePath."
        }

        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $stream = $nuspecs[0].Open()
        try {
            $reader = [Xml.XmlReader]::Create($stream, $settings)
            try {
                $document = [Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.Load($reader)
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }

    $metadata = $document.SelectSingleNode(
        "/*[local-name()='package']/*[local-name()='metadata']"
    )
    if ($null -eq $metadata) {
        throw "Package nuspec does not contain metadata."
    }
    $repository = $metadata.SelectSingleNode("*[local-name()='repository']")
    if ($null -eq $repository) {
        throw "Package nuspec does not contain repository provenance."
    }

    [pscustomobject]@{
        Id = [string](
            $metadata.SelectSingleNode("*[local-name()='id']").InnerText
        )
        Version = [string](
            $metadata.SelectSingleNode("*[local-name()='version']").InnerText
        )
        RepositoryType = [string]$repository.GetAttribute("type")
        RepositoryUrl = [string]$repository.GetAttribute("url")
        RepositoryCommit = [string]$repository.GetAttribute("commit")
    }
}

function Get-PayloadEntryHashes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    $hashes = @{}
    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.Name)) {
                continue
            }
            $normalized = $entry.FullName.Replace("\", "/")
            if (
                $normalized.Equals(
                    ".signature.p7s",
                    [StringComparison]::OrdinalIgnoreCase
                ) -or
                $normalized.Equals(
                    "[Content_Types].xml",
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                continue
            }
            if ($hashes.ContainsKey($normalized)) {
                throw "Duplicate package entry $normalized in $PackagePath."
            }

            $stream = $entry.Open()
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    $hash = ([BitConverter]::ToString(
                        $sha.ComputeHash($stream)
                    )).Replace("-", "").ToLowerInvariant()
                }
                finally {
                    $sha.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
            $hashes.Add($normalized, $hash)
        }
    }
    finally {
        $archive.Dispose()
    }
    $hashes
}

$expectedMetadata = Get-PackageMetadata -PackagePath $expectedPackage
$actualMetadata = Get-PackageMetadata -PackagePath $actualPackage
$repository = $RepositoryUrl.TrimEnd("/")
foreach ($candidate in @(
    [pscustomobject]@{ Label = "expected"; Metadata = $expectedMetadata },
    [pscustomobject]@{ Label = "actual"; Metadata = $actualMetadata }
)) {
    $metadata = $candidate.Metadata
    if (
        $metadata.Id -cne "DocRefract.Tool" -or
        $metadata.Version -cne $Version -or
        $metadata.RepositoryType -cne "git" -or
        $metadata.RepositoryUrl.TrimEnd("/") -cne $repository -or
        $metadata.RepositoryCommit -cne $RepositoryCommit.ToLowerInvariant()
    ) {
        throw "$($candidate.Label) NuGet package provenance does not match the release."
    }
}

$expectedHashes = Get-PayloadEntryHashes -PackagePath $expectedPackage
$actualHashes = Get-PayloadEntryHashes -PackagePath $actualPackage
$expectedNames = @($expectedHashes.Keys | Sort-Object)
$actualNames = @($actualHashes.Keys | Sort-Object)
if (($expectedNames -join "`n") -cne ($actualNames -join "`n")) {
    throw "NuGet.org package payload entries differ from the GitHub release package."
}
foreach ($name in $expectedNames) {
    if ($expectedHashes[$name] -cne $actualHashes[$name]) {
        throw "NuGet.org package payload differs at $name."
    }
}

dotnet nuget verify $actualPackage --all
if ($LASTEXITCODE -ne 0) {
    throw "NuGet.org package signature verification failed with exit code $LASTEXITCODE."
}

Write-Host (
    "Verified NuGet.org repository-signed package payload and provenance for " +
    "DocRefract.Tool $Version."
)
