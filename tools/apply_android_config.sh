#!/usr/bin/env bash
# Android configuration the scaffold does NOT give you (Task Z2).
#
# Run this AFTER `flutter create --platforms=android,ios .` and BEFORE the first
# `flutter build apk`. It is idempotent: every edit is a guarded replacement that
# prints what it changed, so re-running after a scaffold regeneration is safe.
#
# Why a script rather than a checklist in the README: three of these are SILENT
# failures at a counter — a POS that flips to portrait when lifted, one that dies
# on a low-memory phone mid-bill, one that restarts its Dart side on rotation.
# None of them produce a build error, so nobody finds out until service.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
MANIFEST="android/app/src/main/AndroidManifest.xml"
GRADLE="android/app/build.gradle.kts"
GRADLE_GROOVY="android/app/build.gradle"
FAILED=0
CHANGED=0

say()  { printf '  \033[32m→\033[0m %s\n' "$1"; CHANGED=$((CHANGED+1)); }
skip() { printf '  ·   %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAILED=$((FAILED+1)); }

if [ ! -d android ]; then
  echo "No android/ directory yet. Generate the scaffold first:"
  echo "    flutter create --platforms=android,ios --org com.kazama --project-name kazama_pos ."
  echo "Then re-run this script. Nothing was changed."
  exit 2
fi

# ---------------------------------------------------------------- 1. minSdk ---
# drift + sqlite3_flutter_libs need 21+; `flutter_blue_plus` (P4) needs 23 for its
# runtime BLE permissions. Pinning 23 NOW means P4 does not also touch this file,
# and an update that raises minSdk silently cannot strand a shop's old tablet
# mid-service.
for f in "$GRADLE" "$GRADLE_GROOVY"; do
  [ -f "$f" ] || continue
  if ! grep -q "minSdk" "$f"; then
    bad "$f has no minSdk line (unexpected template) — set it by hand"
    continue
  fi
  python3 - "$f" <<'PY' > /dev/null 2>&1
import re, sys
path = sys.argv[1]
src = open(path).read()
repl = "minSdk = 23" if path.endswith(".kts") else "minSdk 23"
pat = r"min\w*[Ss]dk\w*\s*=?\s*(?:flutter\.minSdkVersion|\d+)"
out = re.sub(pat, repl, src, count=1)
if out == src:
    sys.exit(3)  # already pinned to exactly this
open(path, "w").write(out)
PY
  case $? in
    0) say "$f: minSdk → 23" ;;
    3) skip "$f already pins minSdk" ;;
    *) bad "could not rewrite the minSdk assignment in $f" ;;
  esac
done

# ------------------------------------------------- 2. manifest: orientation ---
# A POS tablet in a stand must not flip when it is lifted. `sensorLandscape`
# rather than `landscape` (both rotations are fine) and `configChanges` so a
# rotation — or a keyboard appearing — does not restart the Dart side and lose
# the half-entered payment on screen.
if [ -f "$MANIFEST" ]; then
  if grep -q "android:screenOrientation" "$MANIFEST"; then
    skip "orientation already declared"
  else
    python3 - "$MANIFEST" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "<activity" not in src:
    sys.exit(1)
out = src.replace(
    "<activity",
    "<activity\n"
    '    android:screenOrientation="sensorLandscape"\n'
    '    android:configChanges="orientation|screenSize|keyboardHidden"',
    1,
)
open(path, "w").write(out)
PY
    case $? in
      0) say "orientation → sensorLandscape + configChanges" ;;
      *) bad "no <activity> element found in $MANIFEST" ;;
    esac
  fi
fi

# --------------------------------------------------- 3. manifest: largeHeap ---
# The order screen holds every open ticket's lines and the print queue buffers
# rendered slips; on a 2 GB counter phone the app is already near its heap limit.
if [ -f "$MANIFEST" ]; then
  if grep -q "android:largeHeap" "$MANIFEST"; then
    skip "largeHeap already declared"
  else
    python3 - "$MANIFEST" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "<application" not in src:
    sys.exit(1)
out = src.replace("<application", '<application\n        android:largeHeap="true"', 1)
open(path, "w").write(out)
PY
    case $? in
      0) say "application: largeHeap=true" ;;
      *) bad "no <application> element found in $MANIFEST" ;;
    esac
  fi
fi

# -------------------------------------- 4. manifest: boot permission (declared) --
# Declared here and used by nothing in v1: the day the sync scheduler (T5) wants a
# wake-on-boot, the permission is already in the manifest the store reviewed,
# rather than arriving in an update that looks like a behaviour change.
if [ -f "$MANIFEST" ]; then
  if grep -q "RECEIVE_BOOT_COMPLETED" "$MANIFEST"; then
    skip "RECEIVE_BOOT_COMPLETED already declared"
  else
    python3 - "$MANIFEST" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
if "<application" not in src:
    sys.exit(1)
perm = '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />\n'
open(path, "w").write(src.replace("<application", perm + "\n<application", 1))
PY
    case $? in
      0) say "RECEIVE_BOOT_COMPLETED declared (unused in v1 — deliberate)" ;;
      *) bad "no <application> element found in $MANIFEST" ;;
    esac
  fi
fi

# ------------------------------------------------------------- 5. versioning ---
skip "versionName/build come from pubspec.yaml 'version:' — bump the +N per device build (Z4)"

echo
printf '  %s edit(s), %s failure(s).\n' "$CHANGED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
  echo "Some edits did not apply. The Gradle file name moved between AGP 7"
  echo "(build.gradle) and AGP 8 (build.gradle.kts); the manifest path is stable."
  exit 1
fi
echo "Next:"
echo "    flutter pub get"
echo "    dart run build_runner build --delete-conflicting-outputs"
echo "    flutter analyze && flutter test && flutter build apk --debug"
