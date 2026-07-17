using DocRefract.Core.Diff;
using DocRefract.Core.Extraction;

namespace DocRefract.Core;

public sealed class ComparisonService : IComparisonService
{
    public ComparisonResult Compare(
        string beforePath,
        string afterPath,
        ComparisonOptions? options = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(beforePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(afterPath);

        var beforeSelection = DocumentExtractorFactory.ForPath(beforePath);
        var afterSelection = DocumentExtractorFactory.ForPath(afterPath);
        DocumentExtractorFactory.EnsureSameKind(beforeSelection.Kind, afterSelection.Kind);

        var before = beforeSelection.Extractor.Extract(beforePath);
        var after = afterSelection.Extractor.Extract(afterPath);
        var report = new DiffEngine().Compare(
            before,
            after,
            Path.GetFileName(beforePath),
            Path.GetFileName(afterPath));

        var effectiveOptions = options ?? new ComparisonOptions();
        var policyFailed = report.Changes.Any(
            change => effectiveOptions.FailOn.Contains(change.Category));

        return new ComparisonResult
        {
            Report = report,
            PolicyFailed = policyFailed,
        };
    }
}
