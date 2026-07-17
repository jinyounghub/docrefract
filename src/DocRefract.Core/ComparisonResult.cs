using DocRefract.Core.Model;

namespace DocRefract.Core;

public sealed record ComparisonResult
{
    public required DiffReport Report { get; init; }

    public required bool PolicyFailed { get; init; }
}
