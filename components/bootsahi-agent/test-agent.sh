#!/usr/bin/env bash
# test-agent.sh — proves bootsahi-agent's install-config.json -> fisherman
# recipe.json transform and its exit-code contract, without needing real
# disks, network, or a fisherman/bootc binary. Stubs FISHERMAN_BIN with
# generated scripts (see STUBS below — deliberately not host binaries) to
# exercise the success/failure paths; the greetd fallback logic downstream
# depends on the exit codes checked here being exactly right (see
# bootsahi-agent.sh's header comment for the contract).
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

# Fisherman stand-ins as generated scripts, NOT host binaries. This used to
# pass /bin/true and /bin/false — which exist on Linux and DO NOT exist on
# macOS (it ships /usr/bin/true and /usr/bin/false; /bin has neither). On a
# Mac the exec failed, the agent correctly reported "fisherman install failed"
# and exited 1, and the two success-path assertions failed for a reason that
# had nothing to do with the agent.
#
# It also made "==> fisherman itself fails" pass for the wrong reason: it
# expected exit 1 and got exit 1 because /bin/false was ABSENT, not because a
# present fisherman returned nonzero. Generating the stubs means the stub's
# exit status is the only variable, on every host.
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

printf '#!/bin/sh\nexit 0\n' >"$STUBS/fisherman-ok"
printf '#!/bin/sh\nexit 1\n' >"$STUBS/fisherman-fail"
# Echoes the recipe it was handed into the agent's log, AND keeps a verbatim
# copy the assertions can run jq over. The copy is needed because install.log
# interleaves the JSON with the agent's own log lines, and because the agent
# shreds recipe.json itself on success.
printf '#!/bin/sh\ncat "$1"\ncp "$1" "$(dirname "$1")/recipe-captured.json"\n' >"$STUBS/fisherman-dump"
chmod +x "$STUBS"/fisherman-*

# Sanity-check the stubs by RUNNING them, not with `[ -x ]`. The whole bug
# being fixed here was a stand-in that couldn't execute, so verify the thing
# that actually matters. (`[ -x ]` is also not trustworthy everywhere: it
# returns false for mode-755 files under /tmp in some sandboxes even though
# those files execute fine.)
if ! "$STUBS/fisherman-ok"; then
	echo "FAIL: fisherman-ok stub did not run and exit 0 — cannot trust this suite"
	echo "      stub path: $STUBS/fisherman-ok"
	echo "      If this says 'Permission denied', \$TMPDIR is likely mounted noexec"
	echo "      (common on hardened servers, and in some agent sandboxes). Re-run with"
	echo "      TMPDIR pointed somewhere executable, e.g. TMPDIR=\$PWD/.tmp $0"
	exit 1
fi
if "$STUBS/fisherman-fail"; then
	echo "FAIL: fisherman-fail stub exited 0 — cannot trust this suite"
	exit 1
fi

