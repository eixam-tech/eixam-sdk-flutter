#!/usr/bin/env bash
# Native Android (Kotlin/JVM) unit tests of eixam_connect_flutter.
#
# Usage:   packages/eixam_connect_flutter/tool/test_android_native.sh
# Env:     EIXAM_NATIVE_TEST_OUT  output dir (default: a new temp dir; never
#                                 inside the repository). The throwaway host
#                                 app lives in $EIXAM_NATIVE_TEST_OUT/host and
#                                 is reused when it already exists.
#          JAVA_HOME              JDK 17+ (default: Android Studio's JBR on macOS)
#          flutter on PATH (or FLUTTER_ROOT)
#
# Why a host app: a Flutter plugin's Android module only builds inside an app
# (Flutter's Gradle plugin wires the engine and the plugin's dependencies). The
# host is generated with `flutter create`, depends on this package by path, and
# runs `:eixam_connect_flutter:testDebugUnitTest --rerun-tasks`. Gradle
# discovers every test class itself (no hand list). This script then fails
# loudly unless the run produced tests (> 0), no failures/errors, no skipped
# (@Ignore'd / assumption-failed) tests, and a result XML for every *Test.kt
# under android/src/test.
# iOS: see tool/test_ios_native.sh.
# (macOS `sh` is bash in POSIX mode: re-executed too.)
case "${BASH_VERSION:-}:${SHELLOPTS:-}" in
  :* | *posix*)
    if [ -n "${EIXAM_NATIVE_TEST_REEXEC:-}" ] || ! command -v bash >/dev/null 2>&1; then
      echo "ERROR: $0 needs bash (not POSIX mode)" >&2; exit 2
    fi
    EIXAM_NATIVE_TEST_REEXEC=1 exec env -u POSIXLY_CORRECT bash "$0" "$@" ;;
esac
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$PKG/../.." && pwd)"
OUT="${EIXAM_NATIVE_TEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/eixam-android-native.XXXXXX")}"
case "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")/" in
  "$REPO"/*) echo "ERROR: output dir $OUT is inside the repository; set EIXAM_NATIVE_TEST_OUT elsewhere" >&2; exit 2 ;;
esac
mkdir -p "$OUT"
fail() { echo "ERROR: $*" >&2; exit 1; }

FLUTTER="flutter"
if [[ -n "${FLUTTER_ROOT:-}" ]]; then FLUTTER="$FLUTTER_ROOT/bin/flutter"; fi
command -v "$FLUTTER" >/dev/null || fail "flutter not found (PATH or FLUTTER_ROOT)"
if [[ -z "${JAVA_HOME:-}" ]]; then
  jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [[ -d "$jbr" ]] && export JAVA_HOME="$jbr"
fi

HOST="$OUT/host"
if [[ ! -f "$HOST/android/gradlew" ]]; then
  echo "Creating the host app in $HOST"
  "$FLUTTER" create --no-pub --org dev.eixam.nativetest --project-name eixam_native_test_host \
    --platforms android "$HOST" > "$OUT/create.log" 2>&1 || { tail -20 "$OUT/create.log"; fail "flutter create failed"; }
fi
# Always point at this checkout (the host may have been created for another one).
python3 - "$HOST/pubspec.yaml" "$PKG" <<'EOF'
import re, sys
path, pkg = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r"\n  eixam_connect_flutter:\n    path: [^\n]*", "", text)
text = text.replace("\ndependencies:\n", "\ndependencies:\n  eixam_connect_flutter:\n    path: %s\n" % pkg, 1)
open(path, "w").write(text)
EOF
(cd "$HOST" && "$FLUTTER" pub get > "$OUT/pub-get.log" 2>&1) || { tail -20 "$OUT/pub-get.log"; fail "flutter pub get failed"; }
grep -q "$PKG" "$HOST/.flutter-plugins-dependencies" || fail "host does not resolve eixam_connect_flutter to $PKG"

RESULTS="$HOST/build/eixam_connect_flutter/test-results/testDebugUnitTest"
rm -rf "$RESULTS"
set +e
(cd "$HOST/android" && ./gradlew :eixam_connect_flutter:testDebugUnitTest --rerun-tasks) > "$OUT/gradle.log" 2>&1
rc=$?
set -e
grep -E '^e: |FAILED|BUILD (SUCCESSFUL|FAILED)' "$OUT/gradle.log" | head -20 || true

python3 - "$RESULTS" "$PKG/android/src/test" "$rc" <<'EOF'
import glob, os, re, sys
results, test_root, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
total = failures = errors = skipped = 0
reported = set()
for path in glob.glob(os.path.join(results, "TEST-*.xml")):
    xml = open(path).read()
    m = re.search(r'<testsuite name="([^"]+)" tests="(\d+)" skipped="(\d+)" failures="(\d+)" errors="(\d+)"', xml)
    if not m:
        print("UNPARSED result file %s" % os.path.basename(path))
        failures += 1
        continue
    reported.add(m.group(1))
    total += int(m.group(2)); skipped += int(m.group(3))
    failures += int(m.group(4)); errors += int(m.group(5))
    for name, message in re.findall(r'<testcase name="([^"]+)"[^>]*>\s*<failure message="([^"]{0,300})', xml):
        print("FAIL %s :: %s" % (name, message))
    for name in re.findall(r'<testcase name="([^"]+)"[^>]*>\s*<skipped', xml):
        print("SKIPPED %s :: %s" % (m.group(1), name))
expected = set()
for dirpath, _, files in os.walk(test_root):
    for f in files:
        if f.endswith("Test.kt"):
            src = open(os.path.join(dirpath, f)).read()
            pkg = re.search(r"^package\s+([\w.]+)", src, re.M)
            expected.add((pkg.group(1) + "." if pkg else "") + f[:-3])
missing = sorted(expected - reported)
print("tests=%d failures=%d errors=%d skipped=%d classes=%d/%d" % (total, failures, errors, skipped, len(expected & reported), len(expected)))
problems = []
if rc != 0: problems.append("gradle exit %d" % rc)
if total == 0: problems.append("no tests ran")
if failures or errors: problems.append("%d failures, %d errors" % (failures, errors))
if skipped: problems.append("%d skipped (@Ignore'd or assumption failed): a skipped test proves nothing" % skipped)
if missing: problems.append("no result for: " + ", ".join(missing))
if problems:
    print("Android native: FAIL (" + "; ".join(problems) + ")")
    sys.exit(1)
print("Android native: PASS")
EOF
