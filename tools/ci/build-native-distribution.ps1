param(
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
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory,

    [string]$DotnetPath = "dotnet"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($Version -notmatch "^[0-9]+[.][0-9]+[.][0-9]+$") {
    throw "Version must be a stable semantic version."
}

$contracts = @{
    "linux-x64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::Linux
        Architecture = [Runtime.InteropServices.Architecture]::X64
        Executable = "docrefract"
        Extension = ".tar.gz"
    }
    "linux-arm64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::Linux
        Architecture = [Runtime.InteropServices.Architecture]::Arm64
        Executable = "docrefract"
        Extension = ".tar.gz"
    }
    "osx-x64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::OSX
        Architecture = [Runtime.InteropServices.Architecture]::X64
        Executable = "docrefract"
        Extension = ".tar.gz"
    }
    "osx-arm64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::OSX
        Architecture = [Runtime.InteropServices.Architecture]::Arm64
        Executable = "docrefract"
        Extension = ".tar.gz"
    }
    "win-x64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::Windows
        Architecture = [Runtime.InteropServices.Architecture]::X64
        Executable = "docrefract.exe"
        Extension = ".zip"
    }
    "win-arm64" = @{
        OS = [Runtime.InteropServices.OSPlatform]::Windows
        Architecture = [Runtime.InteropServices.Architecture]::Arm64
        Executable = "docrefract.exe"
        Extension = ".zip"
    }
}

