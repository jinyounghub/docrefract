[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Before,

    [Parameter(Mandatory)]
    [string]$After,

    [Parameter(Mandatory)]
    [string]$FailOn,

    [Parameter(Mandatory)]
    [string]$Out,

    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$Source,

    [string]$Sha256 = "",

    [Parameter(Mandatory)]
    [string]$ArtifactName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

function Assert-SingleLineValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0)) {
        throw "$Name must be a single-line value without NUL characters."
    }
}

function Resolve-WorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $workspace = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
        (Get-Location).Path
    }
    else {
        $env:GITHUB_WORKSPACE
    }

    Assert-SingleLineValue -Name "GITHUB_WORKSPACE" -Value $workspace
    return [System.IO.Path]::GetFullPath((Join-Path $workspace $Path))
}

function Write-ActionOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Write-Host "$Name=$Value"
        return
    }

    $delimiter = "DOCREFRACT_$([Guid]::NewGuid().ToString('N'))"
    $entry = "$Name<<$delimiter`n$Value`n$delimiter`n"
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, $entry, $utf8WithoutBom)
}

function Get-SafeUriDisplay {
    param(
        [Parameter(Mandatory)]
        [Uri]$Uri
    )

    return $Uri.GetLeftPart([UriPartial]::Path)
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)]
        [Uri]$Uri,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    if (-not $Uri.Scheme.Equals("https", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Remote downloads require HTTPS."
    }

    $lastError = $null
    foreach ($attempt in 1..3) {
        try {
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                Remove-Item -LiteralPath $Destination -Force
            }

            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $response = Invoke-WebRequest `
                    -Uri $Uri `
                    -OutFile $Destination `
                    -PassThru
                $finalUri = $response.BaseResponse.RequestMessage.RequestUri
                if ($null -ne $finalUri -and
                    -not $finalUri.Scheme.Equals("https", [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Remote download redirected to a non-HTTPS URI."
                }
            }
            else {
                # Windows PowerShell 5.1 can throw a NullReferenceException when
                # -OutFile and -PassThru follow GitHub release redirects.
                Invoke-WebRequest -Uri $Uri -OutFile $Destination
            }

            return
        }
        catch {
            $lastError = $_
            if (Test-Path -LiteralPath $Destination -PathType Leaf) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt 3) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt - 1))
            }
        }
    }

    $displayUri = Get-SafeUriDisplay -Uri $Uri
    throw "Failed to download $displayUri after 3 attempts: $($lastError.Exception.Message)"
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Confirm-PackageHash {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ExpectedHash
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        return
    }

    if ($ExpectedHash -notmatch "^[0-9a-fA-F]{64}$") {
        throw "sha256 must contain exactly 64 hexadecimal characters."
    }

    $actualHash = Get-FileSha256 -Path $PackagePath
    if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
        throw "Package SHA-256 mismatch. Expected $($ExpectedHash.ToLowerInvariant()), got $actualHash."
    }
}

function Test-OfficialReleasePackageUri {
    param(
        [Parameter(Mandatory)]
        [Uri]$PackageUri,

        [Parameter(Mandatory)]
        [string]$PackageVersion
    )

    $expectedPath = "/jinyounghub/docrefract/releases/download/v$PackageVersion/DocRefract.Tool.$PackageVersion.nupkg"
    return (
        $PackageUri.Scheme.Equals("https", [StringComparison]::OrdinalIgnoreCase) -and
        $PackageUri.Host.Equals("github.com", [StringComparison]::OrdinalIgnoreCase) -and
        [string]::IsNullOrEmpty($PackageUri.UserInfo) -and
        [string]::IsNullOrEmpty($PackageUri.Query) -and
        $PackageUri.AbsolutePath.Equals($expectedPath, [StringComparison]::Ordinal)
    )
}

function Get-OfficialReleaseManifestHash {
    param(
        [Parameter(Mandatory)]
        [Uri]$PackageUri,

        [Parameter(Mandatory)]
        [string]$PackageName,

        [Parameter(Mandatory)]
        [string]$DownloadDirectory
    )

    $manifestUri = [Uri]::new($PackageUri, "SHA256SUMS")
    $manifestPath = Join-Path $DownloadDirectory "SHA256SUMS"
    Invoke-Download -Uri $manifestUri -Destination $manifestPath

    $escapedPackageName = [Regex]::Escape($PackageName)
    $matchingLines = @(
        Get-Content -LiteralPath $manifestPath -Encoding UTF8 |
            Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+\*?$escapedPackageName$" }
    )

    if ($matchingLines.Count -ne 1) {
        throw "Release checksum manifest must contain exactly one entry for $PackageName."
    }

    return ([Regex]::Match(
        $matchingLines[0],
        "^([0-9a-fA-F]{64})")).Groups[1].Value.ToLowerInvariant()
}

function New-IsolatedNuGetConfig {
    param(
        [Parameter(Mandatory)]
        [string]$PackageSource,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $escapedSource = [System.Security.SecurityElement]::Escape($PackageSource)
    $content = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="docrefract-action" value="$escapedSource" />
  </packageSources>
</configuration>
"@

    [System.IO.File]::WriteAllText($Destination, $content, $utf8WithoutBom)
}

function Clear-ManagedReportFiles {
    param(
        [Parameter(Mandatory)]
        [string]$ReportDirectory
    )

    foreach ($name in @("diff.json", "action-error.json", "index.html")) {
        $path = Join-Path $ReportDirectory $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Initialize-RequestedReportDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedPath
    )

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        throw "out must not be empty."
    }

    $directory = Resolve-WorkspacePath -Path $RequestedPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Clear-ManagedReportFiles -ReportDirectory $directory
    return $directory
}

function New-ActionTemporaryDirectory {
    $baseDirectories = @($env:RUNNER_TEMP, [System.IO.Path]::GetTempPath())
    $failures = [System.Collections.Generic.List[string]]::new()

    foreach ($baseDirectory in $baseDirectories) {
        if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
            continue
        }

        try {
            Assert-SingleLineValue -Name "temporary directory" -Value $baseDirectory
            $fullBaseDirectory = [System.IO.Path]::GetFullPath($baseDirectory)
            $candidate = Join-Path `
                $fullBaseDirectory `
                "docrefract-action-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $candidate -Force | Out-Null
            return [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
            $failures.Add($_.Exception.Message)
        }
    }

    throw "Could not create an isolated action directory: $($failures -join '; ')"
}

function Remove-ActionTemporaryDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $leaf = [System.IO.Path]::GetFileName($fullPath)
        if ($leaf -notmatch "^docrefract-action-[0-9a-f]{32}$") {
            throw "Refusing to remove unexpected temporary path: $fullPath"
        }

        if (Test-Path -LiteralPath $fullPath -PathType Container) {
            Remove-Item -LiteralPath $fullPath -Recurse -Force
        }
    }
    catch {
        Write-Warning "Could not clean the DocRefract temporary directory: $($_.Exception.Message)"
    }
}

function Write-ErrorArtifacts {
    param(
        [Parameter(Mandatory)]
        [string]$ReportDirectory,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    Clear-ManagedReportFiles -ReportDirectory $ReportDirectory

    $jsonPath = Join-Path $ReportDirectory "action-error.json"
    $htmlPath = Join-Path $ReportDirectory "index.html"
    $errorDocument = [ordered]@{
        tool = "DocRefract"
        actionStatus = "error"
        exitCode = $ExitCode
        message = $Message
    }
    $json = ($errorDocument | ConvertTo-Json -Depth 4) + "`n"
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8WithoutBom)

    $encodedMessage = [System.Net.WebUtility]::HtmlEncode($Message)
    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
  <title>DocRefract action error</title>
  <style>
    body { max-width: 52rem; margin: 3rem auto; padding: 0 1rem; font: 16px/1.6 system-ui, sans-serif; }
    code { overflow-wrap: anywhere; }
  </style>
</head>
<body>
  <h1>DocRefract could not complete the comparison</h1>
  <p>Exit code: <code>$ExitCode</code></p>
  <p><code>$encodedMessage</code></p>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $html, $utf8WithoutBom)

    return [pscustomobject]@{
        ReportDirectory = $ReportDirectory
        JsonPath = $jsonPath
        HtmlPath = $htmlPath
    }
}

