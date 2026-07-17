namespace DocRefract.Core.Model;

public sealed record DocumentNode
{
    public required string Anchor { get; init; }

    public required NodeKind Kind { get; init; }

    public string Text { get; init; } = string.Empty;

    public string Style { get; init; } = string.Empty;

    public string Layout { get; init; } = string.Empty;

    public BoundingBox? Box { get; init; }

    public int? Page { get; init; }

    public string? MediaHash { get; init; }
}
