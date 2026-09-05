#!/usr/bin/env bash
# T3 environment gate — run BEFORE `flutter pub get`.
# Every failure below prints the exact fix, because a red `pub get` error in a
# first-time Flutter setup is usually the toolchain, not the code (R8/loop step 5).
set -uo pipefail

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        → %s\n' "$2"; FAILS=$((FAILS+1)); }
FAILS=0

echo "── Kazama POS setup check ──────────────────────────────"

# 1. Flutter + Dart
if command -v flutter >/dev/null 2>&1; then
  v=$(flutter --version 2>/dev/null | head -1)
  case "$v" in *" 3.19"*|*" 3.18"*|*" 3.16"*|*" 3.13"*) bad "Flutter is old: $v" "upgrade: flutter upgrade (needs 3.24+)" ;; *) ok "flutter → $v" ;; esac
else
  bad "flutter not on PATH" "install 3.24+ stable: https://docs.flutter.dev/get-started/install"
fi

if command -v dart >/dev/null 2>&1; then ok "dart → $(dart --version 2>&1)"; else bad "dart not on PATH" "comes with the Flutter SDK; check FLUTTER_ROOT/bin"; fi

# 2. Can we reach pub.dev at all? (the sandbox that wrote this code could NOT)
if curl -s -o /dev/null --max-time 8 https://pub.dev; then ok "pub.dev reachable"; else bad "cannot reach https://pub.dev" "offline/proxy/DNS problem — 'flutter pub get' will fail for network reasons, not code reasons"; fi

# 3. Android toolchain
if command -v adb >/dev/null 2>&1; then ok "adb → $(adb version 2>/dev/null | head -1)"; else bad "adb missing" "install Android Studio (or commandline-tools) and set ANDROID_HOME"; fi
if command -v java >/dev/null 2>&1; then ok "java → $(java -version 2>&1 | head -1)"; else bad "java missing" "Gradle needs JDK 17: sudo apt install openjdk-17-jdk"; fi

# 4. A device to install on
if command -v adb >/dev/null 2>&1; then
  n=$(adb devices 2>/dev/null | grep -cw device)
  if [ "${n:-0}" -ge 1 ]; then ok "$n device(s) attached"; else warn "no device — realme phone: enable USB debugging, then 'adb devices' must list it"; fi
fi

# 5. Repo state — the files this task depends on
for f in pubspec.yaml lib/core/db/app_database.dart lib/core/db/connection.dart test/core/app_database_test.dart; do
  [ -f "$f" ] && ok "$f" || bad "missing $f" "wrong directory? run this from the repo root (where pubspec.yaml lives)"
done

# 6. The generated file must NOT be hand-edited, and must exist after codegen
if [ -f lib/core/db/app_database.g.dart ]; then ok "app_database.g.dart present (generated)"; else warn "app_database.g.dart absent — expected until: dart run build_runner build --delete-conflicting-outputs"; fi

echo "────────────────────────────────────────────────────────"
if [ "$FAILS" -eq 0 ]; then
  echo "Ready. Next:"
  echo "  flutter pub get"
  echo "  dart run build_runner build --delete-conflicting-outputs"
  echo "  flutter test test/core/app_database_test.dart"
  exit 0
else
  echo "$FAILS problem(s) to fix before pub get. Do NOT report a code FAIL yet —"
  echo "T3 cannot be evaluated until this script is clean."
  exit 1
fi