function Write-ErrorArtifactsSafely {
    param(
        [AllowNull()]
        [string]$PreferredDirectory,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    $candidateDirectories = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PreferredDirectory)) {
        $candidateDirectories.Add($PreferredDirectory)
    }

    foreach ($baseDirectory in @(
        $env:RUNNER_TEMP,
        [System.IO.Path]::GetTempPath(),
        $env:GITHUB_WORKSPACE
    )) {
        if ([string]::IsNullOrWhiteSpace($baseDirectory)) {
            continue
        }

        try {
            Assert-SingleLineValue -Name "fallback directory" -Value $baseDirectory
            $fullBaseDirectory = [System.IO.Path]::GetFullPath($baseDirectory)
            $candidateDirectories.Add((Join-Path `
                $fullBaseDirectory `
                "docrefract-action-report-$([Guid]::NewGuid().ToString('N'))"))
        }
        catch {
            Write-Warning "Ignoring an invalid fallback directory: $($_.Exception.Message)"
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidateDirectories) {
        if (-not $seen.Add($candidate)) {
            continue
        }

        try {
            return Write-ErrorArtifacts `
                -ReportDirectory $candidate `
                -Message $Message `
                -ExitCode $ExitCode
        }
        catch {
            $failures.Add("${candidate}: $($_.Exception.Message)")
        }
    }

    throw "Could not create DocRefract error artifacts: $($failures -join '; ')"
}

function Write-StepSummary {
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [string]$ReportJsonPath,

        [Parameter(Mandatory)]
        [string]$ReportHtmlPath,

        [Parameter(Mandatory)]
        [string]$Policy,

        [Parameter(Mandatory)]
        [string]$UploadedArtifactName
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        return
    }

    $status = switch ($ExitCode) {
        0 { "PASS" }
        1 { "POLICY FAILED" }
        default { "ERROR" }
    }

    $encodedPolicy = [System.Net.WebUtility]::HtmlEncode($Policy)
    $encodedArtifact = [System.Net.WebUtility]::HtmlEncode($UploadedArtifactName)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## DocRefract · $status")
    $lines.Add("")
    $lines.Add("- Exit code: ``$ExitCode``")
    $lines.Add("- Policy: <code>$encodedPolicy</code>")
    $lines.Add("- Artifact: <code>$encodedArtifact</code>")

    if ([System.IO.Path]::GetFileName($ReportJsonPath) -eq "diff.json") {
        try {
            $report = Get-Content -LiteralPath $ReportJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $summary = $report.summary
            $lines.Add("")
            $lines.Add("| Total | Content | Format | Layout | Media | Visual | Structure |")
            $lines.Add("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
            $lines.Add(
                "| $($summary.total) | $($summary.content) | $($summary.format) | " +
                "$($summary.layout) | $($summary.media) | $($summary.visual) | " +
                "$($summary.structure) |")
        }
        catch {
            $lines.Add("")
            $lines.Add("_The comparison report was created, but its summary could not be parsed._")
        }
    }

    $lines.Add("")
    $encodedHtmlName = [System.Net.WebUtility]::HtmlEncode(
        [System.IO.Path]::GetFileName($ReportHtmlPath))
    $lines.Add("Download the artifact to open <code>$encodedHtmlName</code>.")
    $text = ($lines -join "`n") + "`n"
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $text, $utf8WithoutBom)
}

$exitCode = 2
$failureMessage = "DocRefract could not complete the comparison."
$reportDirectory = $null
$jsonPath = $null
$htmlPath = $null
$actionTempRoot = $null
$safeArtifactName = "docrefract-report"

try {
    $valuesToValidate = [ordered]@{
        before = $Before
        after = $After
        "fail-on" = $FailOn
        out = $Out
        version = $Version
        source = $Source
        sha256 = $Sha256
        "artifact-name" = $ArtifactName
    }
    foreach ($entry in $valuesToValidate.GetEnumerator()) {
        Assert-SingleLineValue -Name $entry.Key -Value $entry.Value
    }

    if ([string]::IsNullOrWhiteSpace($Before) -or [string]::IsNullOrWhiteSpace($After)) {
        throw "before and after must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($FailOn)) {
        throw "fail-on must not be empty."
    }
    if ($Version -notmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$") {
        throw "version must be a three-part semantic version, optionally with a prerelease suffix."
    }
    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "source must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($ArtifactName)) {
        throw "artifact-name must not be empty."
    }
    if ($ArtifactName.IndexOfAny([char[]]'\/:*?"<>|') -ge 0) {
        throw "artifact-name contains a character that GitHub artifacts do not allow."
    }
    $safeArtifactName = $ArtifactName

    $reportDirectory = Initialize-RequestedReportDirectory -RequestedPath $Out
    $jsonPath = Join-Path $reportDirectory "diff.json"
    $htmlPath = Join-Path $reportDirectory "index.html"

    $beforePath = Resolve-WorkspacePath -Path $Before
    $afterPath = Resolve-WorkspacePath -Path $After
    if (-not (Test-Path -LiteralPath $beforePath -PathType Leaf)) {
        throw "Baseline document does not exist: $beforePath"
    }
    if (-not (Test-Path -LiteralPath $afterPath -PathType Leaf)) {
        throw "Candidate document does not exist: $afterPath"
    }

    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $actionTempRoot = New-ActionTemporaryDirectory
    $packageDirectory = Join-Path $actionTempRoot "packages"
    $toolDirectory = Join-Path $actionTempRoot "tool"
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null

    $expandedSource = $Source.Replace("{version}", $Version)
    $sourceUri = $null
    $hasUriScheme = $expandedSource -match "^[A-Za-z][A-Za-z0-9+.-]*://"
    $installSource = ""

    if ($hasUriScheme) {
        if (-not [Uri]::TryCreate($expandedSource, [UriKind]::Absolute, [ref]$sourceUri)) {
            throw "source is not a valid absolute URI."
        }
        if ($sourceUri.Scheme.Equals("http", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Remote package sources require HTTPS; http is not allowed."
        }
        if (-not $sourceUri.Scheme.Equals("https", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unsupported remote package source scheme '$($sourceUri.Scheme)'; use HTTPS or a local path."
        }

        if ($sourceUri.AbsolutePath.EndsWith(
            ".nupkg",
            [StringComparison]::OrdinalIgnoreCase)) {
            $packageName = "DocRefract.Tool.$Version.nupkg"
            $packagePath = Join-Path $packageDirectory $packageName
            $isOfficialRelease = Test-OfficialReleasePackageUri `
                -PackageUri $sourceUri `
                -PackageVersion $Version
            if (-not $isOfficialRelease -and [string]::IsNullOrWhiteSpace($Sha256)) {
                throw "A direct remote nupkg outside the official DocRefract GitHub Release requires sha256."
            }

            Invoke-Download -Uri $sourceUri -Destination $packagePath
            $expectedHash = $Sha256
            if ($isOfficialRelease -and [string]::IsNullOrWhiteSpace($expectedHash)) {
                $expectedHash = Get-OfficialReleaseManifestHash `
                    -PackageUri $sourceUri `
                    -PackageName $packageName `
                    -DownloadDirectory $packageDirectory
            }
            Confirm-PackageHash -PackagePath $packagePath -ExpectedHash $expectedHash
            $installSource = $packageDirectory
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
                throw "sha256 can only be used when source identifies one nupkg."
            }
            $installSource = $expandedSource
        }
    }
    else {
        $localSource = Resolve-WorkspacePath -Path $expandedSource
        if (Test-Path -LiteralPath $localSource -PathType Leaf) {
            if ([System.IO.Path]::GetExtension($localSource) -ne ".nupkg") {
                throw "Local source file must be a .nupkg: $localSource"
            }

            $localPackageName = "DocRefract.Tool.$Version.nupkg"
            $localPackagePath = Join-Path $packageDirectory $localPackageName
            Copy-Item -LiteralPath $localSource -Destination $localPackagePath
            Confirm-PackageHash -PackagePath $localPackagePath -ExpectedHash $Sha256
            $installSource = $packageDirectory
        }
        elseif (Test-Path -LiteralPath $localSource -PathType Container) {
            if (-not [string]::IsNullOrWhiteSpace($Sha256)) {
                throw "sha256 requires source to identify one nupkg, not a package directory."
            }
            $installSource = $localSource
        }
        else {
            throw "Package source does not exist: $localSource"
        }
    }

    $nugetConfigPath = Join-Path $actionTempRoot "NuGet.Config"
    New-IsolatedNuGetConfig -PackageSource $installSource -Destination $nugetConfigPath
    & $dotnet.Source tool install DocRefract.Tool `
        --tool-path $toolDirectory `
        --version $Version `
        --configfile $nugetConfigPath `
        --no-cache
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet tool install failed with exit code $LASTEXITCODE."
    }

    $toolName = if ($env:OS -eq "Windows_NT") { "docrefract.exe" } else { "docrefract" }
    $toolPath = Join-Path $toolDirectory $toolName
    if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
        throw "Installed tool executable was not found: $toolPath"
    }

    & $toolPath $beforePath $afterPath --out $reportDirectory --fail-on $FailOn
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin @(0, 1, 2)) {
        throw "DocRefract returned unsupported exit code $exitCode."
    }
    if ($exitCode -eq 2) {
        $failureMessage = "DocRefract reported a usage, input, or processing error."
    }
    elseif (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $htmlPath -PathType Leaf)) {
        throw "DocRefract did not create both diff.json and index.html."
    }
}
catch {
    $exitCode = 2
    $failureMessage = $_.Exception.Message
    Write-Error $failureMessage -ErrorAction Continue
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($actionTempRoot)) {
        Remove-ActionTemporaryDirectory -Path $actionTempRoot
    }
}

