# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/jinyounghub/docrefract/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/jinyounghub/docrefract/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jinyounghub/docrefract/releases/tag/v0.1.0
