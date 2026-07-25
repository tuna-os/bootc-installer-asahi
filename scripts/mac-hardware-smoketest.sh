#!/usr/bin/env bash
# mac-hardware-smoketest.sh — first real-hardware pass, per docs/TESTING-CHECKLIST.md.
#
# Covers checklist steps 0-2 (prerequisites, does the D3 app build/launch,
# one real D2 ask/answer round trip) plus D1's own selftest. Does NOT touch
# any disk and does NOT attempt an actual install — steps 3-6 in the
# checklist (D3 driving D2 for real, the install-config.json handoff design
# gap, D1 against a scratch disk, a real install) are deliberately not
# automated here: they need a human decision or a disk you're willing to
# risk, not a script.
#
# Usage:
#   ./mac-hardware-smoketest.sh
#   BOOTC_INSTALLER_ASAHI_DIR=~/dev/bootc-installer-asahi \
#   ASAHI_INSTALLER_DIR=~/dev/asahi-installer \
#     ./mac-hardware-smoketest.sh
#
# If BOOTC_INSTALLER_ASAHI_DIR / ASAHI_INSTALLER_DIR aren't set and no
# existing checkout is found nearby, missing repos are cloned fresh into a
# scratch temp dir (read-only smoke test — safe to throw away after).
set -uo pipefail

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# ── 0. Prerequisites ──────────────────────────────────────────────────────
section "Prerequisites"

check_tool() { # name, check-command...
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$name"
	else
		fail "$name (not found or not working: $*)"
	fi
}

check_tool "Xcode Command Line Tools" xcode-select -p
check_tool "swift" swift --version

# xctest_framework_path echoes the XCTest.framework path under the ACTIVE
# developer directory, or nothing. Always exits 0 — callers branch on whether
# stdout is empty, not on status (this script runs with `set -u` and treating
# "no Xcode" as an error would abort the remaining checks).
xctest_framework_path() {
	local devdir fw
	devdir="$(xcode-select -p 2>/dev/null)" || return 0
	[ -n "$devdir" ] || return 0
	fw="$devdir/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"
	[ -d "$fw" ] && echo "$fw"
	return 0
}

if [ -n "$(xctest_framework_path)" ]; then
	pass "XCTest available (full Xcode) — swift test can run"
else
	skip "XCTest not available under $(xcode-select -p 2>/dev/null || echo '<no developer dir>') — swift test will be skipped (needs Xcode.app, not just CLT)"
fi

check_tool "python3" python3 --version
check_tool "jq" jq --version

# ── Locate repos ─────────────────────────────────────────────────────────
section "Locating repos"

find_or_clone() { # var-name, env-var-value, candidate-dirs..., -- , clone-url, clone-args...
	local var="$1" envval="$2"
	shift 2
	local candidates=()
	while [ "$1" != "--" ]; do
		candidates+=("$1")
		shift
	done
	shift # drop --
	local url="$1"
	shift

	if [ -n "$envval" ] && [ -d "$envval" ]; then
		printf -v "$var" '%s' "$envval"
		pass "$var = $envval (from env)"
		return
	fi
	for c in "${candidates[@]}"; do
		if [ -d "$c" ]; then
			printf -v "$var" '%s' "$c"
			pass "$var = $c (found nearby)"
			return
		fi
	done
	local dest
	dest="$SCRATCH/$(basename "$url" .git)"
	printf '  cloning %s -> %s\n' "$url" "$dest"
	if git clone --quiet "$@" "$url" "$dest" >/dev/null 2>&1; then
		printf -v "$var" '%s' "$dest"
		pass "$var = $dest (freshly cloned)"
	else
		fail "could not clone $url"
		printf -v "$var" ''
	fi
}

