using DocRefract.Core.Model;

namespace DocRefract.Core.Extraction;

internal interface IDocumentExtractor
{
    DocumentSnapshot Extract(string path);
}
