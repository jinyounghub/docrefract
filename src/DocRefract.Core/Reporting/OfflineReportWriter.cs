using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using DocRefract.Core.Model;

namespace DocRefract.Core.Reporting;

public sealed class OfflineReportWriter : IReportWriter
{
    private static readonly UTF8Encoding Utf8WithoutBom = new(encoderShouldEmitUTF8Identifier: false);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = JavaScriptEncoder.Default,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters =
        {
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false),
        },
    };

    public ReportWriteResult Write(
        DiffReport report,
        string outputDirectory,
        bool jsonOnly = false)
    {
        ArgumentNullException.ThrowIfNull(report);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputDirectory);

        var fullOutputDirectory = Path.GetFullPath(outputDirectory);
        Directory.CreateDirectory(fullOutputDirectory);

        var jsonPath = Path.Combine(fullOutputDirectory, "diff.json");
        var json = NormalizeNewlines(JsonSerializer.Serialize(report, JsonOptions)) + "\n";
        WriteDeterministicText(jsonPath, json);

        var expectedHtmlPath = Path.Combine(fullOutputDirectory, "index.html");
        string? htmlPath = null;
        if (!jsonOnly)
        {
            htmlPath = expectedHtmlPath;
            WriteDeterministicText(htmlPath, BuildHtml(report));
        }
        else if (File.Exists(expectedHtmlPath))
        {
            File.Delete(expectedHtmlPath);
        }

        return new ReportWriteResult
        {
            JsonPath = jsonPath,
            HtmlPath = htmlPath,
        };
    }

    private static void WriteDeterministicText(string path, string content)
    {
        var directory = Path.GetDirectoryName(path) ??
            throw new InvalidOperationException("Report output path has no parent directory.");
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{RandomNumberGenerator.GetHexString(16)}.tmp");

        try
        {
            using (var stream = new FileStream(
                       temporaryPath,
                       FileMode.CreateNew,
                       FileAccess.Write,
                       FileShare.None,
                       bufferSize: 16_384,
                       FileOptions.WriteThrough))
            using (var writer = new StreamWriter(stream, Utf8WithoutBom, leaveOpen: true))
            {
                writer.Write(content);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private static string BuildHtml(DiffReport report)
    {
        var builder = new StringBuilder(capacity: 16_384);
        builder.Append(
            """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
              <title>DocRefract report</title>
              <style>
                :root {
                  color-scheme: light dark;
                  --bg: #0b1020;
                  --panel: #151c31;
                  --panel-2: #1d2740;
                  --text: #e8edf8;
                  --muted: #aab5ca;
                  --line: #34415e;
                  --accent: #7dd3fc;
                  --content: #fb7185;
                  --format: #c084fc;
                  --layout: #60a5fa;
                  --media: #34d399;
                  --visual: #fbbf24;
                  --structure: #fb923c;
                }
                * { box-sizing: border-box; }
                body {
                  margin: 0;
                  background: var(--bg);
                  color: var(--text);
                  font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                }
                main { width: min(1180px, calc(100% - 32px)); margin: 0 auto; padding: 42px 0 64px; }
                h1 { margin: 0; font-size: clamp(30px, 6vw, 54px); letter-spacing: -0.04em; }
                h2 { margin: 36px 0 14px; font-size: 20px; }
                p { margin: 8px 0; }
                .eyebrow { color: var(--accent); font-size: 13px; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; }
                .subtitle { color: var(--muted); font-size: 17px; }
                .sources, .summary { display: grid; gap: 12px; margin-top: 24px; }
                .sources { grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
                .summary { grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); }
                .card {
                  min-width: 0;
                  padding: 16px;
                  border: 1px solid var(--line);
                  border-radius: 12px;
                  background: var(--panel);
                }
                .label { color: var(--muted); font-size: 12px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
                .value { margin-top: 4px; font-size: 22px; font-weight: 750; }
                .source-name { overflow-wrap: anywhere; font-size: 17px; font-weight: 700; }
                .hash { color: var(--muted); font: 12px/1.5 ui-monospace, SFMono-Regular, Consolas, monospace; overflow-wrap: anywhere; }
                .changes { display: grid; gap: 14px; }
                .change {
                  overflow: hidden;
                  border: 1px solid var(--line);
                  border-radius: 12px;
                  background: var(--panel);
                }
                .change-head {
                  display: flex;
                  flex-wrap: wrap;
                  align-items: center;
                  gap: 8px;
                  padding: 12px 16px;
                  border-bottom: 1px solid var(--line);
                  background: var(--panel-2);
                }
                .badge {
                  padding: 3px 9px;
                  border-radius: 999px;
                  color: #090d17;
                  font-size: 12px;
                  font-weight: 800;
                  text-transform: uppercase;
                }
                .content { background: var(--content); }
                .format { background: var(--format); }
                .layout { background: var(--layout); }
                .media { background: var(--media); }
                .visual { background: var(--visual); }
                .structure { background: var(--structure); }
                .operation, .confidence { color: var(--muted); font-size: 13px; }
                .change-id { margin-left: auto; color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Consolas, monospace; }
                .sides { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); }
                .side { min-width: 0; padding: 16px; }
                .side + .side { border-left: 1px solid var(--line); }
                .anchor { margin: 5px 0 10px; color: var(--accent); font: 12px/1.4 ui-monospace, SFMono-Regular, Consolas, monospace; overflow-wrap: anywhere; }
                .text {
                  min-height: 54px;
                  margin: 0;
                  padding: 12px;
                  border-radius: 8px;
                  background: #090e1c;
                  white-space: pre-wrap;
                  overflow-wrap: anywhere;
                  font: 13px/1.55 ui-monospace, SFMono-Regular, Consolas, monospace;
                }
                .meta { margin-top: 10px; color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }
                .empty {
                  padding: 26px;
                  border: 1px dashed var(--line);
                  border-radius: 12px;
                  color: var(--muted);
                  text-align: center;
                }
                .warnings { padding-left: 22px; color: #fde68a; }
                footer { margin-top: 38px; color: var(--muted); font-size: 12px; }
                @media (max-width: 720px) {
                  main { width: min(100% - 20px, 1180px); padding-top: 24px; }
                  .sides { grid-template-columns: 1fr; }
                  .side + .side { border-top: 1px solid var(--line); border-left: 0; }
                  .change-id { width: 100%; margin-left: 0; }
                }
                @media (prefers-color-scheme: light) {
                  :root {
                    --bg: #f4f7fb;
                    --panel: #fff;
                    --panel-2: #eef3fa;
                    --text: #182033;
                    --muted: #5d6980;
                    --line: #ced7e6;
                  }
                  .text { background: #f3f6fb; }
                }
              </style>
            </head>
            <body>
            <main>
              <div class="eyebrow">Deterministic document diff</div>
              <h1>DocRefract</h1>
              <p class="subtitle">See what changed—not just where pixels moved.</p>
            """);

        AppendSources(builder, report);
        AppendSummary(builder, report.Summary);
        AppendWarnings(builder, report.Warnings);
        AppendChanges(builder, report.Changes);

        builder.Append("<footer>Schema ");
        builder.Append(Encode(report.SchemaVersion));
        builder.Append(" · This report is self-contained and makes no network requests.</footer>\n");
        builder.Append("</main>\n</body>\n</html>\n");

        return NormalizeNewlines(builder.ToString());
    }

    private static void AppendSources(StringBuilder builder, DiffReport report)
    {
        builder.Append("<section class=\"sources\" aria-label=\"Compared documents\">\n");
        AppendSource(builder, "Before", report.Before);
        AppendSource(builder, "After", report.After);
        builder.Append("</section>\n");
    }

    private static void AppendSource(StringBuilder builder, string label, SourceDescriptor source)
    {
        builder.Append("<article class=\"card\"><div class=\"label\">");
        builder.Append(label);
        builder.Append("</div><div class=\"source-name\">");
        builder.Append(Encode(source.Name));
        builder.Append("</div><div class=\"hash\">");
        builder.Append(Encode(source.Kind.ToString()));
        builder.Append(" · SHA-256 ");
        builder.Append(Encode(source.Sha256));
        builder.Append("</div></article>\n");
    }

    private static void AppendSummary(StringBuilder builder, DiffSummary summary)
    {
        builder.Append("<h2>Summary</h2><section class=\"summary\" aria-label=\"Change summary\">\n");
        AppendSummaryCard(builder, "Total", summary.Total);
        AppendSummaryCard(builder, "Content", summary.Content);
        AppendSummaryCard(builder, "Format", summary.Format);
        AppendSummaryCard(builder, "Layout", summary.Layout);
        AppendSummaryCard(builder, "Media", summary.Media);
        AppendSummaryCard(builder, "Visual", summary.Visual);
        AppendSummaryCard(builder, "Structure", summary.Structure);
        builder.Append("</section>\n");
    }

    private static void AppendSummaryCard(StringBuilder builder, string label, int count)
    {
        builder.Append("<article class=\"card\"><div class=\"label\">");
        builder.Append(label);
        builder.Append("</div><div class=\"value\">");
        builder.Append(count.ToString(CultureInfo.InvariantCulture));
        builder.Append("</div></article>\n");
    }

    private static void AppendWarnings(StringBuilder builder, IReadOnlyList<string> warnings)
    {
        if (warnings.Count == 0)
        {
            return;
        }

        builder.Append("<h2>Warnings</h2><ul class=\"warnings\">\n");
        foreach (var warning in warnings)
        {
            builder.Append("<li>");
            builder.Append(Encode(warning));
            builder.Append("</li>\n");
        }

        builder.Append("</ul>\n");
    }

    private static void AppendChanges(StringBuilder builder, IReadOnlyList<ChangeRecord> changes)
    {
        builder.Append("<h2>Changes</h2>");
        if (changes.Count == 0)
        {
            builder.Append("<div class=\"empty\">No semantic changes detected.</div>\n");
            return;
        }

        builder.Append("<section class=\"changes\">\n");
        foreach (var change in changes)
        {
            var category = change.Category.ToString().ToLowerInvariant();
            builder.Append("<article class=\"change\"><header class=\"change-head\"><span class=\"badge ");
            builder.Append(category);
            builder.Append("\">");
            builder.Append(Encode(change.Category.ToString()));
            builder.Append("</span><span class=\"operation\">");
            builder.Append(Encode(change.Operation.ToString()));
            builder.Append("</span><span class=\"confidence\">");
            builder.Append((change.Confidence * 100m).ToString("0.#", CultureInfo.InvariantCulture));
            builder.Append("% confidence</span><span class=\"change-id\">");
            builder.Append(Encode(change.Id));
            builder.Append("</span></header><div class=\"sides\">\n");

            var showStyle = change.Category is ChangeCategory.Format or ChangeCategory.Layout;
            var showBox = change.Category == ChangeCategory.Layout;

            AppendChangeSide(
                builder,
                "Before",
                change.BeforeAnchor,
                change.BeforeText,
                showStyle ? change.BeforeStyle : null,
                showBox ? change.BeforeBox : null);
            AppendChangeSide(
                builder,
                "After",
                change.AfterAnchor,
                change.AfterText,
                showStyle ? change.AfterStyle : null,
                showBox ? change.AfterBox : null);

            builder.Append("</div></article>\n");
        }

        builder.Append("</section>\n");
    }

    private static void AppendChangeSide(
        StringBuilder builder,
        string label,
        string? anchor,
        string? text,
        string? style,
        BoundingBox? box)
    {
        builder.Append("<section class=\"side\"><div class=\"label\">");
        builder.Append(label);
        builder.Append("</div><div class=\"anchor\">");
        builder.Append(Encode(anchor ?? "—"));
        builder.Append("</div><pre class=\"text\">");
        builder.Append(Encode(text ?? "—"));
        builder.Append("</pre>");

        if (!string.IsNullOrEmpty(style))
        {
            builder.Append("<div class=\"meta\"><strong>Style:</strong> ");
            builder.Append(Encode(style));
            builder.Append("</div>");
        }

        if (box is not null)
        {
            builder.Append("<div class=\"meta\"><strong>Box:</strong> ");
            builder.Append(FormatBox(box));
            builder.Append("</div>");
        }

        builder.Append("</section>\n");
    }

    private static string FormatBox(BoundingBox box) =>
        string.Create(
            CultureInfo.InvariantCulture,
            $"x {box.X:0.###}, y {box.Y:0.###}, w {box.Width:0.###}, h {box.Height:0.###}");

    private static string Encode(string value) => WebUtility.HtmlEncode(value);

    private static string NormalizeNewlines(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n');
}
