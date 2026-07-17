# Security policy

DocRefract processes complex, potentially hostile PDF and OOXML containers.
Please report security defects privately so maintainers have time to investigate
before public disclosure.

## Supported versions

Until 1.0, only the latest released 0.x minor receives security fixes.

| Version | Supported |
| --- | --- |
| Latest 0.x | Yes |
| Older 0.x | No |
| Unreleased `main` | Best effort |

## Report a vulnerability

Use GitHub's
[private vulnerability reporting](https://github.com/jinyounghub/docrefract/security/advisories/new).
Do not open a public issue.

Include:

- affected DocRefract version and operating system;
- input format and the smallest safe reproduction you can share;
- expected and observed behavior;
- security impact and whether exploitation is reliable;
- logs or stack traces with confidential paths and content removed.

We aim to acknowledge a report within five business days. We will coordinate
validation, remediation, release, and credit with the reporter. This is a
best-effort open-source response target, not a service-level agreement.

## Security boundaries

DocRefract is designed to:

- operate without network access during comparison;
- avoid fetching external OOXML relationships;
- avoid executing macros, scripts, OLE objects, or embedded content;
- escape document-derived values in HTML reports;
- bound archive entry count, expanded size, compression ratios, markup depth,
  extracted nodes/text/images, PDF pages/letters/words, and style inheritance;
- fail with exit code `2` on malformed, encrypted, or unsupported input.

These bounds reduce accidental and common parser-exhaustion cases; v0.1 does
not isolate third-party parsers in a separate worker process or provide a hard
CPU/memory deadline. For hostile inputs, run DocRefract in an OS sandbox or
resource-limited CI container with least privilege. These goals do not make an
arbitrary document safe to open in another application. Keep the tool and
runtime updated.

The offline HTML report contains text and metadata extracted from the supplied
documents. Treat the report as having the same confidentiality as its inputs.
Do not upload it as a public CI artifact unless the source documents are public.

## Out of scope

Reports about an already-known vulnerable .NET runtime or third-party parser
should normally go to that upstream project. Please still contact us privately
if DocRefract's use of a dependency makes the issue exploitable in a new way.