# Only offer "the directory this script lives in" as a candidate when it's
# actually a real file on disk (BASH_SOURCE[0]) — under `curl | bash`, bash
# reads the script from stdin and BASH_SOURCE has no elements at all, so
# indexing it under `set -u` throws "unbound variable", and the broken
# command substitution used to silently resolve to "/" (cd "" + "/.." -> /),
# which then "found" as a valid-but-wrong BOOTC_DIR and skipped every real
# check. Guard it instead of relying on it being set.
self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

find_or_clone BOOTC_DIR "${BOOTC_INSTALLER_ASAHI_DIR:-}" \
	"$HOME/dev/bootc-installer-asahi" "$HOME/dev/tuna-os/bootc-installer-asahi" \
	${self_dir:+"$self_dir"} \
	-- https://github.com/tuna-os/bootc-installer-asahi.git

find_or_clone ASAHI_INSTALLER_DIR "${ASAHI_INSTALLER_DIR:-}" \
	"$HOME/dev/asahi-installer" "$HOME/dev/hanthor/asahi-installer" \
	-- https://github.com/hanthor/asahi-installer.git --branch json-machine-mode

# ── 1. D1 selftest (protocol/exit-code contract) ─────────────────────────
section "D1: bootsahi-agent selftest"
if [ -n "$BOOTC_DIR" ] && [ -x "$BOOTC_DIR/components/bootsahi-agent/test-agent.sh" ]; then
	if bash "$BOOTC_DIR/components/bootsahi-agent/test-agent.sh" >/tmp/bootsahi-agent-selftest.log 2>&1; then
		pass "test-agent.sh (log: /tmp/bootsahi-agent-selftest.log)"
	else
		fail "test-agent.sh — see /tmp/bootsahi-agent-selftest.log"
	fi
else
	skip "test-agent.sh not found"
fi

# ── 2. D3: does the SwiftUI app build and test? ───────────────────────────
section "D3: swift build / swift test"
BOOTSAHI_DIR="${BOOTC_DIR:+$BOOTC_DIR/macos-app/Bootsahi}"
if [ -n "$BOOTSAHI_DIR" ] && [ -f "$BOOTSAHI_DIR/Package.swift" ]; then
	if (cd "$BOOTSAHI_DIR" && swift build >/tmp/bootsahi-build.log 2>&1); then
		pass "swift build (log: /tmp/bootsahi-build.log)"
	else
		fail "swift build — see /tmp/bootsahi-build.log"
	fi
	# `swift test` needs XCTest, which lives inside Xcode.app — NOT in the
	# Command Line Tools. With CLT only, `swift build` succeeds and `swift test`
	# dies with "no such module 'XCTest'". That's a host toolchain limitation,
	# not a defect in the app, so report it as a SKIP with the actual remedy
	# instead of a FAIL that sends you hunting through Swift source. (Cost me a
	# round trip: CI's macos-14 runner has full Xcode and passes 15/15, so the
	# failure looked Mac-specific and code-shaped when it was neither.)
	if [ -n "$(xctest_framework_path)" ]; then
		if (cd "$BOOTSAHI_DIR" && swift test >/tmp/bootsahi-test.log 2>&1); then
			pass "swift test (log: /tmp/bootsahi-test.log)"
		else
			fail "swift test — see /tmp/bootsahi-test.log"
		fi
	else
		skip "swift test — XCTest not available (Command Line Tools only, no Xcode.app).
       swift build above still covers compile/link correctness, and the same
       tests run green on CI's full-Xcode runner. To run them locally: install
       Xcode.app, then
         sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
	fi
else
	skip "Package.swift not found under $BOOTSAHI_DIR"
fi

# ── 2b. D3: does the app actually launch? (checklist step 1) ─────────────
section "D3: does the app launch (not just compile)?"
if [ -n "$BOOTSAHI_DIR" ] && [ -f "$BOOTSAHI_DIR/Package.swift" ]; then
	(cd "$BOOTSAHI_DIR" && swift run >/tmp/bootsahi-run.log 2>&1 &
	 echo $! >/tmp/bootsahi-run.pid)
	sleep 8
	RUNPID=$(cat /tmp/bootsahi-run.pid 2>/dev/null || echo "")
	if [ -n "$RUNPID" ] && kill -0 "$RUNPID" 2>/dev/null; then
		pass "app process still running 8s after launch (log: /tmp/bootsahi-run.log)"
		kill "$RUNPID" 2>/dev/null
		wait "$RUNPID" 2>/dev/null
	else
		fail "app process exited within 8s — see /tmp/bootsahi-run.log"
	fi
