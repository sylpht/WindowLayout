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
  WindowLayout/ProfileFileStore.swift \
  WindowLayout/DisplayProfile.swift \
  WindowLayout/iCloudSync.swift \
  WindowLayout/RestoreDiagnostics.swift \
  WindowLayout/LayoutManager.swift \
  Tests/main.swift \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  -o TestRunner

./TestRunner

swiftc \
  WindowLayout/WindowSnapshot.swift \
  WindowLayout/ProfileFileStore.swift \
  WindowLayout/iCloudSync.swift \
  Tests/sync_safety.swift \
  -sdk "$SDK" -target arm64-apple-macos13.0 -o SyncSafetyRunner
./SyncSafetyRunner

swiftc \
  WindowLayout/Log.swift \
  WindowLayout/Localization.swift \
  WindowLayout/Geometry.swift \
  WindowLayout/WindowSnapshot.swift \
  WindowLayout/ProfileFileStore.swift \
  WindowLayout/DisplayProfile.swift \
  WindowLayout/iCloudSync.swift \
  WindowLayout/RestoreDiagnostics.swift \
  WindowLayout/LayoutManager.swift \
  Tests/storage_safety/main.swift \
  -sdk "$SDK" -target arm64-apple-macos13.0 -o StorageSafetyRunner
./StorageSafetyRunner

bash Tests/release_tooling.sh
