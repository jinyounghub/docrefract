$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
[xml]$build = Get-Content (Join-Path $repositoryRoot "Directory.Build.props")
$version = [string]$build.Project.PropertyGroup.Version
if ($version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Directory.Build.props must contain a stable semantic Version."
}

$checks = @(
    [pscustomobject]@{
        Path = "README.md"
        Needles = @(
            "gh release download v$version",
            "DocRefract.Tool.$version.nupkg",
            "dotnet tool install --global DocRefract.Tool --version $version",
            "dotnet tool update --global DocRefract.Tool --version $version"
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
            "## [$version] -",
            "[Unreleased]: https://github.com/jinyounghub/docrefract/compare/v$version...HEAD"
        )
    }
)

foreach ($check in $checks) {
    $path = Join-Path $repositoryRoot $check.Path
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($needle in $check.Needles) {
        if ($content.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) {
            throw "$($check.Path) is not synchronized with version $version; missing: $needle"
        }
    }
}

[xml]$cliProject = Get-Content (
    Join-Path $repositoryRoot "src/DocRefract.Cli/DocRefract.Cli.csproj"
)
if (-not [string]::IsNullOrWhiteSpace([string]$cliProject.Project.PropertyGroup.Version)) {
    throw "The CLI project must inherit Version from Directory.Build.props."
}

Write-Host "Versioned package, CLI, report, documentation, and issue metadata are synchronized at $version."
