# Determinism

DocRefract separates deterministic semantic output from renderer-dependent
visual evidence.

## Semantic contract

For the same input bytes, DocRefract version, and options, repeated runs must
produce byte-identical `diff.json`.

The writer therefore:

- emits fields and collections in a stable order;
- uses invariant number and enum formatting;
- omits timestamps, process IDs, temporary paths, and absolute source paths;
- derives IDs from canonical data rather than random values;
- normalizes source-specific volatile metadata before matching;
- ends the UTF-8 JSON file consistently.

Filesystem enumeration, hash-map order, current locale, and local time must not
affect semantic changes or policy.

## Cross-platform semantics

The target is the same semantic change set across supported operating systems.
Parser library updates can alter extraction behavior, so CI baselines should
pin the DocRefract version and review upgrade diffs.

Font substitution and text extraction behavior may vary when a PDF does not
embed the required fonts. DocRefract records warnings instead of silently
claiming certainty.

## Visual profiles

Rasterization is evidence, not the semantic source of truth. Exact visual
comparison is meaningful only when these are held constant:

- renderer and version;
- operating system and architecture;
- installed fonts and font configuration;
- rendering scale, color profile, and antialiasing settings.

Reports produced with different visual profiles may still be inspected, but
their pixel-level results must be treated as advisory. A future report profile
will make these inputs explicit.

## Baseline advice

- Pin the DocRefract tool version.
- Generate baseline and candidate in the same CI image where practical.
- Embed fonts in PDFs.
- Keep source inputs, not generated HTML reports, as long-term baselines.
- Review `warnings` before accepting a change.
- Regenerate a baseline intentionally; do not update it automatically after a
  failed gate.

## Testing determinism

A deterministic fixture test should compare:

1. the exact ordered changes;
2. exact anchors and categories;
3. exact serialized `diff.json` bytes from two independent runs;
4. exit behavior for at least one allowed and one prohibited policy.
