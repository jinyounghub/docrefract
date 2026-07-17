using DocRefract.Core;

namespace DocRefract.Core.Model;

public sealed record EngineDescriptor
{
    public string ToolVersion { get; init; } = DocRefractVersion.Current;

    public string BeforeExtractor { get; init; } = string.Empty;

    public string AfterExtractor { get; init; } = string.Empty;
}
