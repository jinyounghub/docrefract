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
    [xml]$project = Get-Content (Join-Path $repositoryRoot "src/DocRefract.Cli/DocRefract.Cli.csproj")
    $Version = [string]$project.Project.PropertyGroup.Version
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

Invoke-ExpectedExit 0 "no-change comparison" @(
    (Join-Path $fixtures "docx_metadata_before.docx"),
    (Join-Path $fixtures "docx_metadata_after.docx"),
    "--out", (Join-Path $workDirectoryPath "no-change"),
    "--quiet"
)

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

Write-Host "Installed-tool smoke contract passed (exit codes 0, 1, and 2)."
