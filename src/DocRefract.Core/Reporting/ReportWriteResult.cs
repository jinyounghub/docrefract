namespace DocRefract.Core.Reporting;

public sealed record ReportWriteResult
{
    public required string JsonPath { get; init; }

    public string? HtmlPath { get; init; }
}
