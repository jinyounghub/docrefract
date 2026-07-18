# Release runbook

DocRefract releases are fail-closed around version synchronization, native
archives, SPDX SBOMs, checksums, and NuGet trusted publishing. GitHub release
immutability is administrator-attested for the exact tag before staging and
asserted again after publication. Run these steps from an
administrator-authenticated `gh` session.

## Before creating a tag

1. Require all pull-request checks, including `verify-native-sbom-contract`, to
   pass on the exact commit that will become `main`.
2. Confirm that immutable releases are enabled:

   ```powershell
   $setting = gh api repos/jinyounghub/docrefract/immutable-releases |
     ConvertFrom-Json
   if (-not [bool]$setting.enabled) {
       throw "Immutable GitHub releases are not enabled."
   }
   ```

3. Record that administrator check for the exact version tag. The Actions
   `GITHUB_TOKEN` cannot read this admin-only repository setting, so the workflow
   rejects every tag except the one named by this repository variable:

   ```powershell
   $tag = "vX.Y.Z"
   gh variable set IMMUTABLE_RELEASES_ATTESTED_TAG `
     --repo jinyounghub/docrefract `
     --body $tag
   ```

   Set this variable immediately before pushing the tag, and do not change the
   immutable-releases setting until the workflow finishes.

4. Confirm that the `nuget` environment allows only `v*` tags and contains the
   `NUGET_USER` secret expected by `NuGet/login` trusted publishing.
5. Create an annotated tag on the exact current `origin/main` commit, then push
   only that tag.

## While the workflow runs

The workflow performs these gates in order:

1. build, test, pack, normalize, and smoke the .NET tool;
2. build and smoke six self-contained native archives;
3. generate seven SPDX SBOMs and verify the exact 16-asset bundle;
4. create a draft GitHub release and verify every asset digest;
5. publish and re-download the exact NuGet package through OIDC;
6. publish the draft and require the resulting release to report
   `immutable: true` with the same 16 assets.

If publishing the Action to GitHub Marketplace, configure the draft release
before the protected NuGet environment wait expires. Do not publish the draft
manually; the workflow publishes only after NuGet verification succeeds.

## After publication

- Confirm the workflow is successful and the release is public, latest, and
  immutable.
- Confirm all 16 assets and their API digests match `SHA256SUMS`.
- Install the exact version from NuGet.org in a fresh tool directory and run
  `docrefract --version` plus the smoke fixtures.
- Confirm the GitHub Pages demo and Marketplace listing are public.
- Remove any temporary environment wait timer added for Marketplace setup.
- Publish the release announcement only after every check above passes.
