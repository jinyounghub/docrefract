namespace DocRefract.Core.Model;

public sealed record ChangeRecord
{
    public required string Id { get; init; }

    public required ChangeCategory Category { get; init; }

    public required ChangeOperation Operation { get; init; }

    public string? BeforeAnchor { get; init; }

    public string? AfterAnchor { get; init; }

    public string? BeforeText { get; init; }

    public string? AfterText { get; init; }

    public string? BeforeStyle { get; init; }

    public string? AfterStyle { get; init; }

    public BoundingBox? BeforeBox { get; init; }

    public BoundingBox? AfterBox { get; init; }

    public decimal Confidence { get; init; } = 1.0m;
}
