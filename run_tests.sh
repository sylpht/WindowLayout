#!/bin/bash
# Compile and run the test suite.

set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path --sdk macosx)

swiftc \
  WindowLayout/Log.swift \
  WindowLayout/Localization.swift \
  WindowLayout/Geometry.swift \
  WindowLayout/WindowSnapshot.swift \
  WindowLayout/DisplayProfile.swift \
  WindowLayout/iCloudSync.swift \
  WindowLayout/LayoutManager.swift \
  Tests/main.swift \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -o TestRunner

./TestRunner
