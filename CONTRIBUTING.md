# Contributing to Xcodes

Contributions to this maintained fork are welcome. Use [jacobcxdev/XcodesApp issues](https://github.com/jacobcxdev/XcodesApp/issues) for bug reports and feature requests, and send fork pull requests to `jacobcxdev/XcodesApp`.

## Choose the correct branch lane

- Use `jacobcxdev/<topic>` from `origin/main` for fork features, packaging, release work, or changes that depend on fork identity.
- Use `upstream/<topic>` from `upstream/main` for portable changes intended for [XcodesOrg/XcodesApp](https://github.com/XcodesOrg/XcodesApp).
- Use `sync/upstream-YYYYMMDD` from `origin/main` when integrating upstream changes into the fork.

See [FORKING.md](FORKING.md) for exact remote and branch commands. Keep upstream branches free of fork-only identifiers, packaging, and documentation so their commits remain easy to review upstream.

## Pull requests

1. Create the correct branch for the intended destination.
2. Keep each change focused and preserve existing project style.
3. Add or update tests for changed behaviour.
4. Run the relevant tests and `bash Scripts/check_fork_identity.sh`.
5. Document user-visible behaviour.
6. Open the pull request against the intended repository and base branch.

For fork work, open a pull request at [jacobcxdev/XcodesApp/pulls](https://github.com/jacobcxdev/XcodesApp/pulls). For portable upstream work, push the `upstream/<topic>` branch to this fork. Then open a pull request from that branch to `XcodesOrg/XcodesApp:main`.

## Bug reports

Include:

- macOS and Xcodes versions
- Xcode version involved
- clear reproduction steps
- expected and actual behaviour
- relevant redacted logs or screenshots

Never include Apple ID credentials, cookies, Keychain contents, signing keys, or other secrets.

## Licence

By contributing, you agree that your contributions are licensed under the repository's [MIT Licence](LICENSE).
