# Native dependency locks

These lock files pin the dependency graph used by each self-contained release
RID without making normal solution restores download every platform's runtime
pack.

Release and native CI restore with `--locked-mode`. To intentionally refresh
the locks with the SDK pinned in `global.json`, run this command once per RID:

```powershell
$rids = @(
  "linux-x64", "linux-arm64",
  "osx-x64", "osx-arm64",
  "win-x64", "win-arm64"
)
foreach ($rid in $rids) {
  dotnet restore src/DocRefract.Cli/DocRefract.Cli.csproj `
    "-p:RuntimeIdentifier=$rid" `
    --force-evaluate
}
```

Commit all twelve `*.lock.json` files together. The version-sync check rejects
missing RID targets.
