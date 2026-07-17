using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace DocRefract.Core.Extraction;

internal static class ExtractionUtilities
{
    private const long MaxInputBytes = 128L * 1024 * 1024;
    private const long MaxUncompressedBytes = 256L * 1024 * 1024;
    private const int MaxArchiveEntries = 10_000;
    private const decimal MaxCompressionRatio = 1_000m;

    public static string ComputeSha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    public static string ComputeSha256(ReadOnlySpan<byte> bytes) =>
        Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static void PreflightFile(string path)
    {
        if (!File.Exists(path))
        {
            throw new DocumentProcessingException($"Input file was not found: {path}");
        }

        var info = new FileInfo(path);
        if (info.Length == 0)
        {
            throw new DocumentProcessingException($"Input file is empty: {path}");
        }

        if (info.Length > MaxInputBytes)
        {
            throw new DocumentProcessingException(
                $"Input exceeds the {MaxInputBytes / 1024 / 1024} MiB safety limit: {path}");
        }
    }

    public static void PreflightOpenXmlPackage(string path)
    {
        PreflightFile(path);

        try
        {
            using var archive = ZipFile.OpenRead(path);
            if (archive.Entries.Count > MaxArchiveEntries)
            {
                throw new DocumentProcessingException(
                    $"DOCX contains more than {MaxArchiveEntries} package entries.");
            }

            long totalUncompressed = 0;
            foreach (var entry in archive.Entries)
            {
                totalUncompressed = checked(totalUncompressed + entry.Length);
                if (totalUncompressed > MaxUncompressedBytes)
                {
                    throw new DocumentProcessingException(
                        $"DOCX expands beyond the {MaxUncompressedBytes / 1024 / 1024} MiB safety limit.");
                }

                if (entry.Length > 1_048_576 && entry.CompressedLength == 0)
                {
                    throw new DocumentProcessingException("DOCX contains a suspicious zero-length compressed entry.");
                }

                if (entry.CompressedLength > 0 &&
                    (decimal)entry.Length / entry.CompressedLength > MaxCompressionRatio)
                {
                    throw new DocumentProcessingException("DOCX contains a suspicious compression ratio.");
                }

                var segments = entry.FullName.Replace('\\', '/').Split('/');
                if (entry.FullName.StartsWith('/') || segments.Contains("..", StringComparer.Ordinal))
                {
                    throw new DocumentProcessingException("DOCX contains an unsafe package path.");
                }
            }
        }
        catch (DocumentProcessingException)
        {
            throw;
        }
        catch (Exception exception) when (exception is InvalidDataException or IOException or OverflowException)
        {
            throw new DocumentProcessingException("The DOCX package is malformed or unreadable.", exception);
        }
    }

    public static string NormalizeText(string value, bool preserveExplicitControls = false)
    {
        var normalized = value
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Normalize(NormalizationForm.FormC);
        var builder = new StringBuilder(normalized.Length);
        var pendingSpace = false;

        foreach (var character in normalized)
        {
            if (preserveExplicitControls && character is '\t' or '\n')
            {
                pendingSpace = false;
                if (builder.Length > 0 && builder[^1] == ' ')
                {
                    builder.Length--;
                }

                builder.Append(character);
                continue;
            }

            if (char.IsWhiteSpace(character) || character == '\u00a0')
            {
                pendingSpace = builder.Length > 0;
                continue;
            }

            if (pendingSpace)
            {
                builder.Append(' ');
                pendingSpace = false;
            }

            builder.Append(character);
        }

        return builder.ToString();
    }

    public static decimal Round(decimal value) => Math.Round(value, 2, MidpointRounding.AwayFromZero);
}
