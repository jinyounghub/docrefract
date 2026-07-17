namespace DocRefract.Core.Model;

public sealed record DocumentSnapshot
{
    public const string CurrentSchemaVersion = "1.0";

    public string SchemaVersion { get; init; } = CurrentSchemaVersion;

    public required DocumentKind Kind { get; init; }

    public required string SourceHash { get; init; }

    public required string Extractor { get; init; }

    public IReadOnlyList<DocumentNode> Nodes { get; init; } = [];

    public IReadOnlyList<string> Warnings { get; init; } = [];
}
