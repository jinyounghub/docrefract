# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.4] - 2026-07-19

### Added

- Add a conversion-focused Pages landing page, custom social-preview assets, and a reusable observation-mode GitHub Action example with synthetic PDF fixtures.
- Embed a square package icon in the NuGet package.

### Changed

- Put the verified one-shot `dnx` demo before installation details and make the Action adoption path explicit: observe, review evidence, then enforce.
- Link uploaded report artifacts from the composite Action job summary.
- Expand NuGet and Marketplace descriptions and tags for document comparison and regression-testing searches.

### Fixed

- Resume an exact GitHub draft release by paginating authenticated releases because the tag endpoint excludes drafts.

## [0.2.3] - 2026-07-18

### Fixed

- Replace the inaccessible Actions-token immutable-release API preflight with an administrator attestation scoped to the exact release tag, followed by a post-publication immutability assertion.
- Reject a mutable existing release before a resumed NuGet publish, and require the verified public release to be the latest release before success.
- Add a maintainer runbook for immutable GitHub Releases, NuGet OIDC, Marketplace staging, and post-publication verification.

## [0.2.2] - 2026-07-18

### Fixed

- Avoid PowerShell automatic-variable collisions throughout native archive and SPDX verification.
- Run the clean-extracted native SBOM contract on every relevant pull request before a release tag can be created.

## [0.2.1] - 2026-07-18

### Added

- Add `docrefract demo --out <directory>` to generate safe synthetic DOCX inputs and a complete offline report without setup.
- Add the official `jinyounghub/docrefract@v0.2.1` composite Action with report upload, step summary, stable outputs, and preserved CLI exit semantics.
- Publish a live demo report through GitHub Pages.
- Build self-contained archives for Linux, macOS, and Windows on x64 and Arm64, with deterministic packaging and clean-extract smoke checks.
- Prepare the global-tool package for NuGet.org discovery and trusted publishing.

### Changed

- Make the NuGet global tool the primary install path and move source-build instructions behind packaged installs.
- Pin local and CI builds to the .NET `10.0.302` SDK with SDK roll-forward disabled.
- Expand package title, description, tags, license-acceptance, and release-note metadata for search and evaluation.
- Document glibc, code-signing, parser-isolation, rendering, OCR, and cross-format boundaries at the point of installation.
- Normalize NuGet and SPDX artifacts, verify exact release digests, and require GitHub release immutability before publishing.

### Fixed

- Avoid assigning PowerShell 7's read-only `$IsWindows` variable while assembling native SPDX SBOMs.

## [0.1.1] - 2026-07-17

### Fixed

- Documented an install path that uses the package actually attached to GitHub Releases.
- Generate the SPDX SBOM from the packaged runtime payload instead of the source tree.
- Bind the SBOM root to the release package name, version, download URL, license, and SHA-256 digest.
- Include third-party notices in the release checksum manifest.
- Add value, install, quick-start, limitations, and asset guidance to generated release notes.

### Changed

- Centralize package, assembly, CLI, report, and versioned documentation metadata in one CI-enforced build property.
- Validate SBOM runtime identities and exact versions against the packaged dependency graph.
- Isolate read-only release preparation from write-scoped publishing and pin Actions to full commit SHAs.
- Verify installed-tool and report-metadata versions in the cross-platform smoke contract.

## [0.1.0] - 2026-07-17

### Added

- Initial .NET CLI and semantic document model.
- PDF and DOCX extraction foundation.
- Deterministic change categories and policy-based exit codes.
- Versioned JSON and offline HTML report contracts.
- Cross-platform build, test, package, installed-tool smoke, and release automation.
- Bounded local parsing, deterministic fixture generation, and adversarial regression cases.

[Unreleased]: https://github.com/jinyounghub/docrefract/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/jinyounghub/docrefract/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/jinyounghub/docrefract/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/jinyounghub/docrefract/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/jinyounghub/docrefract/compare/v0.1.1...v0.2.1
[0.1.1]: https://github.com/jinyounghub/docrefract/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jinyounghub/docrefract/releases/tag/v0.1.0
