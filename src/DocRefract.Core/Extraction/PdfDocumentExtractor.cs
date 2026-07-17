using System.Globalization;
using DocRefract.Core.Model;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.DocumentLayoutAnalysis;
using UglyToad.PdfPig.DocumentLayoutAnalysis.PageSegmenter;
using UglyToad.PdfPig.DocumentLayoutAnalysis.ReadingOrderDetector;
using UglyToad.PdfPig.DocumentLayoutAnalysis.WordExtractor;
using UglyToad.PdfPig.Graphics.Colors;

namespace DocRefract.Core.Extraction;

internal sealed class PdfDocumentExtractor : IDocumentExtractor
{
    private const int MaxPages = 5_000;
    private const int MaxLettersPerPage = 500_000;
    private const int MaxWordsPerPage = 250_000;
    private const int MaxImagesPerPage = 10_000;
    private const long MaxTotalLetters = 5_000_000;
    private const long MaxTotalImageBytes = 128L * 1024 * 1024;

    public DocumentSnapshot Extract(string path)
    {
        ExtractionUtilities.PreflightFile(path);

        try
        {
            var nodes = new BoundedNodeCollector();
            var warnings = new SortedSet<string>(StringComparer.Ordinal);
            long totalLetters = 0;
            long totalImageBytes = 0;

            using var document = PdfDocument.Open(path);
            if (document.NumberOfPages > MaxPages)
            {
                throw new DocumentProcessingException(
                    $"PDF contains more than {MaxPages:N0} pages.");
            }

            foreach (var page in document.GetPages())
            {
                ExtractPage(page, nodes, warnings, ref totalLetters, ref totalImageBytes);
            }

            return new DocumentSnapshot
            {
                Kind = DocumentKind.Pdf,
                SourceHash = ExtractionUtilities.ComputeSha256(path),
                Extractor = "pdfpig-0.1.15",
                Nodes = nodes.Items,
                Warnings = warnings.ToArray(),
            };
        }
        catch (DocumentProcessingException)
        {
            throw;
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            throw new DocumentProcessingException(
                "The PDF could not be parsed. It may be malformed or password-protected.",
                exception);
        }
    }

    private static void ExtractPage(
        Page page,
        ICollection<DocumentNode> nodes,
        ISet<string> warnings,
        ref long totalLetters,
        ref long totalImageBytes)
    {
        var pageAnchor = $"page[{page.Number:D4}]";
        nodes.Add(new DocumentNode
        {
            Anchor = pageAnchor,
            Kind = NodeKind.Section,
            Page = page.Number,
            Box = new BoundingBox(
                0,
                0,
                Round(page.Width),
                Round(page.Height)),
        });

        var letters = page.Letters;
        if (letters.Count > MaxLettersPerPage)
        {
            throw new DocumentProcessingException(
                $"PDF page {page.Number} exceeds the {MaxLettersPerPage:N0}-letter extraction limit.");
        }

        totalLetters = checked(totalLetters + letters.Count);
        if (totalLetters > MaxTotalLetters)
        {
            throw new DocumentProcessingException(
                $"PDF exceeds the {MaxTotalLetters:N0}-letter extraction limit.");
        }

        var words = NearestNeighbourWordExtractor.Instance
            .GetWords(letters)
            .Take(MaxWordsPerPage + 1)
            .ToArray();
        if (words.Length > MaxWordsPerPage)
        {
            throw new DocumentProcessingException(
                $"PDF page {page.Number} exceeds the {MaxWordsPerPage:N0}-word extraction limit.");
        }

        if (words.Length > 0)
        {
            var blocks = DocstrumBoundingBoxes.Instance.GetBlocks(words);
            var orderedBlocks = UnsupervisedReadingOrderDetector.Instance.Get(blocks).ToArray();

            for (var index = 0; index < orderedBlocks.Length; index++)
            {
                var block = orderedBlocks[index];
                nodes.Add(new DocumentNode
                {
                    Anchor = $"{pageAnchor}/block[{index + 1:D4}]",
                    Kind = NodeKind.Paragraph,
                    Text = ExtractionUtilities.NormalizeText(block.Text),
                    Style = BlockStyleSignature(block),
                    Box = ToTopLeftBox(block.BoundingBox, page.Height),
                    Page = page.Number,
                });
            }
        }

        var images = page.GetImages().Take(MaxImagesPerPage + 1).ToArray();
        if (images.Length > MaxImagesPerPage)
        {
            throw new DocumentProcessingException(
                $"PDF page {page.Number} exceeds the {MaxImagesPerPage:N0}-image extraction limit.");
        }

        for (var index = 0; index < images.Length; index++)
        {
            var image = images[index];
            totalImageBytes = checked(totalImageBytes + image.RawMemory.Length);
            if (totalImageBytes > MaxTotalImageBytes)
            {
                throw new DocumentProcessingException(
                    $"PDF image data exceeds the {MaxTotalImageBytes / 1024 / 1024} MiB extraction limit.");
            }

            nodes.Add(new DocumentNode
            {
                Anchor = $"{pageAnchor}/image[{index + 1:D4}]",
                Kind = NodeKind.Image,
                MediaHash = ExtractionUtilities.ComputeSha256(image.RawMemory.Span),
                Box = ToTopLeftBox(image.BoundingBox, page.Height),
                Page = page.Number,
            });
        }

        if (words.Length == 0 && images.Length > 0)
        {
            warnings.Add(
                $"Page {page.Number} has no extractable text; image changes are reported as media changes (OCR is disabled).");
        }
    }

