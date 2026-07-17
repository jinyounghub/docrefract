namespace DocRefract.Core.Model;

public sealed record SourceDescriptor
{
    public required string Name { get; init; }

    public required DocumentKind Kind { get; init; }

    public required string Sha256 { get; init; }
}
