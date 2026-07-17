using DocRefract.Core.Model;

namespace DocRefract.Core.Extraction;

internal static class DocumentExtractorFactory
{
    public static (DocumentKind Kind, IDocumentExtractor Extractor) ForPath(string path)
    {
        var extension = Path.GetExtension(path).ToLowerInvariant();

        return extension switch
        {
            ".pdf" => (DocumentKind.Pdf, new PdfDocumentExtractor()),
            ".docx" => (DocumentKind.Docx, new DocxDocumentExtractor()),
            _ => throw new DocumentProcessingException(
                $"Unsupported document type '{extension}'. Use two PDF files or two DOCX files."),
        };
    }

    public static void EnsureSameKind(DocumentKind before, DocumentKind after)
    {
        if (before != after)
        {
            throw new DocumentProcessingException("Cross-format comparisons are not supported in v0.1.");
        }
    }
}
