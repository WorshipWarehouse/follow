#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/follow-download.XXXXXX)"
package_cache="${FOLLOW_PACKAGE_CACHE:-$build_dir/SourcePackages}"
cd "$repo_dir"
xcodebuild -project Follow.xcodeproj -scheme 'Follow iPhone Sharing' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir" -clonedSourcePackagesDirPath "$package_cache" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
python3 scripts/package-download.py \
  "$build_dir/Build/Products/Release-iphoneos/FollowPersonalSharing.app" output
