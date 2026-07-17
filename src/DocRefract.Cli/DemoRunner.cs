using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using DocRefract.Core;
using DocRefract.Core.Reporting;

namespace DocRefract.Cli;

internal sealed record DemoResult
{
    public required ComparisonResult Comparison { get; init; }

    public required string BeforePath { get; init; }

    public required string AfterPath { get; init; }

    public required string JsonPath { get; init; }

    public required string HtmlPath { get; init; }
}

internal static class DemoRunner
{
    private const string BeforeFileName = "before.docx";
    private const string AfterFileName = "after.docx";
    private const string JsonFileName = "diff.json";
    private const string HtmlFileName = "index.html";

    private static readonly string[] PublishedFileNames =
    [
        BeforeFileName,
        AfterFileName,
        JsonFileName,
        HtmlFileName,
    ];

    public static DemoResult Run(string outputDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDirectory);

        var fullOutputDirectory = Path.GetFullPath(outputDirectory);
        Directory.CreateDirectory(fullOutputDirectory);
        EnsurePublishTargetsAreSafe(fullOutputDirectory);

        var stagingDirectory = CreateStagingDirectory(fullOutputDirectory);
        try
        {
            var stagedBeforePath = Path.Combine(stagingDirectory, BeforeFileName);
            var stagedAfterPath = Path.Combine(stagingDirectory, AfterFileName);
            DemoDocumentWriter.Write(stagedBeforePath, DemoDocumentKind.Before);
            DemoDocumentWriter.Write(stagedAfterPath, DemoDocumentKind.After);

            IComparisonService comparisonService = new ComparisonService();
            var comparison = comparisonService.Compare(stagedBeforePath, stagedAfterPath);
            IReportWriter reportWriter = new OfflineReportWriter();
            var artifacts = reportWriter.Write(comparison.Report, stagingDirectory);
            if (artifacts.HtmlPath is null)
            {
                throw new InvalidOperationException("The demo HTML report was not generated.");
            }

            foreach (var fileName in PublishedFileNames)
            {
                File.Move(
                    Path.Combine(stagingDirectory, fileName),
                    Path.Combine(fullOutputDirectory, fileName),
                    overwrite: true);
            }

            return new DemoResult
            {
                Comparison = comparison,
                BeforePath = Path.Combine(fullOutputDirectory, BeforeFileName),
                AfterPath = Path.Combine(fullOutputDirectory, AfterFileName),
                JsonPath = Path.Combine(fullOutputDirectory, JsonFileName),
                HtmlPath = Path.Combine(fullOutputDirectory, HtmlFileName),
            };
        }
        finally
        {
            TryDeleteDirectory(stagingDirectory);
        }
    }

    private static void EnsurePublishTargetsAreSafe(string outputDirectory)
    {
        foreach (var fileName in PublishedFileNames)
        {
            var path = Path.Combine(outputDirectory, fileName);
            if (Directory.Exists(path))
            {
                throw new IOException(
                    $"Demo output '{fileName}' is an existing directory and will not be replaced.");
            }

            if (!File.Exists(path))
            {
                continue;
            }

            var attributes = File.GetAttributes(path);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException(
                    $"Demo output '{fileName}' is a symbolic link and will not be replaced.");
            }

            if ((attributes & FileAttributes.ReadOnly) != 0)
            {
                throw new IOException(
                    $"Demo output '{fileName}' is read-only and will not be replaced.");
            }
        }
    }

    private static string CreateStagingDirectory(string outputDirectory)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            var candidate = Path.Combine(
                outputDirectory,
                $".docrefract-demo-{RandomNumberGenerator.GetHexString(16)}.tmp");
            try
            {
                Directory.CreateDirectory(candidate);
                return candidate;
            }
            catch (IOException) when (Directory.Exists(candidate))
            {
                // Try another cryptographically random name.
            }
        }

        throw new IOException("Could not create a unique demo staging directory.");
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (IOException)
        {
            // A completed demo must not become a failure because temporary cleanup was blocked.
        }
        catch (UnauthorizedAccessException)
        {
            // A completed demo must not become a failure because temporary cleanup was blocked.
        }
    }
}

internal enum DemoDocumentKind
{
    Before,
    After,
}

internal static class DemoDocumentWriter
{
    private static readonly UTF8Encoding Utf8WithoutBom =
        new(encoderShouldEmitUTF8Identifier: false);

    private static readonly DateTimeOffset FixedEntryTimestamp =
        new(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private const string ContentTypesXml =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """;

    private const string PackageRelationshipsXml =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """;

    private const string BeforeDocumentXml =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Quarterly invoice</w:t></w:r></w:p>
            <w:p><w:r><w:t>Invoice total: USD 1,200</w:t></w:r></w:p>
            <w:p><w:r><w:t>Payment due in 30 days.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Generated by the sample pipeline.</w:t></w:r></w:p>
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
          </w:body>
        </w:document>
        """;

    private const string AfterDocumentXml =
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Quarterly invoice</w:t></w:r></w:p>
            <w:p><w:r><w:t>Invoice total: USD 1,275</w:t></w:r></w:p>
            <w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Payment due in 30 days.</w:t></w:r></w:p>
            <w:p><w:r><w:t>Generated by the sample pipeline.</w:t><w:br w:type="page"/></w:r></w:p>
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
          </w:body>
        </w:document>
        """;

    public static void Write(string path, DemoDocumentKind kind)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 16_384,
            FileOptions.WriteThrough);
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            WriteEntry(archive, "[Content_Types].xml", ContentTypesXml);
            WriteEntry(archive, "_rels/.rels", PackageRelationshipsXml);
            WriteEntry(
                archive,
                "word/document.xml",
                kind == DemoDocumentKind.Before ? BeforeDocumentXml : AfterDocumentXml);
        }

        stream.Flush(flushToDisk: true);
    }

    private static void WriteEntry(ZipArchive archive, string name, string content)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.NoCompression);
        entry.LastWriteTime = FixedEntryTimestamp;
        using var writer = new StreamWriter(entry.Open(), Utf8WithoutBom);
        writer.NewLine = "\n";
        writer.Write(content);
        writer.Write('\n');
    }
}
