using System.Security.Cryptography;
using System.Text.Json;

namespace DocRefract.Tests;

public sealed class FixtureManifestTests
{
    [Fact]
    public void Committed_Fixtures_Match_Their_Manifest()
    {
        var manifestPath = FixturePaths.Get("manifest.json");
        using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        var files = manifest.RootElement.GetProperty("files").EnumerateArray().ToArray();

        Assert.NotEmpty(files);
        foreach (var record in files)
        {
            var name = record.GetProperty("name").GetString();
            Assert.False(string.IsNullOrWhiteSpace(name));
            var path = FixturePaths.Get(name!);
            var data = File.ReadAllBytes(path);
            var actualHash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

            Assert.Equal(record.GetProperty("bytes").GetInt64(), data.LongLength);
            Assert.Equal(record.GetProperty("sha256").GetString(), actualHash);
        }
    }
}