function Get-SortedDistributionItems {
    param([Parameter(Mandatory = $true)][string]$Root)

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force |
            Sort-Object {
                $_.FullName.Substring($Root.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ).Replace([IO.Path]::DirectorySeparatorChar, "/")
            }
    )
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixedTimestamp = [DateTimeOffset]::new(
        1980,
        1,
        1,
        0,
        0,
        0,
        [TimeSpan]::Zero
    )
    $fileStream = [IO.File]::Open(
        $Destination,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $rootEntry = $archive.CreateEntry("$RootName/")
            $rootEntry.LastWriteTime = $fixedTimestamp
            foreach ($item in Get-SortedDistributionItems -Root $SourceRoot) {
                $relative = $item.FullName.Substring($SourceRoot.Length).TrimStart(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar
                ).Replace([IO.Path]::DirectorySeparatorChar, "/")
                $entryName = "$RootName/$relative"
                if ($item.PSIsContainer) {
                    $entry = $archive.CreateEntry("$entryName/")
                    $entry.LastWriteTime = $fixedTimestamp
                    continue
                }

                $entry = $archive.CreateEntry(
                    $entryName,
                    [IO.Compression.CompressionLevel]::Optimal
                )
                $entry.LastWriteTime = $fixedTimestamp
                $input = [IO.File]::OpenRead($item.FullName)
                try {
                    $entryStream = $entry.Open()
                    try {
                        $input.CopyTo($entryStream)
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
                finally {
                    $input.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function New-DeterministicTarGzip {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ScratchDirectory
    )

    $tar = (
        Get-Command tar -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    ).Source
    $gzip = (
        Get-Command gzip -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    ).Source
    $nonce = [Guid]::NewGuid().ToString("N")
    $listPath = Join-Path $ScratchDirectory "tar-entries-$nonce.txt"
    $temporaryTar = Join-Path $ScratchDirectory "archive-$nonce.tar"
    $compressedTar = "$temporaryTar.gz"
    $entries = [Collections.Generic.List[string]]::new()
    $entries.Add($RootName)
    foreach ($item in Get-SortedDistributionItems -Root $SourceRoot) {
        $relative = $item.FullName.Substring($SourceRoot.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        ).Replace([IO.Path]::DirectorySeparatorChar, "/")
        $entries.Add("$RootName/$relative")
    }
    [IO.File]::WriteAllLines($listPath, $entries, [Text.UTF8Encoding]::new($false))

    try {
        $versionText = @(& $tar --version 2>$null)
        $arguments = [Collections.Generic.List[string]]::new()
        $arguments.Add("-cf")
        $arguments.Add($temporaryTar)
        $arguments.Add("-C")
        $arguments.Add((Split-Path -Parent $SourceRoot))
        $arguments.Add("--no-recursion")
        $arguments.Add("--format=ustar")
        if (($versionText -join "`n") -match "GNU tar") {
            $arguments.Add("--sort=name")
            $arguments.Add("--mtime=2000-01-01T00:00:00Z")
            $arguments.Add("--owner=0")
            $arguments.Add("--group=0")
            $arguments.Add("--numeric-owner")
        }
        else {
            $arguments.Add("--uid=0")
            $arguments.Add("--gid=0")
            $arguments.Add("--uname=root")
            $arguments.Add("--gname=root")
            $arguments.Add("--no-mac-metadata")
            $arguments.Add("--no-xattrs")
            $arguments.Add("--no-acls")
            $arguments.Add("--no-fflags")
        }
        $arguments.Add("-T")
        $arguments.Add($listPath)

        & $tar @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Creating deterministic tar archive failed with exit code $LASTEXITCODE."
        }

        & $gzip -n -f $temporaryTar | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Creating deterministic gzip stream failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath $compressedTar -PathType Leaf)) {
            throw "gzip did not create the expected compressed tar archive."
        }
        Move-Item -LiteralPath $compressedTar -Destination $Destination

        $header = [IO.File]::ReadAllBytes($Destination)
        if (
            $header.Length -lt 10 -or
            $header[0] -ne 0x1f -or
            $header[1] -ne 0x8b -or
            $header[4] -ne 0 -or
            $header[5] -ne 0 -or
            $header[6] -ne 0 -or
            $header[7] -ne 0
        ) {
            throw "gzip header must use an all-zero modification timestamp."
        }
    }
    finally {
        foreach ($temporaryPath in @($listPath, $temporaryTar, $compressedTar)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}
function New-DistributionArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$RootName,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ScratchDirectory
    )

    if ($Extension -eq ".zip") {
        New-DeterministicZip `
            -SourceRoot $SourceRoot `
            -RootName $RootName `
            -Destination $Destination
        return
    }

    New-DeterministicTarGzip `
        -SourceRoot $SourceRoot `
        -RootName $RootName `
        -Destination $Destination `
        -ScratchDirectory $ScratchDirectory
}

function Expand-DistributionArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Extension,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination | Out-Null
    if ($Extension -eq ".zip") {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
        return
    }

    $tar = (
        Get-Command tar -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
    ).Source
    & $tar -xzf $Archive -C $Destination | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Extracting native archive failed with exit code $LASTEXITCODE."
    }
}

function Invoke-ExpectedExitCode {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$Expected,
        [Parameter(Mandatory = $true)][string]$Contract
    )

    & $Executable @Arguments | Out-Host
    $actual = $LASTEXITCODE
    if ($actual -ne $Expected) {
        throw "$Contract returned $actual; expected $Expected."
    }
}

$contract = $contracts[$RuntimeIdentifier]
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform($contract.OS)) {
    throw "Runner OS does not match runtime identifier $RuntimeIdentifier."
}
if (
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne
    $contract.Architecture
) {
    throw "Runner architecture does not match runtime identifier $RuntimeIdentifier."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) {
    throw "Native distribution work directory already exists: $work"
}

New-Item -ItemType Directory -Path $work | Out-Null
New-Item -ItemType Directory -Force -Path $output | Out-Null

$publish = Join-Path $work "publish"
$rootName = "docrefract-$Version-$RuntimeIdentifier"
$distributionRoot = Join-Path $work $rootName
New-Item -ItemType Directory -Path $distributionRoot | Out-Null

$project = Join-Path $repositoryRoot "src/DocRefract.Cli/DocRefract.Cli.csproj"
& $DotnetPath publish $project `
    --configuration Release `
    --framework net10.0 `
    --runtime $RuntimeIdentifier `
    --self-contained true `
    --no-restore `
    --output $publish `
    "-p:Version=$Version" `
    "-p:PublishSingleFile=false" `
    "-p:PublishTrimmed=false" `
    "-p:DebugType=None" `
    "-p:DebugSymbols=false" | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Publishing $RuntimeIdentifier failed with exit code $LASTEXITCODE."
}

$publishedExecutable = Join-Path $publish $contract.Executable
if (-not (Test-Path -LiteralPath $publishedExecutable -PathType Leaf)) {
    throw "Publish output is missing $($contract.Executable)."
}

Get-ChildItem -LiteralPath $publish -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $distributionRoot -Recurse
}
Copy-Item -LiteralPath (Join-Path $repositoryRoot "README.md") -Destination $distributionRoot
Copy-Item -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Destination $distributionRoot
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot "docs/THIRD_PARTY_NOTICES.md") `
    -Destination $distributionRoot
Copy-Item `
    -LiteralPath (Join-Path $repositoryRoot "docs/licenses") `
    -Destination $distributionRoot `
    -Recurse