    private static string BlockStyleSignature(TextBlock block)
    {
        var spans = new List<PdfStyleSpan>();
        foreach (var letter in block.TextLines
                     .SelectMany(line => line.Words)
                     .SelectMany(word => word.Letters))
        {
            var signature = LetterStyleSignature(letter);
            var length = Math.Max(1, letter.Value.Length);
            if (spans.Count > 0 && string.Equals(spans[^1].Signature, signature, StringComparison.Ordinal))
            {
                spans[^1] = spans[^1] with { Length = spans[^1].Length + length };
            }
            else
            {
                spans.Add(new PdfStyleSpan(length, signature));
            }
        }

        return spans.Count switch
        {
            0 => string.Empty,
            1 => "*:" + spans[0].Signature,
            _ => string.Join(',', spans.Select(span => $"{span.Length}:{span.Signature}")),
        };
    }

    private static string LetterStyleSignature(Letter letter) => string.Join(';', new[]
    {
        $"font={NormalizeFontName(letter.FontName)}",
        $"size={Round(letter.FontSize).ToString(CultureInfo.InvariantCulture)}",
        $"mode={letter.RenderingMode}",
        $"fill={ColorSignature(letter.FillColor)}",
        $"stroke={ColorSignature(letter.StrokeColor)}",
    });

    private static string NormalizeFontName(string? fontName)
    {
        if (fontName is { Length: > 7 } && fontName[6] == '+' &&
            fontName.Take(6).All(character => character is >= 'A' and <= 'Z'))
        {
            return fontName[7..];
        }

        return fontName ?? string.Empty;
    }

    private static string ColorSignature(IColor? color)
    {
        if (color is null)
        {
            return string.Empty;
        }

        var (red, green, blue) = color.ToRGBValues();
        return string.Join('/', new[]
        {
            color.ColorSpace.ToString(),
            Round(red).ToString(CultureInfo.InvariantCulture),
            Round(green).ToString(CultureInfo.InvariantCulture),
            Round(blue).ToString(CultureInfo.InvariantCulture),
        });
    }

    private static BoundingBox ToTopLeftBox(PdfRectangle rectangle, double pageHeight)
    {
        var left = Math.Min(rectangle.Left, rectangle.Right);
        var right = Math.Max(rectangle.Left, rectangle.Right);
        var bottom = Math.Min(rectangle.Bottom, rectangle.Top);
        var top = Math.Max(rectangle.Bottom, rectangle.Top);
        return new BoundingBox(
            Round(left),
            Round(pageHeight - top),
            Round(right - left),
            Round(top - bottom));
    }

    private static decimal Round(double value) =>
        decimal.Round((decimal)value, 3, MidpointRounding.AwayFromZero);

    private sealed record PdfStyleSpan(int Length, string Signature);
}
