namespace DocRefract.Core.Model;

public sealed record EngineDescriptor
{
    public string ToolVersion { get; init; } = "0.1.0";

    public string BeforeExtractor { get; init; } = string.Empty;

    public string AfterExtractor { get; init; } = string.Empty;
}
