#!/usr/bin/env bash
# test-backend-contract.sh — hold the D2 backend to the contract D1 depends on.
#
# The macOS backend (asahi-installer --json machine mode) and the Linux
# first-boot agent are developed in different repos, in different languages,
# and are exercised by different test suites that never meet. The only thing
# joining them is <ESP>/asahi/stub_info.json: the backend records which
# partitions it created, and the agent uses that to decide which partition it
# is allowed to format.
#
# That is the most dangerous handoff in the project. If the backend renames
# "role", stops lowercasing "uuid", or drops a field, nothing fails until an
# agent on a real Mac either refuses to install or — far worse — resolves to
# the wrong partition. Both sides' tests would stay green the whole time,
# because each side tests its own idea of the shape.
#
# So this asserts the two agree, at a PINNED backend revision:
#
#   1. the backend's own --json protocol suite still passes at that revision
#      (24 tests, no macOS needed — they mock stdin/stdout);
#   2. the producer still emits every key the agent consumes, checked against
#      the backend's real source rather than against our fixtures.
#
# Usage: ./scripts/test-backend-contract.sh
set -euo pipefail

# Pinned deliberately, exactly like FISHERMAN_REV. "Which backend did we test
# against?" has to stay answerable after the fact, and a floating branch would
# make a green run mean nothing in a week.
BACKEND_REPO="${BACKEND_REPO:-https://github.com/hanthor/asahi-installer}"
BACKEND_REV="${BACKEND_REV:-4cb26d8a0d831476b7e76bdf88cda0a8c5b5164e}"

for t in git python3; do
	command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done
if ! python3 -c "import pytest" 2>/dev/null; then
	echo "SKIP: pytest not available; cannot run the backend's own suite."
	echo "      This is the check that proves the pinned backend still works,"
	echo "      so its absence is worth noticing rather than passing silently."
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0

echo "==> Fetching the pinned backend ($BACKEND_REV)"
git clone --quiet "$BACKEND_REPO" "$WORK/backend"
git -C "$WORK/backend" checkout --quiet "$BACKEND_REV"

# ── 1. The backend's own protocol suite, at the revision we target ───────────
echo
echo "==> The backend's --json protocol suite"
if (cd "$WORK/backend/src" && python3 -m pytest test_json_mode.py -q >"$WORK/pytest.log" 2>&1); then
	echo "ok: $(tail -1 "$WORK/pytest.log")"
else
	echo "FAIL: the pinned backend's own json-mode tests do not pass"
	tail -20 "$WORK/pytest.log" | sed 's/^/      | /'
	fail=1
fi

# ── 2. The stub_info contract ───────────────────────────────────────────────
# Read the keys straight out of the producer rather than trusting a fixture we
# wrote. A fixture agreeing with itself proves nothing; the point is to notice
# when the OTHER side changes.
echo
echo "==> stub_info.json keys: what the backend emits vs what the agent reads"

produced=$(python3 - "$WORK/backend/src/main.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
i = src.find('stub_info["partitions"]')
if i == -1:
    print("PRODUCER-BLOCK-NOT-FOUND")
    sys.exit(0)
# The assignment is a list comprehension over a dict literal; take up to the
# comprehension's `for`, which ends the dict body.
block = src[i:]
end = block.find("for part, info in")
block = block[:end if end != -1 else 2000]
keys = re.findall(r'"([a-z_]+)":', block)
print(" ".join(sorted(set(keys))))
PY
)

if [ "$produced" = "PRODUCER-BLOCK-NOT-FOUND" ]; then
	echo "FAIL: could not find the stub_info[\"partitions\"] producer in the backend."
	echo "      Either it moved or it was refactored away — either way the contract"
	echo "      this test exists to police is no longer where it was."
	fail=1
	produced=""
fi
echo "    backend emits: ${produced:-<none>}"

# What the agent actually reads out of each partition entry. Kept explicit
# rather than grepped: this is the list we are asserting the backend still
# satisfies, so it should be a deliberate statement, not an inference.
AGENT_NEEDS="role uuid"
echo "    agent needs:   $AGENT_NEEDS"

for k in $AGENT_NEEDS; do
	case " $produced " in
		*" $k "*) echo "ok: backend still emits '$k'" ;;
		*)
			echo "FAIL: the agent resolves its install target using '$k', and the pinned"
			echo "      backend no longer emits it. On hardware this is either a refusal"
			echo "      to install or a resolution to the wrong partition."
			fail=1
			;;
	esac
done

# The inverse direction, and the reason it matters: macos_device is present in
# the record and the agent must NEVER resolve by it — it is a macOS device name
# ("disk0s5") that means nothing under Linux, where the same partition is
# nvme0n1p5. Verified against the agent source, because this is a mistake that
# would look completely reasonable in review.
echo
echo "==> the agent must not resolve by the macOS device name"
if grep -q "macos_device" components/bootsahi-agent/bootsahi-agent.sh 2>/dev/null; then
	echo "FAIL: bootsahi-agent references macos_device. That field is a macOS device"
	echo "      name and does not identify anything under Linux."
	fail=1
else
	echo "ok: the agent never reads macos_device"
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "BACKEND CONTRACT FAILED"
	exit 1
fi
echo "BACKEND CONTRACT PASSED (backend $BACKEND_REV)"
