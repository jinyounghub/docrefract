param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$package = (Resolve-Path $PackagePath).Path
if ([IO.Path]::GetExtension($package) -cne ".nupkg") {
    throw "PackagePath must identify a .nupkg file."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$temporary = "$package.normalized-$([Guid]::NewGuid().ToString('N')).tmp"
$fixedTimestamp = [DateTimeOffset]::new(
    1980,
    1,
    1,
    0,
    0,
    0,
    [TimeSpan]::Zero
)
$corePrefix = "package/services/metadata/core-properties/"
$canonicalCoreName = "$corePrefix" + "docrefract.psmdcp"

try {
    $source = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        $nuspecEntries = @(
            $source.Entries |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.Name) -and
                    $_.FullName.EndsWith(
                        ".nuspec",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        if ($nuspecEntries.Count -ne 1) {
            throw "Expected exactly one nuspec in $package."
        }

        $coreEntries = @(
            $source.Entries |
                Where-Object {
                    $_.FullName.StartsWith(
                        $corePrefix,
                        [StringComparison]::Ordinal
                    ) -and
                    $_.FullName.EndsWith(
                        ".psmdcp",
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
        )
        if ($coreEntries.Count -ne 1) {
            throw "Expected exactly one NuGet core-properties part."
        }
        if (
            @($source.Entries | Where-Object FullName -eq "_rels/.rels").Count -ne 1 -or
            @($source.Entries | Where-Object FullName -eq "[Content_Types].xml").Count -ne 1
        ) {
            throw "The NuGet package is missing its OPC relationship contract."
        }
        if (
            @(
                $source.Entries |
                    Where-Object {
                        $_.FullName.Equals(
                            ".signature.p7s",
                            [StringComparison]::OrdinalIgnoreCase
                        )
                    }
            ).Count -ne 0
        ) {
            throw "Normalize the package before signing, not after signing."
        }

        $mappedEntries = @(
            $source.Entries | ForEach-Object {
                $mappedName = if ($_.FullName -ceq $coreEntries[0].FullName) {
                    $canonicalCoreName
                }
                else {
                    $_.FullName
                }
                [pscustomobject]@{
                    Source = $_
                    Name = $mappedName
                }
            }
        ) | Sort-Object Name -CaseSensitive

        $seenNames = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::Ordinal
        )
        foreach ($mapped in $mappedEntries) {
            if (-not $seenNames.Add($mapped.Name)) {
                throw "Normalized package would contain duplicate entry $($mapped.Name)."
            }
        }

        $destinationStream = [IO.File]::Open(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $destination = [IO.Compression.ZipArchive]::new(
                $destinationStream,
                [IO.Compression.ZipArchiveMode]::Create,
                $false
            )
            try {
                foreach ($mapped in $mappedEntries) {
                    $entry = $destination.CreateEntry(
                        $mapped.Name,
                        [IO.Compression.CompressionLevel]::Optimal
                    )
                    $entry.LastWriteTime = $fixedTimestamp
                    $entry.ExternalAttributes = 0
                    if ([string]::IsNullOrWhiteSpace($mapped.Source.Name)) {
                        continue
                    }

                    $output = $entry.Open()
                    try {
                        if ($mapped.Name -ceq "_rels/.rels") {
                            $relationships = @"
<?xml version="1.0" encoding="utf-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Type="http://schemas.microsoft.com/packaging/2010/07/manifest" Target="/$($nuspecEntries[0].FullName)" Id="RManifest" />
  <Relationship Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="/$canonicalCoreName" Id="RCoreProperties" />
</Relationships>
"@
                            $bytes = [Text.UTF8Encoding]::new($false).GetBytes(
                                $relationships.Replace("`r`n", "`n") + "`n"
                            )
                            $output.Write($bytes, 0, $bytes.Length)
                        }
                        else {
                            $input = $mapped.Source.Open()
                            try {
                                $input.CopyTo($output)
                            }
                            finally {
                                $input.Dispose()
                            }
                        }
                    }
                    finally {
                        $output.Dispose()
                    }
                }
            }
            finally {
                $destination.Dispose()
            }
        }
        finally {
            $destinationStream.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }

    $normalized = [IO.Compression.ZipFile]::OpenRead($temporary)
    try {
        if (
            @(
                $normalized.Entries |
                    Where-Object FullName -eq $canonicalCoreName
            ).Count -ne 1
        ) {
            throw "Normalized NuGet package is missing canonical core properties."
        }
        foreach ($entry in $normalized.Entries) {
            if (
                $entry.LastWriteTime.Year -ne 1980 -or
                $entry.LastWriteTime.Month -ne 1 -or
                $entry.LastWriteTime.Day -ne 1 -or
                $entry.LastWriteTime.Hour -ne 0 -or
                $entry.LastWriteTime.Minute -ne 0 -or
                $entry.LastWriteTime.Second -ne 0
            ) {
                throw "Normalized NuGet entry timestamp drifted: $($entry.FullName)"
            }
        }
    }
    finally {
        $normalized.Dispose()
    }

    [IO.File]::Copy($temporary, $package, $true)
}
finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}

Write-Host "Normalized NuGet OPC identities, entry order, and timestamps."
Write-Output $package
