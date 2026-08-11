# AcknowledgementsGenerator

Scans an Xcode project's checked-out SPM packages for license files, then combines them into a single RTF file.

Pass `-c <path>` to use an explicit SwiftPM checkouts directory. Xcode's build phase supplies this from `BUILD_DIR`, so command-line `-derivedDataPath` overrides work without relying on per-user Xcode defaults.

Based on https://github.com/MacPaw/spm-licenses.