[IO.File]::WriteAllText(
    (Join-Path $distributionRoot "VERSION"),
    "$Version`n",
    [Text.UTF8Encoding]::new($false)
)

$normalizedTimestamp = [datetime]::new(
    2000,
    1,
    1,
    0,
    0,
    0,
    [DateTimeKind]::Utc
)
Get-ChildItem -LiteralPath $distributionRoot -Recurse -Force | ForEach-Object {
    $_.LastWriteTimeUtc = $normalizedTimestamp
}
(Get-Item -LiteralPath $distributionRoot).LastWriteTimeUtc = $normalizedTimestamp

$archiveName = "$rootName$($contract.Extension)"
$archive = Join-Path $output $archiveName
if (Test-Path -LiteralPath $archive) {
    throw "Native distribution archive already exists: $archive"
}

$firstArchive = Join-Path $work "archive-first$($contract.Extension)"
$secondArchive = Join-Path $work "archive-second$($contract.Extension)"
New-DistributionArchive `
    -SourceRoot $distributionRoot `
    -RootName $rootName `
    -Extension $contract.Extension `
    -Destination $firstArchive `
    -ScratchDirectory $work
New-DistributionArchive `
    -SourceRoot $distributionRoot `
    -RootName $rootName `
    -Extension $contract.Extension `
    -Destination $secondArchive `
    -ScratchDirectory $work
$firstHash = (Get-FileHash -LiteralPath $firstArchive -Algorithm SHA256).Hash
$secondHash = (Get-FileHash -LiteralPath $secondArchive -Algorithm SHA256).Hash
if ($firstHash -cne $secondHash) {
    throw "Packaging $RuntimeIdentifier twice produced different SHA-256 digests."
}
Move-Item -LiteralPath $firstArchive -Destination $archive
Remove-Item -LiteralPath $secondArchive -Force

