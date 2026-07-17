namespace DocRefract.Core.Model;

public sealed record DiffSummary
{
    public int Total { get; init; }

    public int Content { get; init; }

    public int Format { get; init; }

    public int Layout { get; init; }

    public int Media { get; init; }

    public int Visual { get; init; }

    public int Structure { get; init; }
}
