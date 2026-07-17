using DocRefract.Core.Model;

namespace DocRefract.Core;

public sealed record ComparisonOptions
{
    public IReadOnlySet<ChangeCategory> FailOn { get; init; } =
        new HashSet<ChangeCategory>(Enum.GetValues<ChangeCategory>());
}
