# Runnable GitHub Action example

This directory pairs a generic consumer workflow template with a live repository contract. The contract exercises the pinned published DocRefract Action against two tiny synthetic PDFs containing one intentional content change, proving evidence upload and policy behavior without using private documents.

> [!WARNING]
> The Action uploads HTML and JSON reports that can contain extracted text and metadata. Treat each artifact with the same confidentiality as its inputs; do not publish confidential reports through public-repository workflows.

- [Copy the consumer workflow template](document-regression.yml)
- [Inspect live example runs](https://github.com/jinyounghub/docrefract/actions/workflows/consumer-example.yml)
- [Open the generated report used on GitHub Pages](https://jinyounghub.github.io/docrefract/report/)

## What the first run demonstrates

1. The Action downloads the pinned package and verifies it against the immutable release checksum manifest.
2. DocRefract classifies the known text replacement as `content` and returns exit code `1`.
3. `continue-on-error: true` keeps the learning run green while preserving the failed step outcome.
4. The Action uploads `diff.json` and the self-contained HTML report; the example uses `artifact-url` to add a direct job-summary link.
5. A final assertion confirms the expected outcome, exit code, and artifact URL.

## Adapt it to your pipeline

1. Commit an approved output as a baseline, for example `test/baselines/report.pdf`.
2. Copy the [consumer workflow template](document-regression.yml) into `.github/workflows/` in your repository.
3. Add your existing build command before the comparison so it creates the candidate, for example `build/report.pdf`.
4. Change `before`, `after`, and `fail-on` for your pipeline, then run with `continue-on-error: true` while you review the evidence.
5. Remove `continue-on-error: true` when the policy is ready to block pull requests.

The sample fixtures are deliberately small and synthetic. Replace them with outputs from your own generator; do not commit confidential documents just to create a CI baseline.