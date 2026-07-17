# Contributing to DocRefract

Thanks for helping make document regression tests more trustworthy. Small,
focused changes with reproducible fixtures are the easiest to review.

By participating, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- Search existing issues before opening a new one.
- Use a feature request to discuss a large behavior or schema change first.
- Never attach a confidential customer document. Reduce it to a synthetic,
  minimal reproduction.
- Security vulnerabilities belong in a private report; see
  [SECURITY.md](SECURITY.md).

## Development setup

Install the .NET 10 SDK, then run:

```console
dotnet restore
dotnet build DocRefract.slnx -c Release --no-restore
dotnet test DocRefract.slnx -c Release --no-build
dotnet pack src/DocRefract.Cli -c Release --no-build -o artifacts/packages
```

The repository pins its expected SDK feature band in `global.json`. A newer
.NET 10 feature band may be selected through the configured roll-forward
policy.

## A good change

1. Create a short branch from `main`.
2. Add or update a focused fixture and its expected semantic result.
3. Implement the smallest behavior that makes that case pass.
4. Run the full test suite on your platform.
5. Update user-facing documentation when behavior or JSON output changes.
6. Open a pull request describing what changed and why.

Keep commits coherent. A pull request does not need to be perfect when opened,
but mark unfinished work as a draft.

## Fixture rules

Regression fixtures are part of DocRefract's compatibility contract:

- use generated or clearly redistributable content;
- prefer the smallest document that reproduces the behavior;
- include both the baseline and candidate;
- state the exact expected categories, operations, and anchors;
- include non-ASCII text when the behavior is encoding-sensitive;
- do not normalize a file by hand merely to make the test pass;
- avoid real names, account numbers, or production data.

Large binary fixtures need prior discussion. When practical, commit the
deterministic generator rather than an opaque binary.

## Determinism rules

Machine-readable output must not depend on:

- wall-clock time;
- absolute paths;
- dictionary or filesystem enumeration order;
- random identifiers;
- process IDs or machine-specific temporary paths;
- locale-sensitive number or text formatting.

Any renderer-dependent evidence must identify its renderer profile and remain
advisory when profiles differ. Read [docs/determinism.md](docs/determinism.md)
before changing extraction, matching, anchors, or serialization.

## Compatibility

The `schemaVersion` field versions `diff.json`. Additive changes may occur
within the 1.x schema family; removing or changing the meaning of a field
requires an explicit schema version decision and migration notes.

Exit codes `0`, `1`, and `2` are public CLI behavior. Changes to category
classification or default failure policy require tests and a changelog entry.

## Style

- Follow the existing C# style and nullable annotations.
- Prefer clear domain names over abbreviations.
- Treat compiler warnings as errors.
- Escape all document-derived content in reports.
- Keep parsers bounded and avoid fetching external resources.

## Pull request checklist

- [ ] Tests cover the change.
- [ ] All tests pass locally.
- [ ] Output remains deterministic.
- [ ] Untrusted input paths remain bounded and offline.
- [ ] Documentation and `CHANGELOG.md` are updated when applicable.
- [ ] No confidential or non-redistributable document was added.

Contributions are accepted under the repository's
[Apache-2.0 license](LICENSE).
