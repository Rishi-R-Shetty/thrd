#!/bin/bash
# Build helper for Thrd Spaces.
# Usage: ./scripts/build.sh
# Called by the swiftui-builder subagent's Step 4 (Verify).

set -e
cd "$(dirname "$0")/.."

# Adjust project path and scheme name if you renamed the Xcode project.
PROJECT="thrdspaces/thrdspaces.xcodeproj"
SCHEME="thrdspaces"
DESTINATION="platform=iOS Simulator,name=iPhone 16 Pro"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  build 2>&1 | tail -50
