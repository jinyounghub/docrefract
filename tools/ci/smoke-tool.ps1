param(
    [Parameter(Mandatory = $true)]
    [string]$PackageDirectory,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory,

    [string]$Version
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$packageDirectoryPath = (Resolve-Path $PackageDirectory).Path
$workDirectoryPath = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Force -Path $workDirectoryPath | Out-Null

if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml]$build = Get-Content (Join-Path $repositoryRoot "Directory.Build.props")
    $Version = [string]$build.Project.PropertyGroup.Version
}

$toolPath = Join-Path $workDirectoryPath "tool"
$configPath = Join-Path $workDirectoryPath "NuGet.local.config"
$escapedPackageDirectory = [Security.SecurityElement]::Escape($packageDirectoryPath)
$config = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="local-package" value="$escapedPackageDirectory" />
  </packageSources>
</configuration>
"@
[IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))

dotnet tool install DocRefract.Tool `
    --tool-path $toolPath `
    --configfile $configPath `
    --version $Version `
    --no-http-cache
if ($LASTEXITCODE -ne 0) {
    throw "Installing DocRefract.Tool failed with exit code $LASTEXITCODE."
}

$commandName = if ($env:OS -eq "Windows_NT") { "docrefract.exe" } else { "docrefract" }
$command = Join-Path $toolPath $commandName
$fixtures = Join-Path $repositoryRoot "tests/DocRefract.Tests/Fixtures"

$versionOutput = & $command --version
$versionExitCode = $LASTEXITCODE
$reportedVersion = ($versionOutput -join "`n").Trim()
if ($versionExitCode -ne 0) {
    throw "docrefract --version returned $versionExitCode."
}
if ($reportedVersion -ne $Version) {
    throw "docrefract --version reported $reportedVersion; expected $Version."
}

function Invoke-ExpectedExit {
    param(
        [int]$Expected,
        [string]$Label,
        [string[]]$Arguments
    )

    & $command @Arguments
    $actual = $LASTEXITCODE
    if ($actual -ne $Expected) {
        throw "$Label returned $actual; expected $Expected."
    }
}

$noChangeDirectory = Join-Path $workDirectoryPath "no-change"
Invoke-ExpectedExit 0 "no-change comparison" @(
    (Join-Path $fixtures "docx_metadata_before.docx"),
    (Join-Path $fixtures "docx_metadata_after.docx"),
    "--out", $noChangeDirectory,
    "--quiet"
)

$report = Get-Content (Join-Path $noChangeDirectory "diff.json") -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ([string]$report.engine.toolVersion -ne $Version) {
    throw "diff.json reported tool version $($report.engine.toolVersion); expected $Version."
}

Invoke-ExpectedExit 0 "allowed format comparison" @(
    (Join-Path $fixtures "docx_style_before.docx"),
    (Join-Path $fixtures "docx_style_after.docx"),
    "--out", (Join-Path $workDirectoryPath "allowed-format"),
    "--fail-on", "content",
    "--quiet"
)

Invoke-ExpectedExit 1 "prohibited content comparison" @(
    (Join-Path $fixtures "docx_text_before.docx"),
    (Join-Path $fixtures "docx_text_after.docx"),
    "--out", (Join-Path $workDirectoryPath "blocked-content"),
    "--quiet"
)

Invoke-ExpectedExit 2 "missing-input comparison" @(
    (Join-Path $fixtures "missing.docx"),
    (Join-Path $fixtures "docx_text_after.docx"),
    "--out", (Join-Path $workDirectoryPath "missing-input"),
    "--quiet"
)

Write-Host "Installed-tool smoke contract passed for $Version (version, report metadata, and exit codes 0, 1, and 2)."
exit 0
