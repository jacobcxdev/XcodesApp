<h1><img src="icon.png" align="center" width=50 height=50 /> <img src="IconDark.png" align="center" width=50 height=50 /> <img src="IconMono.png" align="center" width=50 height=50 /> Xcodes.app</h1>

The easiest way to install and switch between multiple versions of Xcode.

This repository is Jacob Clayden's maintained fork of [XcodesOrg/XcodesApp](https://github.com/XcodesOrg/XcodesApp). It keeps the visible `Xcodes.app` name and workflow as a drop-in replacement while using fork-owned bundle, helper, update, signing, and release identities.

If you need a command-line tool, see the upstream [`xcodes`](https://github.com/XcodesOrg/xcodes) project.

[![CI](https://github.com/jacobcxdev/XcodesApp/actions/workflows/ci.yml/badge.svg)](https://github.com/jacobcxdev/XcodesApp/actions/workflows/ci.yml)

![](screenshot_light.png#gh-light-mode-only)
![](screenshot_dark.png#gh-dark-mode-only)

## Features

- Lists available Xcode versions from [Xcode Releases](https://xcodereleases.com) or Apple Developer.
- Downloads and installs Xcode, with resumable multi-connection downloads through [`aria2`](https://aria2.github.io).
- Selects the active version using `xcode-select`.
- Shows release notes, OS compatibility, SDKs, and compilers.
- Installs supported simulator platforms and runtimes.
- Supports Apple silicon and universal Xcode variants.
- Supports Apple ID and security-key authentication where Apple requires sign-in.
- Supports stable and prerelease update channels through Sparkle.

The optional unxip experiment builds on [saagarjha/unxip](https://github.com/saagarjha/unxip). It can reduce extraction time, at the cost of higher memory use on some systems.

## Installation

Fork releases use the same `Xcodes.app` application name as upstream. The fork has a distinct bundle ID and helper identity, so macOS can distinguish its settings and privileged helper.

1. Download `Xcodes.zip` from the [latest fork release](https://github.com/jacobcxdev/XcodesApp/releases/latest).
2. Expand the archive.
3. Move `Xcodes.app` to `/Applications`.

The release process distributes fork assets only after Developer ID signing and notarization. GitHub Releases is the supported binary distribution path. This fork does not publish a Homebrew cask.

On first launch, non-secret preferences can migrate from upstream Xcodes. Apple credentials, cookies, Keychain items, and the privileged helper do not migrate. Sign in again. When Xcodes prompts you, approve helper installation.

## Build from source

Clone the maintained fork:

```sh
git clone https://github.com/jacobcxdev/XcodesApp.git
cd XcodesApp
open Xcodes.xcodeproj
```

Use the Xcode version configured by CI (`DEVELOPER_DIR` in `.github/workflows/ci.yml`) or a newer compatible release. Xcode resolves Swift package dependencies when the project opens. To build without signing from the command line:

```sh
xcodebuild build \
  -project Xcodes.xcodeproj \
  -scheme Xcodes \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

Run the test suite with:

```sh
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test CODE_SIGNING_ALLOWED=NO
```

The repository release workflow automates packaging and notarization. `Scripts` and the workflow files document local and CI release requirements.

## Contributing

Report fork bugs and request features in [fork issues](https://github.com/jacobcxdev/XcodesApp/issues). See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

Normal fork development and portable upstream contributions use separate branch lanes. [FORKING.md](FORKING.md) documents exact remote and branch commands.

## Upstream and credits

Robots and Pencils, XcodesOrg, Matt Kiazyk, and many community contributors and translators created and maintained Xcodes. Repository history, licence notices, and the app's acknowledgements retain their credits. [Jacob Clayden](https://github.com/jacobcxdev) maintains this fork independently.

[`xcode-install`](https://github.com/xcpretty/xcode-install), [fastlane/spaceship](https://github.com/fastlane/fastlane/tree/master/spaceship), and the project's open-source dependencies deserve credit for the foundations Xcodes builds on.

## Licence

Xcodes is available under the [MIT Licence](LICENSE). Original copyright notices are preserved alongside the fork copyright.
