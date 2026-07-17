using DocRefract.Core;
using DocRefract.Core.Model;
using DocRefract.Core.Reporting;

namespace DocRefract.Tests;

public sealed class OfflineReportWriterTests
{
    private readonly ComparisonService _service = new();
    private readonly OfflineReportWriter _writer = new();

    [Fact]
    public void Same_Report_Writes_Byte_Identical_Json_And_Html()
    {
        using var firstDirectory = TempDirectory.Create();
        using var secondDirectory = TempDirectory.Create();
        var report = _service.Compare(
            FixturePaths.Get("docx_text_before.docx"),
            FixturePaths.Get("docx_text_after.docx")).Report;

        var first = _writer.Write(report, firstDirectory.Path);
        var second = _writer.Write(report, secondDirectory.Path);

        Assert.Equal(File.ReadAllBytes(first.JsonPath), File.ReadAllBytes(second.JsonPath));
        Assert.Equal(File.ReadAllBytes(first.HtmlPath!), File.ReadAllBytes(second.HtmlPath!));
        Assert.Equal(new byte[] { (byte)'{' }, File.ReadAllBytes(first.JsonPath)[..1]);
        Assert.Equal(new byte[] { (byte)'<' }, File.ReadAllBytes(first.HtmlPath!)[..1]);
    }

    [Fact]
    public void Html_Report_Is_Self_Contained_And_Encodes_Untrusted_Document_Text()
    {
        using var directory = TempDirectory.Create();
        const string hostile = "<script>alert('fixture')</script>";
        var report = new DiffReport
        {
            Before = Source("before-<script>.docx"),
            After = Source("after.docx"),
            Summary = new DiffSummary { Total = 1, Content = 1 },
            Changes =
            [
                new ChangeRecord
                {
                    Id = "content-0001",
                    Category = ChangeCategory.Content,
                    Operation = ChangeOperation.Replace,
                    BeforeAnchor = "body/p[0001]",
                    AfterAnchor = "body/p[0001]",
                    BeforeText = hostile,
                    AfterText = "safe",
                },
            ],
            Warnings = [hostile],
        };

        var output = _writer.Write(report, directory.Path);
        var html = File.ReadAllText(output.HtmlPath!);
        var json = File.ReadAllText(output.JsonPath);

        Assert.DoesNotContain(hostile, html, StringComparison.Ordinal);
        Assert.Contains("&lt;script&gt;alert(&#39;fixture&#39;)&lt;/script&gt;", html, StringComparison.Ordinal);
        Assert.Contains("default-src 'none'", html, StringComparison.Ordinal);
        Assert.DoesNotContain("http://", html, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https://", html, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(hostile, json, StringComparison.Ordinal);
        Assert.Contains("\\u003Cscript\\u003E", json, StringComparison.Ordinal);
    }

    [Fact]
    public void JsonOnly_Mode_Does_Not_Write_Html()
    {
        using var directory = TempDirectory.Create();
        var report = new DiffReport
        {
            Before = Source("before.docx"),
            After = Source("after.docx"),
            Summary = new DiffSummary(),
        };

        var initial = _writer.Write(report, directory.Path);
        Assert.True(File.Exists(initial.HtmlPath));

        var output = _writer.Write(report, directory.Path, jsonOnly: true);

        Assert.True(File.Exists(output.JsonPath));
        Assert.Null(output.HtmlPath);
        Assert.False(File.Exists(System.IO.Path.Combine(directory.Path, "index.html")));
    }

    private static SourceDescriptor Source(string name) => new()
    {
        Name = name,
        Kind = DocumentKind.Docx,
        Sha256 = new string('0', 64),
    };

    private sealed class TempDirectory : IDisposable
    {
        private TempDirectory(string path)
        {
            Path = path;
            Directory.CreateDirectory(path);
        }

        public string Path { get; }

        public static TempDirectory Create() =>
            new(System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "docrefract-tests-" + Guid.NewGuid().ToString("N")));

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
