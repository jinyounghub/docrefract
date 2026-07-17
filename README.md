# DocRefract

[![CI](https://github.com/jinyounghub/docrefract/actions/workflows/ci.yml/badge.svg)](https://github.com/jinyounghub/docrefract/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![.NET 10](https://img.shields.io/badge/.NET-10.0-512BD4)](https://dotnet.microsoft.com/)

**See what changed—not just where pixels moved.**

DocRefract is a local-first document regression tester for generated PDF and
DOCX files. It turns a document comparison into deterministic, reviewable
changes—`content`, `format`, `layout`, `media`, `visual`, and `structure`—then
lets CI decide which categories are allowed.

![DocRefract offline comparison report](https://raw.githubusercontent.com/jinyounghub/docrefract/main/docs/assets/report-preview.png)

```console
docrefract baseline.docx candidate.docx \
  --out artifacts/docrefract \
  --fail-on content,layout
```

The command writes a machine-readable `diff.json` and a self-contained
`index.html`. Exit code `1` makes the build fail only when a prohibited change
is found.

> [!IMPORTANT]
> DocRefract is an early alpha. The report schema is versioned, but may evolve
> before 1.0. Start by pinning the tool version in CI.

## Why DocRefract?

Document pipelines break in ways ordinary snapshot tests do not explain:

- a total changes while the page still looks almost identical;
- a font fallback moves content onto another page;
- a table cell changes but a full-page pixel diff becomes noisy;
- a regenerated DOCX changes package metadata even though its content does not.

DocRefract gives PDF and DOCX pipelines one offline CI contract:

- **Semantic changes:** distinguish text, styling, geometry, media, and
  document structure.
- **Stable automation:** canonical anchors and ordered JSON make results
  suitable for baselines, code review, and policy checks.
- **Useful evidence:** inspect an offline HTML report without uploading
  confidential documents to a service.
- **Intentional gates:** fail on `content` and `layout`, for example, while
  allowing an approved formatting refresh.

## Quick start

### Run from source

Prerequisite: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```console
git clone https://github.com/jinyounghub/docrefract.git
cd docrefract
dotnet restore
dotnet run --project src/DocRefract.Cli -- \
  path/to/before.pdf path/to/after.pdf \
  --out artifacts/report \
  --fail-on content,layout
```

Open `artifacts/report/index.html` in a browser, or consume
`artifacts/report/diff.json` from another tool.

### Install from GitHub Releases

Prerequisite: [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).
The installable package is attached to every GitHub Release. With the
[GitHub CLI](https://cli.github.com/):

```console
gh release download v0.1.1 --repo jinyounghub/docrefract --pattern "DocRefract.Tool.0.1.1.nupkg" --dir .docrefract-packages
dotnet tool install --global DocRefract.Tool --version 0.1.1 --source .docrefract-packages
docrefract --version
```

Alternatively, download
[`DocRefract.Tool.0.1.1.nupkg`](https://github.com/jinyounghub/docrefract/releases/download/v0.1.1/DocRefract.Tool.0.1.1.nupkg)
in a browser and pass its containing directory to `--source`. NuGet.org
publishing is not enabled yet, so the GitHub Release package is the canonical
binary for this version.

If an older DocRefract version is already installed, update from the same local
package directory:

```console
dotnet tool update --global DocRefract.Tool --version 0.1.1 --source .docrefract-packages
```

Open a new terminal if `docrefract` is not yet on `PATH`.

### Verify release assets

Download all four assets before checking the manifest; `SHA256SUMS` covers the
`.nupkg`, packaged-payload SBOM, and third-party notices:

```console
gh release download v0.1.1 --repo jinyounghub/docrefract --dir .docrefract-release
cd .docrefract-release
sha256sum --check SHA256SUMS
```

On macOS, use `shasum -a 256 --check SHA256SUMS`. In PowerShell, compare each
manifest hash with `Get-FileHash -Algorithm SHA256`.

To test a package built from the repository:

```console
dotnet pack src/DocRefract.Cli -c Release -o artifacts/packages
dotnet tool install --global DocRefract.Tool \
  --source artifacts/packages --version 0.1.1
```

## CLI contract

```text
docrefract <before> <after> [options]

Options:
  --out <directory>       Report directory (required)
  --fail-on <categories>  `any` or a comma-separated policy:
                          content,format,layout,media,visual,structure
  --json-only             Write diff.json and remove any stale index.html.
  --quiet                 Suppress the console summary.
  -h, --help              Show help.
  -V, --version           Show the tool version.
```

The two inputs must currently have the same supported format:
PDF-to-PDF or DOCX-to-DOCX.

| Exit code | Meaning |
| ---: | --- |
| `0` | Comparison completed and policy passed |
| `1` | One or more prohibited changes were found |
| `2` | Input, parsing, configuration, or report generation failed |

Without `--fail-on`, any detected change fails the comparison. Processing
errors always return `2`, regardless of policy.

## Change categories

| Category | Typical examples |
| --- | --- |
| `content` | text inserted, deleted, or replaced |
| `format` | font, size, emphasis, color, or paragraph style changed |
| `layout` | margins, page geometry, position, or reflow changed |
| `media` | an embedded image was added, removed, or replaced |
| `visual` | schema-reserved for a future raster fallback; not emitted in v0.1 |
| `structure` | pages, paragraphs, rows, cells, or other nodes moved or changed |

See [Change categories](docs/categories.md) for classification rules and
[diff.json](docs/diff-json.md) for the report contract.

## GitHub Actions

Pin a released version and upload the report even when the gate fails:

```yaml
name: Document regression

on:
  pull_request:

jobs:
  compare:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - uses: actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68 # v6.0.0
        with:
          dotnet-version: 10.0.x
      - name: Install DocRefract 0.1.1
        run: |
          mkdir -p "$RUNNER_TEMP/docrefract-packages"
          curl --fail --location --retry 3 \
            --output "$RUNNER_TEMP/docrefract-packages/DocRefract.Tool.0.1.1.nupkg" \
            https://github.com/jinyounghub/docrefract/releases/download/v0.1.1/DocRefract.Tool.0.1.1.nupkg
          dotnet tool install --global DocRefract.Tool \
            --version 0.1.1 \
            --source "$RUNNER_TEMP/docrefract-packages"
      - name: Compare generated document
        run: >
          docrefract test/baseline.pdf build/report.pdf
          --out artifacts/docrefract
          --fail-on content,layout,media
      - name: Upload report
        if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: docrefract-report
          path: artifacts/docrefract
```

## How it differs

| | DocRefract | Pixel diff | Word redline |
| --- | --- | --- | --- |
| Primary job | CI regression policy | visual snapshot | authoring review |
| Inputs | PDF and DOCX workflows | rendered images/pages | usually DOCX |
| Explains semantic changes | Yes | No | Yes, for editing changes |
| Separates change categories | Yes | Usually no | Partially |
| Stable machine-readable report | Yes | Tool-specific | Not the focus |
| Offline operation | Yes | Usually | Usually |

DocRefract does not replace a legal redline workflow. v0.1 emits semantic
evidence only and does not promise pixel identity across different renderers,
operating systems, or font installations.

## Determinism and security

`diff.json` excludes timestamps and absolute paths, uses stable ordering, and
records extractor context. For comparable results, pin the DocRefract version
and use the same fonts and renderer profile across CI runs.

Treat every input as untrusted. DocRefract does not fetch external DOCX
relationships or execute embedded content. Reports are self-contained and
escape document text before display. Resource limits bound archive expansion and extracted evidence; v0.1 is not a
hard parser sandbox. See [Security policy](SECURITY.md) for private
reporting and [Determinism](docs/determinism.md) for reproducibility boundaries.

## v0.1 boundaries

The first release intentionally does **not** include:

- DOCX-to-PDF comparison;
- OCR for scanned PDFs;
- a built-in raster visual-diff fallback (`visual` is schema-reserved in v0.1);
- exact Word pagination emulation;
- exact visual equivalence across renderer or font environments;
- three-way merge or tracked-change document generation;
- a desktop GUI or hosted document service.

## Roadmap

- **0.1:** deterministic PDF/DOCX semantic extraction, policy gates, JSON and
  offline HTML reports, and a focused regression fixture corpus.
- **0.2:** richer layout and visual evidence, renderer fingerprints, and
  improved table/move matching.
- **Later:** baseline management, SARIF/JUnit adapters, and opt-in OCR after the
  semantic core is proven.

Roadmap items are direction, not promises. If a missing case matters to your
pipeline, please open a [feature request](https://github.com/jinyounghub/docrefract/issues/new?template=feature.yml).

## Contributing

Small, reproducible document cases are especially valuable. Read
[CONTRIBUTING.md](CONTRIBUTING.md), the
[architecture notes](docs/architecture.md), and the
[Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

## License

Apache License 2.0. See [LICENSE](LICENSE).
