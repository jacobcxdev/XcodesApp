# Fork and upstream workflow

This repository has two purposes: independently maintained Xcodes releases and clean contributions back to XcodesOrg. Keep those histories separate.

## Configure remotes

Clone the maintained fork so `origin` is owned product authority:

```sh
git clone https://github.com/jacobcxdev/XcodesApp.git
cd XcodesApp
git remote add upstream https://github.com/XcodesOrg/XcodesApp.git
git remote set-url --push upstream DISABLED
git fetch upstream
git remote -v
```

`origin/main` owns fork identity, packaging, CI, releases, documentation, and fork-only features. `upstream` is fetch-only. Never enable its push URL.

For an existing checkout, make ownership explicit before adding upstream:

```sh
git remote set-url origin https://github.com/jacobcxdev/XcodesApp.git
git remote add upstream https://github.com/XcodesOrg/XcodesApp.git
git remote set-url --push upstream DISABLED
git fetch upstream
```

## Normal fork work

Start fork work from current owned `main`:

```sh
git switch main
git pull --ff-only origin main
git switch --create jacobcxdev/<topic>
git push --set-upstream origin jacobcxdev/<topic>
```

Open the pull request against `jacobcxdev/XcodesApp:main`.

## Portable upstream contributions

Start from upstream source, not owned `main`:

```sh
git fetch upstream
git switch --create upstream/<topic> upstream/main
git push --set-upstream origin upstream/<topic>
```

Keep the branch limited to portable source, tests, and documentation. Do not merge `origin/main` into it. Open the pull request against `XcodesOrg/XcodesApp:main`.

If upstream requests changes, rebase on its current `main`:

```sh
git fetch upstream
git switch upstream/<topic>
git rebase upstream/main
git push --force-with-lease origin upstream/<topic>
```

## Sync upstream into the maintained fork

Integrate upstream through a dated review branch:

```sh
git fetch upstream
git switch --create sync/upstream-YYYYMMDD origin/main
git merge --no-ff upstream/main
git push --set-upstream origin sync/upstream-YYYYMMDD
```

When you resolve conflicts, retain fork identity, migration, packaging, update, and release contracts. Before you merge the sync pull request into `origin/main`, run the full test suite and identity check.

## Release-only changes

Release identity and automation belong only on owned fork branches. Never copy fork signing, notarization, Sparkle, GitHub environment, or publishing configuration into an `upstream/<topic>` branch. See [docs/RELEASING.md](docs/RELEASING.md) for protected release setup and tag procedure.
