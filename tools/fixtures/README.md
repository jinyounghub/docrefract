# Deterministic regression fixtures

`generate_fixtures.py` is the source of truth for the small DOCX and PDF files
used by `DocRefract.Tests`. It deliberately varies only one document signal per
fixture pair:

| Pair | Expected semantic result |
| --- | --- |
| `docx_metadata_*` | no changes; package order, core metadata, and `w:rsid*` are ignored |
| `docx_text_*` | one `content/replace` |
| `docx_table_*` | one table-cell `content/replace` |
| `docx_style_*` | one `format/replace` |
| `pdf_text_*` | one `content/replace` |
| `pdf_identical.pdf` compared with itself | no changes |

The DOCX generator applies the `standard_business_brief` fixture token map:
US Letter, 1-inch margins, Calibri 11 pt body text, explicit paragraph spacing,
and fixed-DXA table geometry. The PDFs use ReportLab invariant mode.

Generate or refresh:

```powershell
& $env:CODEX_BUNDLED_PYTHON tools/fixtures/generate_fixtures.py
```

Verify byte-for-byte reproducibility:

```powershell
& $env:CODEX_BUNDLED_PYTHON tools/fixtures/generate_fixtures.py --check
```

`tests/DocRefract.Tests/Fixtures/manifest.json` records stable SHA-256 hashes so
fixture drift is visible in code review. Do not edit generated binaries by hand.
