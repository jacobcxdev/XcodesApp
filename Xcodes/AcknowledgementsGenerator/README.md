# AcknowledgementsGenerator

Scans an Xcode project's checked-out SPM packages for license files, then combines them into a single RTF file.

Pass `-c <path>` to use an explicit SwiftPM checkouts directory. Pass `-b <path>` to resolve `SourcePackages/checkouts` from an Xcode build directory. Xcode's build phase passes `BUILD_DIR`, so normal builds, archives, and command-line `-derivedDataPath` overrides work without relying on per-user Xcode defaults.

Based on https://github.com/MacPaw/spm-licenses.
