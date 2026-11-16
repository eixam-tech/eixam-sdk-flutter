#!/usr/bin/env bash
# Native iOS (Swift) tests of eixam_connect_flutter, without an Xcode project.
#
# Usage:   packages/eixam_connect_flutter/tool/test_ios_native.sh
# Env:     EIXAM_NATIVE_TEST_OUT   output dir (default: a new temp dir; never
#                                  inside the repository)
#          FLUTTER_ROOT            Flutter SDK (default: from `flutter` on PATH),
#                                  for the Flutter.framework typecheck
#          EIXAM_SKIP_IOS_TYPECHECK=1  skip the typecheck (reported, not silent)
#
# What it does:
#   1. Discovers every .swift file under ios/Classes and ios/Tests (no hand
#      list). Every Classes file is compiled into every test binary unless it is
#      in EXCLUDE below (with the reason it cannot build standalone).
#   2. Fails loudly if a discovered file is neither compiled nor excluded, if an
#      excluded file no longer exists, or if a Tests file has no @main.
#   3. Builds one macOS executable per Tests/*.swift (each has its own @main)
#      with swiftc, runs it, and fails on a build error, a non-zero exit or any
#      FAIL line.
#   4. Typechecks the excluded files (all Classes, FirmwareDfuBridge stubbed)
#      against the iOS simulator SDK and Flutter.framework.
# Android: see tool/test_android_native.sh.
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$PKG/ios"
OUT="${EIXAM_NATIVE_TEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/eixam-ios-native.XXXXXX")}"
REPO="$(cd "$PKG/../.." && pwd)"
case "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")/" in
  "$REPO"/*) echo "ERROR: output dir $OUT is inside the repository; set EIXAM_NATIVE_TEST_OUT elsewhere" >&2; exit 2 ;;
esac
mkdir -p "$OUT"

# Files that cannot compile standalone with swiftc on macOS ("path|reason").
EXCLUDE=(
  "Classes/EixamConnectFlutterPlugin.swift|Flutter plugin registration (Flutter, UIKit)"
  "Classes/ProtectionRuntimeBridge.swift|Flutter method channel + CoreBluetooth/UIKit runtime"
  "Classes/BackgroundLocationBridge.swift|Flutter channel, CoreLocation/UIKit"
  "Classes/ActivityRecordingStorageBridge.swift|Flutter channel"
  "Classes/SecureStorageBridge.swift|Flutter channel"
  "Classes/PhoneRadioBridge.swift|Flutter channel, CoreTelephony (iOS only)"
  "Classes/NearbyClosedAppNotifier.swift|UIKit (iOS only)"
  "Classes/EixamSosPromptNotificationHandler.swift|calls ProtectionRuntimeBridge (Flutter)"
  "Classes/FirmwareDfuBridge.swift|NordicDFU pod (CocoaPods only); stubbed in the typecheck"
)

fail() { echo "ERROR: $*" >&2; exit 1; }

excluded_paths=()
for entry in "${EXCLUDE[@]}"; do
  excluded_paths+=("${entry%%|*}")
done
is_excluded() {
  local p
  for p in "${excluded_paths[@]}"; do [[ "$p" == "$1" ]] && return 0; done
  return 1
}

cd "$IOS"
missing=()
for p in "${excluded_paths[@]}"; do [[ -f "$p" ]] || missing+=("$p"); done
[[ ${#missing[@]} -eq 0 ]] || fail "excluded files no longer exist (update EXCLUDE): ${missing[*]}"

discovered=()
while IFS= read -r f; do discovered+=("${f#./}"); done < <(find ./Classes ./Tests -name '*.swift' | sort)
[[ ${#discovered[@]} -gt 0 ]] || fail "no Swift sources found under $IOS"

classes=()
tests=()
unaccounted=()
for f in "${discovered[@]}"; do
  if is_excluded "$f"; then continue; fi
  case "$f" in
    Classes/*) classes+=("$f") ;;
    Tests/*) tests+=("$f") ;;
    *) unaccounted+=("$f") ;;
  esac
done
[[ ${#unaccounted[@]} -eq 0 ]] || fail "Swift files neither compiled nor excluded: ${unaccounted[*]}"
[[ ${#tests[@]} -gt 0 ]] || fail "no Swift test files under ios/Tests"
for t in "${tests[@]}"; do
  grep -q '^@main' "$t" || fail "$t has no @main (each test file is its own executable)"
done

echo "iOS native tests: ${#classes[@]} classes x ${#tests[@]} test executables; ${#excluded_paths[@]} excluded; out=$OUT"
status=0
for t in "${tests[@]}"; do
  name="$(basename "$t" .swift)"
  if ! swiftc -parse-as-library -o "$OUT/$name" "${classes[@]}" "$t" > "$OUT/$name.build.log" 2>&1; then
    echo "BUILD_FAILED $name"; grep 'error:' "$OUT/$name.build.log" | head -20
    status=1; continue
  fi
  set +e
  (cd "$IOS" && "$OUT/$name") > "$OUT/$name.log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]] || grep -qE 'FAIL' "$OUT/$name.log"; then
    echo "FAILED $name (exit=$rc)"; grep -E 'FAIL' "$OUT/$name.log" | head -40
    status=1
  else
    echo "OK $name: $(tail -1 "$OUT/$name.log")"
  fi
done

if [[ "${EIXAM_SKIP_IOS_TYPECHECK:-}" == "1" ]]; then
  echo "TYPECHECK SKIPPED (EIXAM_SKIP_IOS_TYPECHECK=1): excluded files not checked"
else
  root="${FLUTTER_ROOT:-}"
  if [[ -z "$root" ]] && command -v flutter >/dev/null; then
    root="$(cd "$(dirname "$(command -v flutter)")/.." && pwd)"
  fi
  framework="$root/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
  [[ -d "$framework" ]] || fail "Flutter.framework not found ($framework); set FLUTTER_ROOT, run 'flutter precache --ios', or EIXAM_SKIP_IOS_TYPECHECK=1"
  cat > "$OUT/FirmwareDfuBridgeStub.swift" <<'EOF'
import Flutter
enum FirmwareDfuBridge { static func register(with registrar: FlutterPluginRegistrar) {} }
EOF
  typecheck=()
  for f in "${discovered[@]}"; do
    case "$f" in Classes/FirmwareDfuBridge.swift|Tests/*) ;; Classes/*) typecheck+=("$f") ;; esac
  done
  if swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
      -target arm64-apple-ios13.0-simulator -F "$framework" \
      "${typecheck[@]}" "$OUT/FirmwareDfuBridgeStub.swift" > "$OUT/typecheck.log" 2>&1; then
    echo "OK typecheck: ${#typecheck[@]} Classes files against iOS simulator SDK + Flutter.framework"
  else
    echo "TYPECHECK_FAILED"; grep 'error:' "$OUT/typecheck.log" | head -20
    status=1
  fi
fi

[[ $status -eq 0 ]] && echo "iOS native: PASS" || echo "iOS native: FAIL (logs in $OUT)"
exit $status
