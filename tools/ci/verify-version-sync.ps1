Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path

function Read-RepositoryText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    return Get-Content `
        -LiteralPath (Join-Path $repositoryRoot $RelativePath) `
        -Raw `
        -Encoding UTF8
}

[xml]$build = Read-RepositoryText -RelativePath "Directory.Build.props"
$versionNode = $build.SelectSingleNode("/Project/PropertyGroup/Version")
$version = [string]$versionNode.InnerText
if ($version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Directory.Build.props must contain a stable semantic Version."
}

$readmeNeedles = [Collections.Generic.List[string]]::new()
foreach ($needle in @(
    "open-source PDF diff",
    "DOCX diff",
    "document regression testing CLI",
    "dotnet tool install --global DocRefract.Tool --version $version",
    "dotnet tool update --global DocRefract.Tool --version $version",
    "gh release download v$version",
    "docrefract demo --out report",
    "https://jinyounghub.github.io/docrefract/",
    "uses: jinyounghub/docrefract@v$version"
)) {
    $readmeNeedles.Add($needle)
}

$nativeExtensions = [ordered]@{
    "linux-x64" = ".tar.gz"
    "linux-arm64" = ".tar.gz"
    "osx-x64" = ".tar.gz"
    "osx-arm64" = ".tar.gz"
    "win-x64" = ".zip"
    "win-arm64" = ".zip"
}
foreach ($runtimeIdentifier in $nativeExtensions.Keys) {
    $readmeNeedles.Add(
        "docrefract-$version-$runtimeIdentifier$($nativeExtensions[$runtimeIdentifier])"
    )
}

foreach ($runtimeIdentifier in $nativeExtensions.Keys) {
    foreach ($projectName in @("DocRefract.Cli", "DocRefract.Core")) {
        $lockRelativePath = "eng/native-locks/$projectName.$runtimeIdentifier.lock.json"
        $lockPath = Join-Path $repositoryRoot $lockRelativePath
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
            throw "Missing native dependency lock: $lockRelativePath"
        }
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $targetName = "net10.0/$runtimeIdentifier"
        if ($null -eq $lock.dependencies.PSObject.Properties[$targetName]) {
            throw "$lockRelativePath is missing target $targetName."
        }
    }
}
$checks = @(
    [pscustomobject]@{
        Path = "README.md"
        Needles = @($readmeNeedles)
    },
    [pscustomobject]@{
        Path = "action.yml"
        Needles = @(
            "default: $version",
            "dotnet-version: 10.0.302"
        )
    },
    [pscustomobject]@{
        Path = "docs/diff-json.md"
        Needles = @("""toolVersion"": ""$version""")
    },
    [pscustomobject]@{
        Path = ".github/ISSUE_TEMPLATE/bug.yml"
        Needles = @("placeholder: $version")
    },
    [pscustomobject]@{
        Path = "CHANGELOG.md"
        Needles = @(
            "## [$version] - 2026-07-17",
            "[Unreleased]: https://github.com/jinyounghub/docrefract/compare/v$version...HEAD"
        )
    }
)

foreach ($check in $checks) {
    $content = Read-RepositoryText -RelativePath $check.Path
    foreach ($needle in $check.Needles) {
        if ($content.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            throw "$($check.Path) is not synchronized with version $version; missing: $needle"
        }
    }
}

[xml]$cliProject = Read-RepositoryText `
    -RelativePath "src/DocRefract.Cli/DocRefract.Cli.csproj"
if ($null -ne $cliProject.SelectSingleNode("/Project/PropertyGroup/Version")) {
    throw "The CLI project must inherit Version from Directory.Build.props."
}

$requiredPackageMetadata = [ordered]@{
    PackageId = "DocRefract.Tool"
    Title = "DocRefract - PDF and DOCX Document Regression CLI"
    PackageRequireLicenseAcceptance = "false"
    PackageReleaseNotes = 'https://github.com/jinyounghub/docrefract/releases/tag/v$(Version)'
}
foreach ($propertyName in $requiredPackageMetadata.Keys) {
    $node = $cliProject.SelectSingleNode("/Project/PropertyGroup/$propertyName")
    $expected = $requiredPackageMetadata[$propertyName]
    if ($null -eq $node -or [string]$node.InnerText -cne $expected) {
        throw "CLI package metadata $propertyName must be '$expected'."
    }
}

$descriptionNode = $cliProject.SelectSingleNode("/Project/PropertyGroup/Description")
if ($null -eq $descriptionNode -or [string]::IsNullOrWhiteSpace($descriptionNode.InnerText)) {
    throw "CLI package metadata must include a Description."
}

$tagsNode = $cliProject.SelectSingleNode("/Project/PropertyGroup/PackageTags")
$packageTags = @()
if ($null -ne $tagsNode) {
    $packageTags = @(
        $tagsNode.InnerText.Split(";") |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
    )
}
foreach ($requiredTag in @(
    "pdf-diff",
    "docx-diff",
    "document-testing",
    "regression-testing",
    "github-actions"
)) {
    if ($packageTags -notcontains $requiredTag) {
        throw "CLI PackageTags is missing '$requiredTag'."
    }
}

$sdk = Read-RepositoryText -RelativePath "global.json" | ConvertFrom-Json
if ([string]$sdk.sdk.version -cne "10.0.302") {
    throw "global.json must pin SDK 10.0.302."
}
if ([string]$sdk.sdk.rollForward -cne "disable") {
    throw "global.json must disable SDK roll-forward."
}

foreach ($workflow in @(
    ".github/workflows/ci.yml",
    ".github/workflows/pages.yml",
    ".github/workflows/action-test.yml",
    ".github/workflows/native.yml",
    ".github/workflows/release.yml"
)) {
    $workflowContent = Read-RepositoryText -RelativePath $workflow
    if (
        $workflowContent.IndexOf(
            "dotnet-version: 10.0.302",
            [StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "$workflow must pin actions/setup-dotnet to SDK 10.0.302."
    }
}

foreach ($workflow in @(
    ".github/workflows/native.yml",
    ".github/workflows/release.yml"
)) {
    $workflowContent = Read-RepositoryText -RelativePath $workflow
    $runtimeLockNeedle = '-p:RuntimeIdentifier=$' + '{{ matrix.rid }}'
    if (
        $workflowContent.IndexOf(
            $runtimeLockNeedle,
            [StringComparison]::Ordinal
        ) -lt 0 -or
        $workflowContent.IndexOf(
            "-p:SelfContained=true",
            [StringComparison]::Ordinal
        ) -lt 0 -or
        $workflowContent.IndexOf("--force-evaluate", [StringComparison]::Ordinal) -ge 0
    ) {
        throw "$workflow must restore self-contained RID-specific lock files in locked mode."
    }
}
$ciWorkflow = Read-RepositoryText -RelativePath ".github/workflows/ci.yml"
if (
    $ciWorkflow.IndexOf(
        "./tools/ci/normalize-nupkg.ps1",
        [StringComparison]::Ordinal
    ) -lt 0
) {
    throw "CI must normalize the NuGet package before smoke installation."
}

$releaseWorkflow = Read-RepositoryText -RelativePath ".github/workflows/release.yml"
foreach ($needle in @(
    "./tools/ci/normalize-nupkg.ps1",
    'repos/$env:GH_REPO/immutable-releases',
    "Published GitHub release is not immutable."
)) {
    if ($releaseWorkflow.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
        throw "Release workflow is missing its package immutability contract: $needle"
    }
}

Write-Host "Versioned package, NuGet install, native assets, Action, demo, report, documentation, issue metadata, and SDK pin are synchronized at $version."
