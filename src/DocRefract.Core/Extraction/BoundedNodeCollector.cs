using System.Collections;
using DocRefract.Core.Model;

namespace DocRefract.Core.Extraction;

internal sealed class BoundedNodeCollector : ICollection<DocumentNode>
{
    private const int MaxNodes = 25_000;
    private const long MaxEvidenceCharacters = 20_000_000;
    private readonly List<DocumentNode> _items = [];
    private long _evidenceCharacters;

    public IReadOnlyList<DocumentNode> Items => _items;

    public int Count => _items.Count;

    public bool IsReadOnly => false;

    public void Add(DocumentNode item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (_items.Count >= MaxNodes)
        {
            throw new DocumentProcessingException(
                $"Document exceeds the {MaxNodes:N0}-node extraction limit.");
        }

        var addedCharacters = (long)item.Text.Length + item.Style.Length + item.Layout.Length;
        if (_evidenceCharacters + addedCharacters > MaxEvidenceCharacters)
        {
            throw new DocumentProcessingException(
                $"Document exceeds the {MaxEvidenceCharacters:N0}-character extraction limit.");
        }

        _evidenceCharacters += addedCharacters;
        _items.Add(item);
    }

    public void Clear()
    {
        _items.Clear();
        _evidenceCharacters = 0;
    }

    public bool Contains(DocumentNode item) => _items.Contains(item);

    public void CopyTo(DocumentNode[] array, int arrayIndex) =>
        _items.CopyTo(array, arrayIndex);

    public bool Remove(DocumentNode item)
    {
        if (!_items.Remove(item))
        {
            return false;
        }

        _evidenceCharacters -= (long)item.Text.Length + item.Style.Length + item.Layout.Length;
        return true;
    }

    public IEnumerator<DocumentNode> GetEnumerator() => _items.GetEnumerator();

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}
