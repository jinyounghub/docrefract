# Change categories

Categories let a repository state what matters. They are not severity levels:
a one-character `content` edit may be more important than a full-page visual
refresh.

## `content`

Human-readable text was inserted, deleted, or replaced. Whitespace is
normalized only where the source format makes it representational rather than
meaningful.

Examples:

- `Total: 125` becomes `Total: 152`;
- a sentence is added;
- text is removed from one table cell.

## `format`

The content is stable, but its presentation attributes changed.

Examples:

- font family, size, weight, italic, underline, or color;
- DOCX paragraph or character style;
- alignment or spacing classified as styling rather than geometry.

## `layout`

A node's page geometry, flow, or page setup changed while the semantic content
remained matchable.

Examples:

- page margin, orientation, or an explicit page/column break;
- a table grid width changes while cell text remains stable;
- a matched block or floating image moves materially;
- text reflows onto another page.

Layout confidence depends on available geometry. DOCX pagination is not claimed
to reproduce Microsoft Word exactly.

## `media`

An embedded media asset was inserted, deleted, replaced, or relinked.

Examples:

- a logo image changes;
- an inline image is removed;
- media bytes change while the surrounding text remains stable.

## `visual`

Rendered appearance changed, but the semantic extractors cannot assign a
stronger category with sufficient confidence.

Visual evidence is renderer-dependent. Results from different renderer/font
profiles are advisory and must not be described as exact cross-platform
equivalence.

The `visual` value is reserved in the 1.0 report schema and policy grammar.
The v0.1 built-in extractors do not raster-render documents, so they do not
emit this category yet.

## `structure`

Logical document organization changed.

Examples:

- page, paragraph, row, or cell inserted/deleted as a unit;
- a matched block moves to another logical location;
- table topology changes.

Text within a newly inserted structure can be represented by the structure
change rather than duplicated as a large set of content insertions. The
diff engine favors the smallest useful explanation.

## Classification precedence

When evidence overlaps, DocRefract applies these principles:

1. Preserve a strong semantic match before interpreting visual displacement.
2. Report the smallest change set that explains the edit.
3. Use `content`, `format`, `layout`, `media`, or `structure` when evidence is
   strong enough.
4. Use `visual` as evidence of unexplained appearance change, not as a duplicate
   for every semantic change.
5. Expose uncertainty through confidence and warnings.
