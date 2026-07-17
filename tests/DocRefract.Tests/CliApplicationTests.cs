using System.Text.Json;
using DocRefract.Cli;

namespace DocRefract.Tests;

public sealed class CliApplicationTests
{
    [Fact]
    public void Help_Describes_Demo_Command()
    {
        var (exitCode, output, error) = Run("--help");

        Assert.Equal(0, exitCode);
        Assert.Contains("docrefract demo --out <directory>", output, StringComparison.Ordinal);
        Assert.Contains("Generate sample DOCX files", output, StringComparison.Ordinal);
        Assert.Empty(error);
    }

    [Fact]
    public void Demo_Writes_Deterministic_SelfContained_Artifacts_And_Preserves_Other_Files()
    {
        using var directory = TempDirectory.Create();
        var sentinelPath = Path.Combine(directory.Path, "keep.txt");
        File.WriteAllText(sentinelPath, "do not replace");

        var firstRun = Run("demo", "--out", directory.Path);

        Assert.Equal(0, firstRun.ExitCode);
        Assert.Empty(firstRun.Error);
        Assert.Contains("Demo completed successfully.", firstRun.Output, StringComparison.Ordinal);

        var expectedNames = new[] { "before.docx", "after.docx", "diff.json", "index.html" };
        Assert.All(
            expectedNames,
            name => Assert.True(File.Exists(Path.Combine(directory.Path, name)), name));
        Assert.Equal("do not replace", File.ReadAllText(sentinelPath));
        Assert.Empty(
            Directory.EnumerateDirectories(directory.Path, ".docrefract-demo-*.tmp"));

        var jsonPath = Path.Combine(directory.Path, "diff.json");
        using (var json = JsonDocument.Parse(File.ReadAllText(jsonPath)))
        {
            var root = json.RootElement;
            Assert.Equal("before.docx", root.GetProperty("before").GetProperty("name").GetString());
            Assert.Equal("after.docx", root.GetProperty("after").GetProperty("name").GetString());
            var summary = root.GetProperty("summary");
            Assert.True(summary.GetProperty("content").GetInt32() >= 1);
            Assert.True(summary.GetProperty("format").GetInt32() >= 1);
            Assert.True(summary.GetProperty("layout").GetInt32() >= 1);
        }

        var html = File.ReadAllText(Path.Combine(directory.Path, "index.html"));
        Assert.Contains("default-src 'none'", html, StringComparison.Ordinal);
        Assert.DoesNotContain("http://", html, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("https://", html, StringComparison.OrdinalIgnoreCase);

        var firstBytes = expectedNames.ToDictionary(
            name => name,
            name => File.ReadAllBytes(Path.Combine(directory.Path, name)),
            StringComparer.Ordinal);

        var secondRun = Run("demo", $"--out={directory.Path}");

        Assert.Equal(0, secondRun.ExitCode);
        Assert.Empty(secondRun.Error);
        Assert.All(
            expectedNames,
            name => Assert.Equal(firstBytes[name], File.ReadAllBytes(Path.Combine(directory.Path, name))));
        Assert.Equal("do not replace", File.ReadAllText(sentinelPath));
    }

    [Fact]
    public void Demo_Returns_Zero_While_Comparing_Its_Changed_Documents_Returns_One()
    {
        using var directory = TempDirectory.Create();
        var demoDirectory = Path.Combine(directory.Path, "demo");
        var compareDirectory = Path.Combine(directory.Path, "compare");

        var demo = Run("demo", "--out", demoDirectory);
        var comparison = Run(
            Path.Combine(demoDirectory, "before.docx"),
            Path.Combine(demoDirectory, "after.docx"),
            "--out",
            compareDirectory,
            "--quiet");

        Assert.Equal(0, demo.ExitCode);
        Assert.Equal(1, comparison.ExitCode);
        Assert.Empty(comparison.Output);
        Assert.Empty(comparison.Error);
        Assert.True(File.Exists(Path.Combine(compareDirectory, "diff.json")));
        Assert.True(File.Exists(Path.Combine(compareDirectory, "index.html")));
    }

    [Fact]
    public void Demo_Usage_And_Processing_Errors_Return_Two()
    {
        var missingOutput = Run("demo");
        Assert.Equal(2, missingOutput.ExitCode);
        Assert.Contains("required option '--out' is missing", missingOutput.Error, StringComparison.Ordinal);

        using var directory = TempDirectory.Create();
        var filePath = Path.Combine(directory.Path, "not-a-directory");
        File.WriteAllText(filePath, "occupied");

        var invalidOutput = Run("demo", "--out", filePath);
        Assert.Equal(2, invalidOutput.ExitCode);
        Assert.StartsWith("docrefract:", invalidOutput.Error, StringComparison.Ordinal);
        Assert.Equal("occupied", File.ReadAllText(filePath));
    }

    private static (int ExitCode, string Output, string Error) Run(params string[] args)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();
        var exitCode = CliApplication.Run(args, output, error);
        return (exitCode, output.ToString(), error.ToString());
    }

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
                "docrefract-cli-tests-" + Guid.NewGuid().ToString("N")));

        public void Dispose()
        {
            if (Directory.Exists(Path))
            {
                Directory.Delete(Path, recursive: true);
            }
        }
    }
}
