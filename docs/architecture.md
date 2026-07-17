# Architecture

DocRefract is a document regression tester, not a general-purpose editor. Its
architecture keeps parser-specific details outside the policy and reporting
layers.

```text
before.pdf/docx ─┐
                 ├─> bounded input preflight
after.pdf/docx ──┘
                         │
                         v
                 format extractor
                         │
                         v
               canonical document IR
                         │
                         v
           deterministic matching + diff
                         │
               ┌─────────┴─────────┐
               v                   v
          policy gate        report writers
           exit 0/1       diff.json + index.html

Any processing failure exits 2.
```

## Layers

### Input preflight

Preflight identifies the format, rejects mismatched or unsupported input, and
applies resource bounds before expensive parsing. DOCX packages are checked for
archive entry count, expanded size, and suspicious compression ratios.
External relationships are data, never instructions to fetch.

### Extractors

Each extractor projects source-specific structures into a shared document
snapshot:

- stable logical anchor;
- node kind;
- normalized text;
- canonical style and layout signatures;
- optional page and normalized bounding box;
- optional media digest;
- extractor warnings.

PDF extraction uses glyph, word, and geometry evidence. DOCX extraction uses
OOXML body, table, header, footer, note, style, and relationship structures.
Package metadata such as ZIP entry order and volatile `rsid` values does not
become a semantic node.

### Canonical intermediate representation

The intermediate representation is deliberately smaller than either source
format. It contains only information that can participate in matching,
classification, policy, or evidence.

Anchors describe logical positions such as:

```text
body/p[0004]
body/t[0002]/r[0003]/c[0001]/p[0001]
page[0007]/block[0012]
```

Anchors are deterministic identifiers, not globally persistent object IDs.
Matching may connect different before/after anchors when a node moves.

### Matching and classification

Matching is deterministic and ordered. Strong evidence—exact anchor, node kind,
normalized content, and local context—is preferred over fuzzy similarity. A
weak match lowers confidence rather than inventing a precise semantic change.

Classification follows the rules in [categories.md](categories.md). One
underlying edit should produce the smallest useful change set. For example, a
single number replacement should not become dozens of layout edits merely
because surrounding text reflowed.

### Policy

Policy is a pure function of the final change records and the `--fail-on`
category set. It never suppresses parser or report failures:

- no prohibited category: exit `0`;
- prohibited category found: exit `1`;
- comparison cannot be completed: exit `2`.

### Reports

`diff.json` is the automation contract. The offline HTML report is a view of
the same data and must not reinterpret policy. Document-derived strings are
escaped and no external resource is required to open the report.

## Dependency principles

- Prefer permissively licensed libraries that can ship in an Apache-2.0 tool.
- Keep extractors replaceable behind the canonical model.
- Do not call a hosted service during comparison.
- Do not make the semantic result depend on a specific visual renderer.
- Record parser/renderer versions when their behavior can affect evidence.

Current foundational libraries and licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
