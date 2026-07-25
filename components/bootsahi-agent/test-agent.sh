#!/usr/bin/env bash
# test-agent.sh — proves bootsahi-agent's install-config.json -> fisherman
# recipe.json transform and its exit-code contract, without needing real
# disks, network, or a fisherman/bootc binary. Stubs FISHERMAN_BIN with
# /bin/true or /bin/false to exercise the success/failure paths; the greetd
# fallback logic downstream depends on the exit codes checked here being
# exactly right (see bootsahi-agent.sh's header comment for the contract).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/bootsahi-agent.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1 (expected $2, got $3)"
		fail=1
	else
		echo "ok: $1"
	fi
}

# dump_agent_output prints the agent's own stdout + install.log for a run
# directory. Without this a failure only tells you the exit code was wrong,
# not WHERE the agent stopped — and the EXIT trap deletes $WORK, so the
# evidence is gone before you can look. Bit me diagnosing a macOS-only
# failure; same lesson as dakota's error-lines truncation.
dump_agent_output() { # rundir label
	echo "  ---- $2: agent stdout ----"
	sed 's/^/  | /' "$1/stdout" 2>/dev/null || echo "  | (no stdout captured)"
	echo "  ---- $2: install.log ----"
	sed 's/^/  | /' "$1/install.log" 2>/dev/null || echo "  | (no install.log written)"
	echo "  ---- $2: files in rundir ----"
	ls -la "$1" 2>/dev/null | sed 's/^/  | /'
	echo "  --------------------------------"
}

# check_exit wraps check() and dumps diagnostics when the exit code is wrong.
check_exit() { # description expected rundir
	local actual
	actual="$(cat "$3/exit")"
	check "$1" "$2" "$actual"
	[ "$2" != "$actual" ] && dump_agent_output "$3" "$1"
	return 0
}

run_agent() { # config_path fisherman_bin [extra_env...]
	local cfg="$1" fbin="$2" rundir
	rundir=$(mktemp -d -p "$WORK")
	set +e
	env BOOTSAHI_RUN_DIR="$rundir" BOOTSAHI_NO_REBOOT=1 BOOTSAHI_CONFIG_PATH="$cfg" \
		BOOTSAHI_FISHERMAN_BIN="$fbin" "${@:3}" bash "$AGENT" >"$rundir/stdout" 2>&1
	echo $? >"$rundir/exit"
	set -e
	echo "$rundir"
}

cat >"$WORK/good.json" <<'EOF'
{
  "targetImgref": "ghcr.io/tuna-os/bonito:gnome-asahi",
  "rootPartition": "/dev/null",
  "espPartition": "/dev/null",
  "filesystem": "btrfs",
  "hostname": "tuna-mac",
  "user": {"username": "james", "groups": ["wheel"]},
  "encryption": {"type": "none"}
}
EOF

cat >"$WORK/missing-field.json" <<'EOF'
{"targetImgref": "x", "rootPartition": "/dev/null", "espPartition": "/dev/null", "filesystem": "btrfs"}
EOF

cat >"$WORK/cosign.json" <<'EOF'
{
  "targetImgref": "x", "rootPartition": "/dev/null", "espPartition": "/dev/null",
  "filesystem": "btrfs", "hostname": "h",
  "cosignIdentity": "https://example.test/signer", "cosignIssuer": "https://example.test/oidc"
}
EOF

echo "==> success path (fisherman succeeds)"
r=$(run_agent "$WORK/good.json" /bin/true)
check_exit "exit code" 0 "$r"
check "recipe.json shredded after success" "" "$(ls "$r/recipe.json" 2>/dev/null || true)"

echo "==> recipe.json shape (fisherman=cat, inspect via install.log)"
r=$(run_agent "$WORK/good.json" cat)
grep -q '"bootloader": "systemd"' "$r/install.log" || { echo "FAIL: recipe missing bootloader=systemd"; fail=1; }
grep -q '"target": "/"' "$r/install.log" || { echo "FAIL: recipe missing root customMount"; fail=1; }
grep -q '"target": "/boot/efi"' "$r/install.log" || { echo "FAIL: recipe missing ESP customMount"; fail=1; }
grep -q '"imageType": "bootc"' "$r/install.log" || { echo "FAIL: recipe missing imageType=bootc"; fail=1; }
[ $fail -eq 0 ] && echo "ok: recipe.json shape"

echo "==> no install-config.json present"
r=$(run_agent "$WORK/does-not-exist.json" /bin/true)
check_exit "exit code (no config -> fall through to interactive UI)" 2 "$r"

echo "==> install-config.json missing a required field"
r=$(run_agent "$WORK/missing-field.json" /bin/true)
check_exit "exit code (missing field)" 1 "$r"

echo "==> fisherman itself fails"
r=$(run_agent "$WORK/good.json" /bin/false)
check_exit "exit code (fisherman failure)" 1 "$r"

echo "==> cosignIdentity set but cosign not installed"
r=$(run_agent "$WORK/cosign.json" /bin/true)
check_exit "exit code (cosign required, binary absent)" 1 "$r"

echo "==> BOOTSAHI_SKIP_VERIFY escape hatch"
r=$(run_agent "$WORK/cosign.json" /bin/true BOOTSAHI_SKIP_VERIFY=1)
check_exit "exit code (skip-verify escape hatch)" 0 "$r"

if [ "$fail" -ne 0 ]; then
	echo "SELFTEST FAILED"
	exit 1
fi
echo "SELFTEST PASSED"
