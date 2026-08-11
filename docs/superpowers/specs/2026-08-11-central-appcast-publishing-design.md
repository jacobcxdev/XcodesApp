# Central Appcast Publishing Design

## Goal

Keep Sparkle automatic updates without enabling GitHub Pages or maintaining a
`gh-pages` branch in XcodesApp. Publish verified appcasts through the existing
`docs.jacobcx.dev` site, following the same source-repository-to-central-index
pattern used by `rust-composable-architecture` and `gemini-mcp-tool`.

## Ownership

- XcodesApp owns release creation, release-history validation, appcast
  generation, and appcast content.
- `jacobcxdev.github.io` owns static hosting and GitHub Pages deployment.
- XcodesApp never enables Pages, creates `gh-pages`, or deploys a site.
- No Xcodes documentation is published as part of this work.

## Publication Flow

1. XcodesApp signs, notarises, validates, and publishes an immutable GitHub
   release.
2. XcodesApp validates complete release history and renders both Sparkle feeds.
3. XcodesApp checks out the central index repository at an immutable action
   revision.
4. A central composite action validates the two expected XML files and commits
   them to the stable repository identity path
   `public/repo/1330187036/updates/` in the central repository.
5. The central repository's existing build deploys them at:
   - `https://docs.jacobcx.dev/repo/1330187036/updates/appcast.xml`
   - `https://docs.jacobcx.dev/repo/1330187036/updates/appcast-prereleases.xml`
6. XcodesApp's stable and prerelease feed settings use those URLs.

## Publisher Contract

The central publisher accepts exactly two regular, non-empty XML files. It
parses both before publication, rejects symlinks and unexpected entries,
publishes through an isolated staging directory, and updates only
`public/repo/1330187036/updates/`. The numeric repository ID follows the
central site's canonical stable-identity rule. It uses the existing
`INDEX_REPO_TOKEN` model used by other source repositories. XcodesApp's
secret-bearing publication job receives
only that token and the already verified appcast artifact.

## Branch and Release Policy

- XcodesApp work lands through a `jacobcxdev/*` topic branch and pull request.
- Central-site source work follows its `dev/next` workflow, then merges to
  `main` so the composite action is available from the stable branch.
- XcodesApp pins the central action checkout to the exact central merge commit.
- XcodesApp advances build number and creates a new immutable `vX.Y.ZbN` tag;
  existing releases and tags remain unchanged.

## Verification

- Central publisher tests cover valid feeds, missing/extra files, malformed
  XML, symlinks, unchanged output, and failed push behaviour.
- Xcodes workflow mutation tests reject Pages deployment, `gh-pages`, unpinned
  central checkout, token exposure, wrong destination, and bypassed XML checks.
- Xcodes tests, unsigned build, workflow lint, shell lint, identity guards, and
  release-contract suites pass.
- Published release completes signing, notarisation, stapling, GitHub Release,
  central appcast publication, and live feed validation.
- XcodesApp repository reports `has_pages: false` and has no `gh-pages` ref.
