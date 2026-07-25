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
check "exit code" 0 "$(cat "$r/exit")"
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
check "exit code (no config -> fall through to interactive UI)" 2 "$(cat "$r/exit")"

echo "==> install-config.json missing a required field"
r=$(run_agent "$WORK/missing-field.json" /bin/true)
check "exit code (missing field)" 1 "$(cat "$r/exit")"

echo "==> fisherman itself fails"
r=$(run_agent "$WORK/good.json" /bin/false)
check "exit code (fisherman failure)" 1 "$(cat "$r/exit")"

echo "==> cosignIdentity set but cosign not installed"
r=$(run_agent "$WORK/cosign.json" /bin/true)
check "exit code (cosign required, binary absent)" 1 "$(cat "$r/exit")"

echo "==> BOOTSAHI_SKIP_VERIFY escape hatch"
r=$(run_agent "$WORK/cosign.json" /bin/true BOOTSAHI_SKIP_VERIFY=1)
check "exit code (skip-verify escape hatch)" 0 "$(cat "$r/exit")"

if [ "$fail" -ne 0 ]; then
	echo "SELFTEST FAILED"
	exit 1
fi
echo "SELFTEST PASSED"
