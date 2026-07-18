# DocRefract

[![CI](https://github.com/jinyounghub/docrefract/actions/workflows/ci.yml/badge.svg)](https://github.com/jinyounghub/docrefract/actions/workflows/ci.yml)
[![NuGet](https://img.shields.io/nuget/v/DocRefract.Tool.svg)](https://www.nuget.org/packages/DocRefract.Tool/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![.NET 10](https://img.shields.io/badge/.NET-10.0-512BD4)](https://dotnet.microsoft.com/)

**See what changed—not just where pixels moved.**

DocRefract is an open-source PDF diff and DOCX diff tool: a document regression testing CLI for local-first, deterministic CI. It classifies changes as `content`, `format`, `layout`, `media`, `visual`, or `structure`, then produces machine-readable JSON and a self-contained HTML report without uploading documents to a service.

[Install](#install) · [Try demo](#try-the-demo) · [Live report](https://jinyounghub.github.io/docrefract/) · [GitHub Action](#github-action)

![DocRefract offline comparison report](https://raw.githubusercontent.com/jinyounghub/docrefract/main/docs/assets/report-preview.png)

```console
docrefract baseline.docx candidate.docx --out report --fail-on content,layout
```

Exit code `1` fails a build only when a prohibited category changes. Exit code `2` is reserved for usage, input, parsing, or report-generation errors.

> [!IMPORTANT]
> DocRefract is an early alpha. Pin version `0.2.1` in automation and review the [current boundaries](#current-boundaries) before using it as a release gate.

## Install

### NuGet global tool

Install the pinned release from [NuGet.org](https://www.nuget.org/packages/DocRefract.Tool/). This path requires the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```console
dotnet tool install --global DocRefract.Tool --version 0.2.1
```

Confirm the command is available:

```console
docrefract --version
```

If DocRefract is already installed:

```console
dotnet tool update --global DocRefract.Tool --version 0.2.1
```

Open a new terminal if `docrefract` is not yet on `PATH`.

### Self-contained native archives

If the global tool is unsuitable, the [v0.2.1 GitHub Release](https://github.com/jinyounghub/docrefract/releases/tag/v0.2.1) provides six self-contained fallback archives that do not require a separately installed .NET runtime.

| Platform | Architecture | Release asset |
| --- | --- | --- |
| Linux | x64 | `docrefract-0.2.1-linux-x64.tar.gz` |
| Linux | Arm64 | `docrefract-0.2.1-linux-arm64.tar.gz` |
| macOS | Intel x64 | `docrefract-0.2.1-osx-x64.tar.gz` |
| macOS | Apple silicon | `docrefract-0.2.1-osx-arm64.tar.gz` |
| Windows | x64 | `docrefract-0.2.1-win-x64.zip` |
| Windows | Arm64 | `docrefract-0.2.1-win-arm64.zip` |

For example, on Linux x64:

```console
tar -xzf docrefract-0.2.1-linux-x64.tar.gz
./docrefract-0.2.1-linux-x64/docrefract --version
```

On Windows x64 in PowerShell:

```powershell
Expand-Archive .\docrefract-0.2.1-win-x64.zip
.\docrefract-0.2.1-win-x64\docrefract.exe --version
```

The Linux builds target glibc-based distributions; musl/Alpine is not supported yet. The macOS and Windows archives are not code-signed in v0.2.1, so Gatekeeper or SmartScreen may warn. Do not weaken operating-system security controls; use the NuGet tool install when an unsigned executable is not acceptable.

To verify downloaded release assets:

```console
gh release download v0.2.1 --repo jinyounghub/docrefract --dir .docrefract-release
cd .docrefract-release
sha256sum --check SHA256SUMS
```

On macOS, use `shasum -a 256 --check SHA256SUMS`. In PowerShell, compare each manifest entry with `Get-FileHash -Algorithm SHA256`.

## Try the demo

Generate two safe synthetic DOCX files and a complete report in about 30 seconds:

```console
docrefract demo --out report
```

Open `report/index.html` to explore the result, or inspect `report/diff.json` for the stable automation contract. The demo intentionally contains known changes and returns exit code `0`; it does not read your documents.

No installation available right now? Open the same generated report at [jinyounghub.github.io/docrefract](https://jinyounghub.github.io/docrefract/).

## Compare documents

```console
docrefract path/to/before.pdf path/to/after.pdf \
  --out artifacts/docrefract \
  --fail-on content,layout,media
```

The two inputs must currently have the same supported format: PDF-to-PDF or DOCX-to-DOCX. Open `artifacts/docrefract/index.html` for review or consume `artifacts/docrefract/diff.json` from another tool.

### CLI contract

```text
docrefract <before> <after> --out <directory> [options]
docrefract demo --out <directory>

Options:
  --out <directory>       Write diff.json and index.html to this directory.
  --fail-on <categories>  `any` or a comma-separated policy:
                          content,format,layout,media,visual,structure
  --json-only             Write diff.json and remove any stale index.html.
  --quiet                 Suppress the console summary.
  -h, --help              Show help.
  -V, --version           Show the tool version.
```

| Exit code | Meaning |
| ---: | --- |
| `0` | Comparison passed, or the demo completed successfully |
| `1` | Comparison completed and one or more prohibited changes were found |
| `2` | Usage, input, parsing, configuration, or report generation failed |

Without `--fail-on`, any detected change fails the comparison. Processing errors always return `2`, regardless of policy.

## GitHub Action

The official composite Action installs the pinned tool, runs the comparison, uploads the report even when the policy fails, and writes a job summary.

```yaml
name: Document regression

on:
  pull_request:

permissions:
  contents: read

jobs:
  compare:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
      - name: Generate candidate document
        run: |
          ./scripts/generate-report.sh # Replace with your document generator.
          test -f build/report.pdf
      - name: Compare generated document
        uses: jinyounghub/docrefract@v0.2.1
        with:
          before: test/baseline.pdf
          after: build/report.pdf
          fail-on: content,layout,media
          out: artifacts/docrefract
```

This example assumes `test/baseline.pdf` is committed and the generation step writes `build/report.pdf`. Replace the command and paths with your own pipeline.

The Action exposes `exit-code`, `report-path`, `json-path`, `html-path`, `artifact-id`, and `artifact-url` outputs. Exit codes keep the same CLI meaning, so a prohibited change fails the step after the evidence has been uploaded.

Official release packages are checked against `SHA256SUMS` on an immutable GitHub Release. If you override `source`, keep `source` and `version` as workflow-owned literals rather than pull-request data; direct non-official HTTPS `.nupkg` URLs also require the `sha256` input, and HTTP is rejected.

## Why DocRefract?

Document pipelines break in ways ordinary snapshot tests do not explain:

- a total changes while the page still looks almost identical;
- a font fallback moves content onto another page;
- a table cell changes but a full-page pixel diff becomes noisy;
- a regenerated DOCX changes package metadata even though its content does not.

DocRefract gives PDF and DOCX pipelines one offline CI contract:

- **Semantic changes:** distinguish text, styling, geometry, media, and document structure.
- **Stable automation:** canonical anchors and ordered JSON make results suitable for baselines, code review, and policy checks.
- **Useful evidence:** inspect an offline HTML report without uploading confidential documents to a service.
- **Intentional gates:** fail on `content` and `layout`, for example, while allowing an approved formatting refresh.

## Change categories

| Category | Typical examples |
| --- | --- |
| `content` | text inserted, deleted, or replaced |
| `format` | font, size, emphasis, color, or paragraph style changed |
| `layout` | margins, page geometry, position, or reflow changed |
| `media` | an embedded image was added, removed, or replaced |
| `visual` | schema-reserved for a future raster fallback; not emitted in v0.2 |
| `structure` | pages, paragraphs, rows, cells, or other nodes moved or changed |

See [Change categories](docs/categories.md) for classification rules and [diff.json](docs/diff-json.md) for the report contract.

## How it differs

| | DocRefract | Pixel diff | Word redline |
| --- | --- | --- | --- |
| Primary job | CI regression policy | visual snapshot | authoring review |
| Inputs | PDF and DOCX workflows | rendered images/pages | usually DOCX |
| Explains semantic changes | Yes | No | Yes, for editing changes |
| Separates change categories | Yes | Usually no | Partially |
| Stable machine-readable report | Yes | Tool-specific | Not the focus |
| Offline operation | Yes | Usually | Usually |

DocRefract does not replace a legal redline workflow and does not promise pixel identity across different renderers, operating systems, or font installations.

## Determinism and security

`diff.json` excludes timestamps and absolute paths, uses stable ordering, and records extractor context. For comparable results, pin the DocRefract version and use the same fonts and renderer profile across CI runs.

Treat every input as untrusted. DocRefract does not fetch external DOCX relationships or execute embedded content. Reports are self-contained and escape document text before display. Resource limits bound archive expansion and extracted evidence, but DocRefract is not a hard parser sandbox. See the [Security policy](SECURITY.md) for private reporting and [Determinism](docs/determinism.md) for reproducibility boundaries.

## Current boundaries

v0.2.1 intentionally does not include:

- PDF-to-DOCX or DOCX-to-PDF comparison;
- OCR for scanned or image-only PDFs;
- a built-in raster visual-diff fallback (`visual` remains schema-reserved);
- exact Microsoft Word pagination or layout emulation;
- exact visual equivalence across renderer, operating-system, or font environments;
- three-way merge or tracked-change document generation;
- a desktop GUI, hosted document service, or hard parser sandbox;
- musl Linux binaries or signed/notarized macOS and Windows executables.

## Build from source

Use this path when developing DocRefract rather than for a normal installation. It requires the exact [.NET 10.0.302 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```console
git clone https://github.com/jinyounghub/docrefract.git
cd docrefract
dotnet restore --locked-mode
dotnet test --configuration Release --no-restore
dotnet run --project src/DocRefract.Cli -- demo --out report
```

To build and install a local package:

```console
dotnet pack src/DocRefract.Cli -c Release -o artifacts/packages
dotnet tool install --global DocRefract.Tool --version 0.2.1 --source artifacts/packages
```

## Roadmap

- **Shipped in 0.2:** one-command synthetic demo, live report, official GitHub Action, NuGet global-tool distribution, and self-contained archives for six OS/architecture targets.
- **Next:** richer layout evidence, renderer fingerprints, improved table/move matching, and CI adapters such as SARIF or JUnit.
- **Later:** baseline management and opt-in OCR or raster evidence after the deterministic semantic core is proven.

Roadmap items are direction, not promises. If a missing case matters to your pipeline, open a [feature request](https://github.com/jinyounghub/docrefract/issues/new?template=feature.yml) with a small synthetic reproduction.

## Contributing

Small, reproducible document cases are especially valuable. Read [CONTRIBUTING.md](CONTRIBUTING.md), the [architecture notes](docs/architecture.md), and the [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

## License

Apache License 2.0. See [LICENSE](LICENSE).
