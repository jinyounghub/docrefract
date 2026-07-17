namespace DocRefract.Core.Model;

public sealed record DiffReport
{
    public const string CurrentSchemaVersion = "1.0";

    public string SchemaVersion { get; init; } = CurrentSchemaVersion;

    public EngineDescriptor Engine { get; init; } = new();

    public required SourceDescriptor Before { get; init; }

    public required SourceDescriptor After { get; init; }

    public required DiffSummary Summary { get; init; }

    public IReadOnlyList<ChangeRecord> Changes { get; init; } = [];

    public IReadOnlyList<string> Warnings { get; init; } = [];
}