if ($exitCode -eq 2) {
    try {
        $errorArtifacts = Write-ErrorArtifactsSafely `
            -PreferredDirectory $reportDirectory `
            -Message $failureMessage `
            -ExitCode $exitCode
        $reportDirectory = $errorArtifacts.ReportDirectory
        $jsonPath = $errorArtifacts.JsonPath
        $htmlPath = $errorArtifacts.HtmlPath
    }
    catch {
        Write-Warning $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($reportDirectory)) {
            $reportDirectory = ""
        }
        if ([string]::IsNullOrWhiteSpace($jsonPath)) {
            $jsonPath = ""
        }
        if ([string]::IsNullOrWhiteSpace($htmlPath)) {
            $htmlPath = ""
        }
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($jsonPath) -and
        -not [string]::IsNullOrWhiteSpace($htmlPath)) {
        Write-StepSummary `
            -ExitCode $exitCode `
            -ReportJsonPath $jsonPath `
            -ReportHtmlPath $htmlPath `
            -Policy $FailOn `
            -UploadedArtifactName $safeArtifactName
    }
}
catch {
    Write-Warning "Could not write the GitHub step summary: $($_.Exception.Message)"
}

$outputValues = [ordered]@{
    "exit-code" = $exitCode.ToString([Globalization.CultureInfo]::InvariantCulture)
    "report-path" = if ($null -eq $reportDirectory) { "" } else { $reportDirectory }
    "json-path" = if ($null -eq $jsonPath) { "" } else { $jsonPath }
    "html-path" = if ($null -eq $htmlPath) { "" } else { $htmlPath }
    "artifact-name" = $safeArtifactName
}
foreach ($entry in $outputValues.GetEnumerator()) {
    try {
        Write-ActionOutput -Name $entry.Key -Value ([string]$entry.Value)
    }
    catch {
        Write-Warning "Could not write action output '$($entry.Key)': $($_.Exception.Message)"
    }
}

# The composite action uploads artifacts before a final step re-emits this code.
exit 0