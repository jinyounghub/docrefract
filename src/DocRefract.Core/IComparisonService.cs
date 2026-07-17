namespace DocRefract.Core;

public interface IComparisonService
{
    ComparisonResult Compare(
        string beforePath,
        string afterPath,
        ComparisonOptions? options = null);
}
