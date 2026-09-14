#!/bin/bash
#
# Archive the app and upload it to App Store Connect, bumping the build number first.
#
#     Tools/upload.sh
#
# Uses the Apple ID signed into Xcode, so nothing needs to be typed. Each upload needs a unique
# build number, and this is the only place that touches it — so it can't be forgotten and can't
# be double-used. The version (1.0, 1.1, …) is yours to change in project.yml when it matters.
set -euo pipefail
cd "$(dirname "$0")/.."

# Bump CFBundleVersion in project.yml and regenerate.
current=$(grep -E '^\s+CFBundleVersion:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
next=$((current + 1))
sed -i '' -E "s/^(\s+CFBundleVersion: )\"$current\"/\1\"$next\"/" project.yml
xcodegen generate >/dev/null
version=$(grep -E '^\s+CFBundleShortVersionString:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
echo "Uploading $version ($next)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

xcodebuild archive \
  -project Highlights.xcodeproj -scheme Highlights \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath "$work/Highlights.xcarchive" \
  -allowProvisioningUpdates -quiet

xcodebuild -exportArchive \
  -archivePath "$work/Highlights.xcarchive" \
  -exportOptionsPlist Tools/ExportOptions.plist \
  -exportPath "$work/export" \
  -allowProvisioningUpdates 2>&1 | grep -E "Upload succeeded|error|EXPORT (SUCCEEDED|FAILED)"

echo "Build $next is processing in App Store Connect. Commit the version bump:"
echo "    git commit -am 'Build $next'"
