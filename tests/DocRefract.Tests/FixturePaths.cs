namespace DocRefract.Tests;

internal static class FixturePaths
{
    private static readonly string Root =
        Path.Combine(AppContext.BaseDirectory, "Fixtures");

    public static string Get(string name)
    {
        var path = Path.Combine(Root, name);
        Assert.True(File.Exists(path), $"Fixture was not copied to the test output: {path}");
        return path;
    }
}
