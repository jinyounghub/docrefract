using DocRefract.Core.Model;

namespace DocRefract.Cli;

internal enum ParseResultKind
{
    Run,
    Demo,
    Help,
    Version,
    Error,
}

internal sealed record CliParseResult
{
    public required ParseResultKind Kind { get; init; }

    public CliArguments? Options { get; init; }

    public DemoArguments? DemoOptions { get; init; }

    public string? Error { get; init; }
}

internal sealed record DemoArguments
{
    public required string OutputDirectory { get; init; }
}

internal sealed record CliArguments
{
    private static readonly IReadOnlyDictionary<string, ChangeCategory> CategoryNames =
        new Dictionary<string, ChangeCategory>(StringComparer.OrdinalIgnoreCase)
        {
            ["content"] = ChangeCategory.Content,
            ["format"] = ChangeCategory.Format,
            ["layout"] = ChangeCategory.Layout,
            ["media"] = ChangeCategory.Media,
            ["visual"] = ChangeCategory.Visual,
            ["structure"] = ChangeCategory.Structure,
        };

    public required string BeforePath { get; init; }

    public required string AfterPath { get; init; }

    public required string OutputDirectory { get; init; }

    public required IReadOnlySet<ChangeCategory> FailOn { get; init; }

    public bool JsonOnly { get; init; }

    public bool Quiet { get; init; }

    public static CliParseResult Parse(string[] args)
    {
        if (args.Any(argument => argument is "--help" or "-h"))
        {
            return new CliParseResult { Kind = ParseResultKind.Help };
        }

        if (args.Any(argument => argument is "--version" or "-V"))
        {
            return new CliParseResult { Kind = ParseResultKind.Version };
        }

        if (args.Length > 0 && string.Equals(args[0], "demo", StringComparison.Ordinal))
        {
            return ParseDemo(args);
        }

        var positional = new List<string>(capacity: 2);
        string? outputDirectory = null;
        string? failOnValue = null;
        var jsonOnly = false;
        var quiet = false;

        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];
            if (argument == "--json-only")
            {
                if (jsonOnly)
                {
                    return Error("option '--json-only' was specified more than once");
                }

                jsonOnly = true;
                continue;
            }

            if (argument == "--quiet")
            {
                if (quiet)
                {
                    return Error("option '--quiet' was specified more than once");
                }

                quiet = true;
                continue;
            }

            if (TryReadOption(args, ref index, "--out", argument, out var outValue, out var outError))
            {
                if (outError is not null)
                {
                    return Error(outError);
                }

                if (outputDirectory is not null)
                {
                    return Error("option '--out' was specified more than once");
                }

                outputDirectory = outValue;
                continue;
            }

            if (TryReadOption(args, ref index, "--fail-on", argument, out var failValue, out var failError))
            {
                if (failError is not null)
                {
                    return Error(failError);
                }

                if (failOnValue is not null)
                {
                    return Error("option '--fail-on' was specified more than once");
                }

                failOnValue = failValue;
                continue;
            }

            if (argument.StartsWith("-", StringComparison.Ordinal) && argument != "-")
            {
                return Error($"unknown option '{argument}'");
            }

            positional.Add(argument);
        }

        if (positional.Count != 2)
        {
            return Error("exactly two input files are required");
        }

        if (string.IsNullOrWhiteSpace(outputDirectory))
        {
            return Error("required option '--out' is missing");
        }

        var failOn = ParseFailOn(failOnValue ?? "any", out var categoryError);
        if (categoryError is not null)
        {
            return Error(categoryError);
        }

        return new CliParseResult
        {
            Kind = ParseResultKind.Run,
            Options = new CliArguments
            {
                BeforePath = positional[0],
                AfterPath = positional[1],
                OutputDirectory = outputDirectory,
                FailOn = failOn!,
                JsonOnly = jsonOnly,
                Quiet = quiet,
            },
        };
    }

    private static CliParseResult ParseDemo(string[] args)
    {
        string? outputDirectory = null;
        for (var index = 1; index < args.Length; index++)
        {
            var argument = args[index];
            if (TryReadOption(args, ref index, "--out", argument, out var outValue, out var outError))
            {
                if (outError is not null)
                {
                    return Error(outError);
                }

                if (outputDirectory is not null)
                {
                    return Error("option '--out' was specified more than once");
                }

                outputDirectory = outValue;
                continue;
            }

            if (argument.StartsWith("-", StringComparison.Ordinal) && argument != "-")
            {
                return Error($"unknown demo option '{argument}'");
            }

            return Error($"unexpected demo argument '{argument}'");
        }

        if (string.IsNullOrWhiteSpace(outputDirectory))
        {
            return Error("required option '--out' is missing");
        }

        return new CliParseResult
        {
            Kind = ParseResultKind.Demo,
            DemoOptions = new DemoArguments { OutputDirectory = outputDirectory },
        };
    }

    private static bool TryReadOption(
        string[] args,
        ref int index,
        string optionName,
        string argument,
        out string? value,
        out string? error)
    {
        value = null;
        error = null;
        if (argument == optionName)
        {
            if (index + 1 >= args.Length)
            {
                error = $"option '{optionName}' requires a value";
                return true;
            }

            value = args[++index];
            if (string.IsNullOrWhiteSpace(value) ||
                (value.StartsWith("-", StringComparison.Ordinal) && value != "-"))
            {
                error = $"option '{optionName}' requires a value";
            }

            return true;
        }

        var optionPrefix = optionName + "=";
        if (!argument.StartsWith(optionPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        value = argument[optionPrefix.Length..];
        if (string.IsNullOrWhiteSpace(value))
        {
            error = $"option '{optionName}' requires a value";
        }

        return true;
    }

    private static IReadOnlySet<ChangeCategory>? ParseFailOn(string value, out string? error)
    {
        error = null;
        if (value.Equals("any", StringComparison.OrdinalIgnoreCase))
        {
            return new HashSet<ChangeCategory>(Enum.GetValues<ChangeCategory>());
        }

        var values = value.Split(',', StringSplitOptions.TrimEntries);
        if (values.Length == 0 || values.Any(string.IsNullOrWhiteSpace))
        {
            error = "option '--fail-on' requires 'any' or a comma-separated category list";
            return null;
        }

        var categories = new HashSet<ChangeCategory>();
        foreach (var categoryName in values)
        {
            if (categoryName.Equals("any", StringComparison.OrdinalIgnoreCase))
            {
                error = "'any' cannot be combined with other '--fail-on' categories";
                return null;
            }

            if (!CategoryNames.TryGetValue(categoryName, out var category))
            {
                error = $"unknown '--fail-on' category '{categoryName}'";
                return null;
            }

            categories.Add(category);
        }

        return categories;
    }

    private static CliParseResult Error(string message) =>
        new()
        {
            Kind = ParseResultKind.Error,
            Error = message,
        };
}
