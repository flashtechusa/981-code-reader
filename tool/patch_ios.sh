#!/usr/bin/env bash
# Applies the iOS plumbing Boxster SRS needs after `flutter create` has
# generated the ios/ folder:
#   * NSLocalNetworkUsageDescription  (iOS 14+ local-network prompt)
#   * UIRequiresPersistentWiFi         (keep the adapter's Wi-Fi alive)
#   * portrait only (iPhone)
#   * bundle id com.flashtech.boxstersrs
#   * iOS 15.0 deployment target
# Safe to run repeatedly. Run from the project root on macOS (uses PlistBuddy)
# or anywhere with sed for the pbxproj part.
set -euo pipefail

cd "$(dirname "$0")/.."
PLIST="ios/Runner/Info.plist"
PBX="ios/Runner.xcodeproj/project.pbxproj"
PODFILE="ios/Podfile"
BUNDLE_ID="com.flashtech.boxstersrs"

if [[ ! -f "$PLIST" ]]; then
  echo "error: $PLIST not found - run: flutter create --org com.flashtech --project-name boxster_srs ." >&2
  exit 1
fi

PB="/usr/libexec/PlistBuddy"
if [[ -x "$PB" ]]; then
  set_str() { "$PB" -c "Set :$1 $2" "$PLIST" 2>/dev/null || "$PB" -c "Add :$1 string $2" "$PLIST"; }
  set_bool() { "$PB" -c "Set :$1 $2" "$PLIST" 2>/dev/null || "$PB" -c "Add :$1 bool $2" "$PLIST"; }

  set_str  NSLocalNetworkUsageDescription "Boxster SRS talks to your OBD-II Wi-Fi adapter."
  set_bool UIRequiresPersistentWiFi true
  set_bool ITSAppUsesNonExemptEncryption false
  set_str  CFBundleDisplayName "Boxster SRS"

  "$PB" -c "Delete :UISupportedInterfaceOrientations" "$PLIST" 2>/dev/null || true
  "$PB" -c "Add :UISupportedInterfaceOrientations array" "$PLIST"
  "$PB" -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" "$PLIST"
  echo "patched $PLIST"
else
  echo "PlistBuddy not available (not macOS?) - skipping Info.plist; the committed ios/Runner/Info.plist already contains the keys."
fi

if [[ -f "$PBX" ]]; then
  # flutter create derives com.flashtech.boxsterSrs; normalise to the lower-case id.
  sed -i.bak -E "s/PRODUCT_BUNDLE_IDENTIFIER = [^;]*;/PRODUCT_BUNDLE_IDENTIFIER = ${BUNDLE_ID};/g" "$PBX"
  sed -i.bak -E "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/IPHONEOS_DEPLOYMENT_TARGET = 15.0;/g" "$PBX"
  rm -f "$PBX.bak"
  echo "patched $PBX (bundle id ${BUNDLE_ID}, iOS 15.0)"
fi

if [[ -f "$PODFILE" ]]; then
  sed -i.bak -E "s/^# platform :ios, '[0-9.]+'/platform :ios, '15.0'/; s/^platform :ios, '[0-9.]+'/platform :ios, '15.0'/" "$PODFILE"
  rm -f "$PODFILE.bak"
  echo "patched $PODFILE (platform :ios, '15.0')"
fi
