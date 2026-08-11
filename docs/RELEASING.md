# Releasing the maintained fork

Fork releases are built from immutable version tags by [the signed release workflow](../.github/workflows/release.yml). The workflow uses Developer ID signing, Apple notarization, and the fork's Sparkle key. It publishes the four files produced by `Scripts/package_release.sh` without rebuilding them in the publishing job.

## One-time GitHub configuration

Create an environment named `release` in `jacobcxdev/XcodesApp`. Add required reviewers and prevent self-review when another trusted reviewer is available. The environment protection rule must allow only protected tags matching `v*`; do not allow branches or unprotected tags. The environment applies to the whole packaging job, so this exact tag restriction is the external security boundary that prevents a branch-triggered job from gaining release secrets. Keep environment administrators able to stop a compromised run.

Add these environment secrets. Do not add them as repository variables or commit their values:

| Secret | Required format |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64 of the binary Developer ID Application `.p12`, with no surrounding quotes. Generate with `base64 < certificate.p12`. |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Raw password used when exporting that `.p12`. |
| `RELEASE_KEYCHAIN_PASSWORD` | Raw random password used only for the temporary CI Keychain. It does not need to match a local Keychain password. |
| `APP_STORE_CONNECT_API_KEY_ID` | Raw App Store Connect API key identifier, for example `ABC123DEFG`. |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Raw App Store Connect issuer UUID. |
| `APP_STORE_CONNECT_API_PRIVATE_KEY` | Complete raw contents of the matching `AuthKey_*.p8`, including PEM header, footer, and newlines. |
| `SPARKLE_PRIVATE_KEY` | Complete raw contents exported by Sparkle `generate_keys --account dev.jacobcx.Xcodes -x <private-key-file>`. |

Use a Developer ID Application certificate for team `K2648T24P4`. Keep the `.p12`, its password, the API private key, and exported Sparkle key outside this repository. The workflow writes them with mode `077`, imports the certificate into a temporary Keychain, and removes private files and the Keychain even when packaging fails or is cancelled.

Add repository Actions secret `INDEX_REPO_TOKEN`. Scope it to write only `jacobcxdev/jacobcxdev.github.io`; it publishes verified appcasts through that repository's pinned composite action. Do not add this token to the protected release environment because packaging never needs it.

Configure GitHub Actions to allow selected pinned actions. Protect the `v*` tag namespace against rewriting or deletion with a repository ruleset, and require release tags to target commits already on `main`; the workflow applies the stricter `vX.Y.ZbN` grammar and verifies `origin/main` ancestry before credentials are imported. XcodesApp must not enable GitHub Pages or maintain a `gh-pages` branch. Central documentation infrastructure serves feeds from `https://docs.jacobcx.dev/repo/1330187036/updates/appcast.xml` and `appcast-prereleases.xml`.

## Prepare a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Run local contracts and unsigned verification:

   ```sh
   bash Scripts/check_fork_identity.sh
   bash Scripts/test_fork_identity_guard.sh
   bash Scripts/check_appcast_identity.sh
   bash Scripts/test_appcast_contracts.sh
   bash Scripts/test_release_scripts.sh
   bash Scripts/test_release_artifacts.sh
   bash Scripts/test_ci_release_workflows.sh
   ruby Scripts/check_localizations.rb
   bash Scripts/test_localization_contract.sh
   xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test CODE_SIGNING_ALLOWED=NO
   xcodebuild build -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug CODE_SIGNING_ALLOWED=NO
   ```

3. Commit the version change. Create an annotated tag whose values exactly match the project, for example:

   ```sh
   git tag -a v4.0.5b45 -m 'Xcodes 4.0.5 build 45'
   git push origin v4.0.5b45
   ```

4. Approve the protected `release` environment deployment after confirming the tag and commit.
5. Confirm the GitHub release contains `Xcodes.zip`, `Xcodes.zip.sha256`, `sparkle-signature.txt`, and `release-manifest.txt`.
6. Confirm the final reusable-appcast job completes and the stable feed references the exact ZIP and Sparkle signature. Releases created with GitHub Actions' `GITHUB_TOKEN` do not emit another workflow-triggering release event, so the release workflow calls the local appcast workflow explicitly and passes the published tag. Reusable workflows receive the caller's `github.ref`; the appcast build requires that ref to equal `refs/tags/<tag>` and verifies the checked-out tag commit and `main` ancestry before executing repository code. Before central publication, the appcast workflow paginates every published non-draft release, verifies each tag exists on `main`, downloads exactly four assets per release into tag-scoped temporary directories, and validates every checksum, manifest, release-body signature, Ed25519 signature, and embedded app identity and version. Jekyll receives only the resulting sanitised release data and validator-produced signature map; the rendered stable and prerelease feeds must exactly match validated release sets. The secret-bearing publish job then invokes the pinned central publisher with only verified XML files.

Tags using this contract are stable releases. The workflow does not infer prerelease status from the build-number suffix. Add an explicit, reviewed tag grammar and matching appcast policy before publishing prereleases.

For a manual rerun, `workflow_dispatch` reruns must use `--ref v4.0.5b45` and the same `release_tag`; selecting a branch is rejected before credential files are written:

```sh
gh workflow run release.yml --ref v4.0.5b45 -f release_tag=v4.0.5b45
```

A manual appcast rerun must likewise use the published tag for both the workflow ref and input (`--ref <tag> -f tag=<same tag>`):

```sh
gh workflow run appcast.yml --ref v4.0.5b45 -f tag=v4.0.5b45
```

## Local packaging dry run

`Scripts/test_release_scripts.sh` exercises packaging and notarization boundaries with fake tools and no credentials. A real local package requires the exact tag at `HEAD`, a clean tracked worktree, the Developer ID certificate, App Store Connect key variables, and the Sparkle private key:

```sh
export NOTARY_KEY_ID='<key identifier>'
export NOTARY_ISSUER_ID='<issuer UUID>'
export NOTARY_KEY_PATH='/absolute/path/AuthKey_ID.p8'
export SPARKLE_PRIVATE_KEY_FILE='/absolute/path/sparkle-private-key'
bash Scripts/package_release.sh v4.0.5b45
bash Scripts/validate_release_artifacts.sh Product/v4.0.5b45 v4.0.5b45
```

Do not paste secret values into shell history on shared machines. Prefer a local secret manager or a short-lived protected shell environment.

## Failure recovery

- Packaging failure: fix the cause and rerun the same workflow with `workflow_dispatch`, the existing tag input, and that tag as the workflow ref. Packaging does not publish partial `Product/<tag>/` output.
- Publishing failure before a GitHub release exists: rerun the same tag. The publish job revalidates the downloaded artifact before creating the release.
- GitHub release already exists: the workflow refuses to replace it. Inspect assets and appcast state. Delete a bad release only after preserving evidence and deciding whether the immutable tag can remain valid; otherwise issue a new build number and tag.
- Appcast failure after a valid release: Inspect every published non-draft release because an invalid historical release blocks both feeds instead of being silently skipped. Rerun the same appcast tag only for transient infrastructure or central-host configuration failures when tagged source is unchanged. Complete published release history must also be unchanged. Do not replace signed release assets under an existing tag. Any workflow, validator, or source fix requires an incremented build number, a new immutable `vX.Y.ZbN` tag, and a new release. A release-history correction likewise requires a new build and immutable tag.
- Suspected key exposure: disable workflows, revoke affected Apple credentials or certificate, rotate the Sparkle key with an app update signed by the still-trusted old key, and document the incident before resuming releases.