else
	skip "Package.swift not found"
fi

# ── 3. D2: one real ask/answer round trip ─────────────────────────────────
section "D2: one real ask/answer round trip (protocol only — no real disk/mac probing)"
if [ -n "$ASAHI_INSTALLER_DIR" ] && [ -f "$ASAHI_INSTALLER_DIR/src/main.py" ]; then
	# main.py needs installer_data.json / version.tag / boot/m1n1.bin to even
	# construct InstallerMain — these are build.sh release artifacts, not in
	# git. Stub them in a throwaway copy so this stays read-only and doesn't
	# touch your real checkout. This proves the JSON protocol handshake
	# works; it does NOT exercise real hardware/disk detection at all
	# (system.py's SystemInfo() still runs for real — that part IS live).
	D2SCRATCH="$SCRATCH/asahi-installer-run"
	mkdir -p "$D2SCRATCH/boot"
	cp "$ASAHI_INSTALLER_DIR/src/"*.py "$D2SCRATCH/" 2>/dev/null
	ln -sf "$ASAHI_INSTALLER_DIR/src/asahi_firmware" "$D2SCRATCH/asahi_firmware" 2>/dev/null
	echo '{"os_list": []}' >"$D2SCRATCH/installer_data.json"
	echo "smoketest" >"$D2SCRATCH/version.tag"
	printf 'stub' >"$D2SCRATCH/boot/m1n1.bin"

	# macOS ships no `timeout(1)` by default (it's GNU coreutils; `gtimeout`
	# via brew if installed). Not load-bearing here — the Python below has
	# its own internal timeouts (thread join + select, ~25s worst case) and
	# always proc.terminate()s before exiting, so run bare if neither exists.
	TIMEOUT_CMD=""
	if command -v timeout >/dev/null 2>&1; then
		TIMEOUT_CMD="timeout 30"
	elif command -v gtimeout >/dev/null 2>&1; then
		TIMEOUT_CMD="gtimeout 30"
	fi
	RESULT=$(cd "$D2SCRATCH" && $TIMEOUT_CMD python3 - <<'PYEOF'
import json, subprocess, sys, threading

proc = subprocess.Popen(
    [sys.executable, "main.py", "--json"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1,
)

events = []
def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
        if events[-1].get("event") == "ask":
            break

t = threading.Thread(target=reader, daemon=True)
t.start()
t.join(timeout=15)

if not events or events[-1].get("event") != "ask":
    print("NO_ASK_RECEIVED")
    proc.kill()
    sys.exit(1)

ask = events[-1]
proc.stdin.write(json.dumps({"id": ask["id"], "value": None}) + "\n")
proc.stdin.flush()

# One more line proves the round trip: the installer moved past the ask.
import select
ready, _, _ = select.select([proc.stdout], [], [], 10)
proc.terminate()
if ready:
    print("ROUND_TRIP_OK")
else:
    print("NO_FOLLOWUP_AFTER_ANSWER")
PYEOF
)
	if [ "$RESULT" = "ROUND_TRIP_OK" ]; then
		pass "ask -> answer -> follow-up round trip"
	else
		fail "round trip did not complete (got: ${RESULT:-<nothing>})"
	fi
else
	skip "src/main.py not found under $ASAHI_INSTALLER_DIR"
fi

# ── Summary ────────────────────────────────────────────────────────────
section "Summary"
echo "  pass: $PASS   fail: $FAIL   skip: $SKIP"
[ "$FAIL" -eq 0 ]