$extractionDirectory = Join-Path $work "clean-extract"
Expand-DistributionArchive `
    -Archive $archive `
    -Extension $contract.Extension `
    -Destination $extractionDirectory
$topLevelItems = @(Get-ChildItem -LiteralPath $extractionDirectory -Force)
if (
    $topLevelItems.Count -ne 1 -or
    -not $topLevelItems[0].PSIsContainer -or
    $topLevelItems[0].Name -cne $rootName
) {
    throw "Native archive must contain exactly one top-level directory named $rootName."
}
$extractedRoot = $topLevelItems[0].FullName
$extractedExecutable = Join-Path $extractedRoot $contract.Executable
if (-not (Test-Path -LiteralPath $extractedExecutable -PathType Leaf)) {
    throw "Extracted native distribution is missing $($contract.Executable)."
}
if ($contract.Extension -ne ".zip") {
    $mode = [IO.File]::GetUnixFileMode($extractedExecutable)
    if (($mode -band [IO.UnixFileMode]::UserExecute) -eq 0) {
        throw "Extracted native executable is missing its user execute bit."
    }
}

$runtimeVariables = @(
    "DOTNET_ROOT",
    "DOTNET_ROOT_X64",
    "DOTNET_ROOT_ARM64",
    "DOTNET_MULTILEVEL_LOOKUP"
)
$previousRuntimeValues = @{}
foreach ($name in $runtimeVariables) {
    $previousRuntimeValues[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        [EnvironmentVariableTarget]::Process
    )
}
$missingRuntime = Join-Path $work "runtime-that-does-not-exist"
try {
    foreach ($name in @("DOTNET_ROOT", "DOTNET_ROOT_X64", "DOTNET_ROOT_ARM64")) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $missingRuntime,
            [EnvironmentVariableTarget]::Process
        )
    }
    [Environment]::SetEnvironmentVariable(
        "DOTNET_MULTILEVEL_LOOKUP",
        "0",
        [EnvironmentVariableTarget]::Process
    )

    $reportedVersion = @(& $extractedExecutable --version)
    if ($LASTEXITCODE -ne 0) {
        throw "Native $RuntimeIdentifier --version returned $LASTEXITCODE."
    }
    if (($reportedVersion -join "`n").Trim() -ne $Version) {
        throw "Native $RuntimeIdentifier reported the wrong version."
    }

    $demoReport = Join-Path $work "demo-report"
    $demoOutput = @(& $extractedExecutable demo --out $demoReport)
    if ($LASTEXITCODE -ne 0) {
        throw "Native $RuntimeIdentifier demo returned $LASTEXITCODE."
    }
    $demoOutput | ForEach-Object { Write-Host $_ }
    foreach ($name in @("index.html", "diff.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $demoReport $name) -PathType Leaf)) {
            throw "Native $RuntimeIdentifier demo did not produce $name."
        }
    }
    $demoJson = Get-Content -LiteralPath (Join-Path $demoReport "diff.json") -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if ($demoJson.engine.toolVersion -ne $Version) {
        throw "Native $RuntimeIdentifier demo report contains the wrong toolVersion."
    }

    $fixtures = Join-Path $repositoryRoot "tests/DocRefract.Tests/Fixtures"
    Invoke-ExpectedExitCode `
        -Executable $extractedExecutable `
        -Arguments @(
            (Join-Path $fixtures "docx_metadata_before.docx"),
            (Join-Path $fixtures "docx_metadata_after.docx"),
            "--out", (Join-Path $work "metadata-no-change"),
            "--fail-on", "any",
            "--quiet"
        ) `
        -Expected 0 `
        -Contract "Metadata-only comparison"
    Invoke-ExpectedExitCode `
        -Executable $extractedExecutable `
        -Arguments @(
            (Join-Path $fixtures "docx_style_before.docx"),
            (Join-Path $fixtures "docx_style_after.docx"),
            "--out", (Join-Path $work "allowed-format"),
            "--fail-on", "content",
            "--quiet"
        ) `
        -Expected 0 `
        -Contract "Allowed formatting comparison"
    Invoke-ExpectedExitCode `
        -Executable $extractedExecutable `
        -Arguments @(
            (Join-Path $fixtures "docx_text_before.docx"),
            (Join-Path $fixtures "docx_text_after.docx"),
            "--out", (Join-Path $work "blocked-content"),
            "--fail-on", "content",
            "--quiet"
        ) `
        -Expected 1 `
        -Contract "Prohibited content comparison"
    Invoke-ExpectedExitCode `
        -Executable $extractedExecutable `
        -Arguments @(
            (Join-Path $fixtures "missing.docx"),
            (Join-Path $fixtures "docx_text_after.docx"),
            "--out", (Join-Path $work "missing-input"),
            "--quiet"
        ) `
        -Expected 2 `
        -Contract "Missing input comparison"
}
finally {
    foreach ($name in $runtimeVariables) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $previousRuntimeValues[$name],
            [EnvironmentVariableTarget]::Process
        )
    }
}

$global:LASTEXITCODE = 0
Write-Host "Built, determinism-checked, clean-extracted, and smoked $archiveName."
Write-Output $archive