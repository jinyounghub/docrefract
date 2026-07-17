using System.Reflection;
using DocRefract.Core;
using DocRefract.Core.Reporting;

namespace DocRefract.Cli;

internal static class CliApplication
{
    private const int SuccessExitCode = 0;
    private const int PolicyFailureExitCode = 1;
    private const int ErrorExitCode = 2;

    public static int Run(string[] args, TextWriter output, TextWriter error)
    {
        ArgumentNullException.ThrowIfNull(args);
        ArgumentNullException.ThrowIfNull(output);
        ArgumentNullException.ThrowIfNull(error);

        var parseResult = CliArguments.Parse(args);
        if (parseResult.Kind == ParseResultKind.Help)
        {
            output.Write(HelpText);
            return SuccessExitCode;
        }

        if (parseResult.Kind == ParseResultKind.Version)
        {
            output.WriteLine(GetVersion());
            return SuccessExitCode;
        }

        if (parseResult.Error is not null)
        {
            error.WriteLine($"docrefract: {parseResult.Error}");
            error.WriteLine("Try 'docrefract --help' for usage.");
            return ErrorExitCode;
        }

        var options = parseResult.Options!;
        try
        {
            IComparisonService comparisonService = new ComparisonService();
            var comparison = comparisonService.Compare(
                options.BeforePath,
                options.AfterPath,
                new ComparisonOptions { FailOn = options.FailOn });

            IReportWriter reportWriter = new OfflineReportWriter();
            var artifacts = reportWriter.Write(
                comparison.Report,
                options.OutputDirectory,
                options.JsonOnly);

            if (!options.Quiet)
            {
                WriteSummary(output, comparison, artifacts);
            }

            return comparison.PolicyFailed ? PolicyFailureExitCode : SuccessExitCode;
        }
        catch (Exception exception)
        {
            error.WriteLine($"docrefract: {exception.Message}");
            return ErrorExitCode;
        }
    }

    private static void WriteSummary(
        TextWriter output,
        ComparisonResult comparison,
        ReportWriteResult artifacts)
    {
        var summary = comparison.Report.Summary;
        output.WriteLine(
            $"DocRefract: {summary.Total} change{(summary.Total == 1 ? string.Empty : "s")} " +
            $"(content {summary.Content}, format {summary.Format}, layout {summary.Layout}, " +
            $"media {summary.Media}, visual {summary.Visual}, structure {summary.Structure})");
        output.WriteLine($"Policy: {(comparison.PolicyFailed ? "FAIL" : "PASS")}");
        output.WriteLine($"JSON: {artifacts.JsonPath}");
        if (artifacts.HtmlPath is not null)
        {
            output.WriteLine($"Report: {artifacts.HtmlPath}");
        }
    }

    private static string GetVersion()
    {
        var informationalVersion = typeof(CliApplication).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informationalVersion))
        {
            var metadataSeparator = informationalVersion.IndexOf('+', StringComparison.Ordinal);
            return metadataSeparator < 0
                ? informationalVersion
                : informationalVersion[..metadataSeparator];
        }

        var version = typeof(CliApplication).Assembly.GetName().Version;
        return version is null
            ? "unknown"
            : $"{version.Major}.{version.Minor}.{version.Build}";
    }

    private const string HelpText =
        """
        DocRefract - deterministic semantic regression testing for PDF and DOCX.

        Usage:
          docrefract <before> <after> --out <directory> [options]

        Arguments:
          <before>                 Baseline PDF or DOCX file.
          <after>                  Candidate PDF or DOCX file.

        Options:
          --out <directory>        Write diff.json and index.html to this directory.
          --fail-on <categories>   Fail on any, or a comma-separated list of:
                                   content, format, layout, media, visual, structure.
                                   Default: any.
          --json-only              Write diff.json without the HTML report.
          --quiet                  Suppress the console summary.
          -h, --help               Show help and exit.
          -V, --version            Show the version and exit.

        Exit codes:
          0  Comparison completed and policy passed.
          1  Comparison completed and prohibited changes were found.
          2  Usage, input, or processing error.

        """;
}
