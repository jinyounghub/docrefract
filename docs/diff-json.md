# `diff.json` contract

`diff.json` is the machine-readable output of every successful comparison. The
root `schemaVersion` identifies its compatibility family.

The initial schema has this shape:

```json
{
  "schemaVersion": "1.0",
  "engine": {
    "toolVersion": "0.2.1",
    "beforeExtractor": "openxml-3.5.1",
    "afterExtractor": "openxml-3.5.1"
  },
  "before": {
    "name": "baseline.docx",
    "kind": "docx",
    "sha256": "…"
  },
  "after": {
    "name": "candidate.docx",
    "kind": "docx",
    "sha256": "…"
  },
  "summary": {
    "total": 1,
    "content": 1,
    "format": 0,
    "layout": 0,
    "media": 0,
    "visual": 0,
    "structure": 0
  },
  "changes": [
    {
      "id": "chg-0001",
      "category": "content",
      "operation": "replace",
      "beforeAnchor": "body/t[0001]/r[0002]/c[0003]/p[0001]",
      "afterAnchor": "body/t[0001]/r[0002]/c[0003]/p[0001]",
      "beforeText": "125",
      "afterText": "152",
      "confidence": 1.0
    }
  ],
  "warnings": []
}
```

The ellipsis above is illustrative; real SHA-256 values are lowercase
hexadecimal strings.

`engine` records the pinned tool version and the extractor used for each input.
Consumers can use these fields to reject comparisons produced by an
incompatible extraction profile.

## Source descriptors

`name` is a display-safe file name, never an absolute path. `sha256` identifies
the exact input bytes. `kind` is `pdf` or `docx`.

## Change records

Every change has:

- deterministic `id`, ordered by canonical document position and change kind;
- `category` from the public category set;
- `operation`: `insert`, `delete`, `replace`, or `move`;
- optional before/after anchors and evidence;
- decimal `confidence` in the inclusive range 0–1.

Text, style, or bounding-box fields are omitted or `null` when that evidence is
not applicable. Coordinates are normalized to the extractor's documented
top-left coordinate space.

Consumers should ignore unknown additive fields within a compatible schema
family. They must not infer policy from `summary`; policy is evaluated from the
change records and requested category set.

## Warnings

Warnings describe incomplete or ambiguous evidence, such as a missing embedded
font or an unsupported tracked-change construct. A warning does not by itself
change exit code. A condition that prevents a trustworthy comparison is a
processing error and returns exit code `2` instead of producing a successful
report.

## Compatibility

Before 1.0 of the tool, the report schema remains explicitly versioned but may
change. Pin the DocRefract package version in automation. A future incompatible
shape will receive a new `schemaVersion` and migration notes in the changelog.