run_agent() { # config_path fisherman_bin [extra_env...]
	local cfg="$1" fbin="$2" rundir usedcfg
	rundir=$(mktemp -d -p "$WORK")
	# Hand the agent a per-run COPY of the config, never the shared fixture.
	# The agent deletes install-config.json on success (it carries the LUKS
	# passphrase and lives on a world-readable vfat ESP), so passing the fixture
	# directly would let the first success-path test delete a file the later
	# tests still need — a self-inflicted ordering dependency.
	usedcfg="$rundir/install-config.json"
	if [ -f "$cfg" ]; then
		cp "$cfg" "$usedcfg"
	else
		usedcfg="$cfg" # nonexistent-on-purpose, for the "no config" case
	fi
	set +e
	env BOOTSAHI_RUN_DIR="$rundir" BOOTSAHI_NO_REBOOT=1 BOOTSAHI_CONFIG_PATH="$usedcfg" \
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
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-ok")
check_exit "exit code" 0 "$r"
check "recipe.json shredded after success" "" "$(ls "$r/recipe.json" 2>/dev/null || true)"
check "install-config.json removed after success" "" "$(ls "$r/install-config.json" 2>/dev/null || true)"
# The agent reports an unexecutable fisherman and a fisherman that ran and
# returned nonzero identically (both "install failed", exit 1). Assert the
# stub was actually EXECUTED, so a future path/permission regression can't
# masquerade as a legitimately-failing install the way /bin/true did.
if grep -q 'No such file or directory' "$r/install.log" 2>/dev/null; then
	echo "FAIL: fisherman stub was never executed (see install.log)"
	dump_agent_output "$r" "stub not executable"
	fail=1
fi

echo "==> recipe.json shape (fisherman dumps the recipe into install.log)"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-dump")
# shape_fail is separate from the global `fail` on purpose: this block used to
# gate its "ok" on `fail`, so any EARLIER failing test silenced it entirely and
# the shape checks reported neither ok nor FAIL — leaving you unable to tell
# whether they ran, passed, or were skipped.
shape_fail=0
grep -q '"bootloader": "systemd"' "$r/install.log" || { echo "FAIL: recipe missing bootloader=systemd"; shape_fail=1; }
grep -q '"target": "/"' "$r/install.log" || { echo "FAIL: recipe missing root customMount"; shape_fail=1; }
grep -q '"target": "/boot/efi"' "$r/install.log" || { echo "FAIL: recipe missing ESP customMount"; shape_fail=1; }
grep -q '"imageType": "bootc"' "$r/install.log" || { echo "FAIL: recipe missing imageType=bootc"; shape_fail=1; }
if [ "$shape_fail" -eq 0 ]; then
	echo "ok: recipe.json shape"
else
	dump_agent_output "$r" "recipe.json shape"
	fail=1
fi

# ── fstype tokens must be ones fisherman actually accepts ────────────────
# The grep-for-substrings assertions above are why a bogus fstype survived: they
# checked that a /boot/efi mount EXISTED, never what it would DO. fisherman's
# recipe.Validate() doesn't check customMounts fstypes either, so an unknown
# token isn't caught until disk.formatPartition() fatals at install step 1 —
# on real hardware, after the disk has already been repartitioned.
#
# Accepted set is disk.formatPartition()'s switch plus the two skip-format
# sentinels. Keep in sync with internal/disk/custom.go.
CAPTURED="$r/recipe-captured.json"
if [ ! -f "$CAPTURED" ]; then
	echo "FAIL: fisherman-dump did not capture a recipe to inspect"
	fail=1
else
	bad=$(jq -r '
		["fat32","ext4","ext3","xfs","btrfs","unformatted","swap",""] as $ok
		| .customMounts[]
		| select((.fstype // "") as $f | $ok | index($f) | not)
		| "\(.target)=\(.fstype)"
	' "$CAPTURED")
	if [ -n "$bad" ]; then
		echo "FAIL: fstype not accepted by fisherman's formatPartition: $bad"
		fail=1
	else
		echo "ok: all customMounts fstypes are tokens fisherman accepts"
	fi

	# The ESP must never be reformatted: it already holds m1n1/boot.bin, the
	# bootloader, and vendorfw/ — on-device-extracted Apple firmware that is not
	# redistributable and cannot be recovered. Anything but a skip-format token
	# here is a DFU-restore-grade bug, so assert it explicitly rather than
	# relying on it being in the accepted set above.
	esp_fstype=$(jq -r '.customMounts[] | select(.target == "/boot/efi") | .fstype' "$CAPTURED")
	case "$esp_fstype" in
	unformatted | "") echo "ok: ESP is not reformatted (fstype=${esp_fstype:-<empty>})" ;;
	*)
		echo "FAIL: ESP fstype is '$esp_fstype' — this runs mkfs on the ESP and destroys m1n1/boot.bin + vendorfw"
		fail=1
		;;
	esac
fi

echo "==> no install-config.json present"
r=$(run_agent "$WORK/does-not-exist.json" "$STUBS/fisherman-ok")
check_exit "exit code (no config -> fall through to interactive UI)" 2 "$r"

echo "==> install-config.json missing a required field"
r=$(run_agent "$WORK/missing-field.json" "$STUBS/fisherman-ok")
check_exit "exit code (missing field)" 1 "$r"

echo "==> fisherman itself fails"
r=$(run_agent "$WORK/good.json" "$STUBS/fisherman-fail")
check_exit "exit code (fisherman failure)" 1 "$r"
# The complement of the deletion above: on failure the config must SURVIVE, or
# the interactive fisherman UI we fall back to has nothing to retry from.
check "install-config.json preserved after failure" "$r/install-config.json" \
	"$(ls "$r/install-config.json" 2>/dev/null || true)"

echo "==> cosignIdentity set but cosign not installed"
r=$(run_agent "$WORK/cosign.json" "$STUBS/fisherman-ok")
check_exit "exit code (cosign required, binary absent)" 1 "$r"

echo "==> BOOTSAHI_SKIP_VERIFY escape hatch"
r=$(run_agent "$WORK/cosign.json" "$STUBS/fisherman-ok" BOOTSAHI_SKIP_VERIFY=1)
check_exit "exit code (skip-verify escape hatch)" 0 "$r"

if [ "$fail" -ne 0 ]; then
	echo "SELFTEST FAILED"
	exit 1
fi
echo "SELFTEST PASSED"
