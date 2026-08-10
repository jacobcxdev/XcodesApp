#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_file="$repo_root/Xcodes.xcodeproj/project.pbxproj"
shared_constants="$repo_root/HelperXPCShared/HelperXPCShared.swift"
helper_dir="$repo_root/dev.jacobcx.Xcodes.Helper"
uninstall_script="$repo_root/Scripts/uninstall_privileged_helper.sh"
app_info_plist="$repo_root/Xcodes/Resources/Info.plist"
helper_scheme="$repo_root/Xcodes.xcodeproj/xcshareddata/xcschemes/dev.jacobcx.Xcodes.Helper.xcscheme"

require_literal() {
    local literal="$1"
    local file="$2"

    if ! grep -Fq -- "$literal" "$file"; then
        echo "Missing required identity '$literal' in ${file#"$repo_root/"}" >&2
        return 1
    fi
}

status=0

if [[ ! -d "$helper_dir" ]]; then
    echo "Missing renamed helper directory: ${helper_dir#"$repo_root/"}" >&2
    status=1
fi

if [[ ! -f "$helper_scheme" ]]; then
    echo "Missing renamed helper scheme: ${helper_scheme#"$repo_root/"}" >&2
    status=1
fi

require_literal 'PRODUCT_BUNDLE_IDENTIFIER = dev.jacobcx.Xcodes;' "$project_file" || status=1
require_literal 'PRODUCT_BUNDLE_IDENTIFIER = dev.jacobcx.Xcodes.Helper;' "$project_file" || status=1
require_literal 'DEVELOPMENT_TEAM = K2648T24P4;' "$project_file" || status=1
require_literal 'let machServiceName = "dev.jacobcx.Xcodes.Helper"' "$shared_constants" || status=1
require_literal 'let clientBundleID = "dev.jacobcx.Xcodes"' "$shared_constants" || status=1

if [[ -d "$repo_root/com.xcodesorg.xcodesapp.Helper" ]]; then
    echo "Legacy helper directory still exists: com.xcodesorg.xcodesapp.Helper" >&2
    status=1
fi

if [[ -f "$repo_root/Xcodes.xcodeproj/xcshareddata/xcschemes/com.robotsandpencils.XcodesApp.Helper.xcscheme" ]]; then
    echo "Legacy helper scheme still exists: com.robotsandpencils.XcodesApp.Helper.xcscheme" >&2
    status=1
fi

identity_scope=(
    "$repo_root/Xcodes.xcodeproj"
    "$repo_root/HelperXPCShared"
    "$uninstall_script"
    "$app_info_plist"
)

if [[ -d "$helper_dir" ]]; then
    identity_scope+=("$helper_dir")
fi

if grep -R -n -E -- 'com\.xcodesorg\.xcodesapp|com\.robotsandpencils\.XcodesApp|ZU6GR6B2FY' "${identity_scope[@]}"; then
    echo "Legacy operational identities remain" >&2
    status=1
else
    scan_status=$?
    if [[ "$scan_status" -ne 1 ]]; then
        echo "Unable to scan the complete operational identity scope" >&2
        status=1
    fi
fi

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

echo "Fork identity check passed"
