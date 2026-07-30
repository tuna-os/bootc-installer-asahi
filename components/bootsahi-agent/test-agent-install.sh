#!/usr/bin/env bash
# test-agent-install.sh — run the REAL fisherman through a REAL install against a
# disposable loop disk, and prove what it did and did not touch. (issue #26)
#
# Everything before this test was producer-side. test-agent.sh checks the
# config->recipe transform, test-agent-disk.sh checks partition SELECTION with a
# recording stub, and the `fisherman validate` step added there checks that the
# recipe PARSES. None of them execute an install, so none of them can observe
# consumer semantics — what fisherman actually does to the disk when it runs.
#
# That gap is why this exists. The `vfat` defect (#17) survived every
# producer-side assertion because the recipe looked right to us; it would have
# died mid-install, after partitioning. `validate` catches that specific class
# now, but validate is a parser, and the questions that destroy someone's Mac
# are not parse questions:
#
#   - does fstype "unformatted" really skip mkfs on the ESP, or merely skip a
#     check? The ESP holds m1n1, boot.bin, the bootloader, and vendorfw/ —
#     Apple firmware extracted on-device that we may not redistribute. mkfs
#     there means a DFU restore, and the user's macOS is gone with it.
#   - does the install stay inside the partition it was given, or does it touch
#     neighbours? On a real Mac the neighbours are the user's macOS install.
#   - does the bootstrap partition — the one the agent is RUNNING from — survive?
#
# So: seed a canary on every partition, run the real thing, and assert
# preservation and mutation explicitly, per partition. A canary that survives
# where it should have died is as much a failure as the reverse; "the install
# passed" is not evidence that it installed anything.
#
# This is destructive by design, but only to a loop file in a temp dir. It
# refuses to run against anything that is not a loop device.
#
# Needs root, losetup, sgdisk, podman, and a real fisherman binary.
# Usage: sudo FISHERMAN_BIN=/path/to/fisherman ./test-agent-install.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AGENT="$HERE/bootsahi-agent.sh"

# The image fisherman will actually deploy. Defaults to the one variant proven
# to pass the Asahi golden-manifest harness (tuna-os/tunaOS#776) — six of the
# eight promoted asahi tags are unbootable, so "any asahi image" is not a safe
# default. Overridable because a smaller bootc image exercises the same
# fisherman code paths for a fraction of the pull, and this test is about
# fisherman's behaviour, not about any one image's contents.
TARGET_IMAGE="${TARGET_IMAGE:-ghcr.io/tuna-os/bonito:gnome-asahi}"
DISK_SIZE="${DISK_SIZE:-14G}"

if [ "$(id -u)" -ne 0 ]; then
	echo "SKIP: needs root for losetup + bootc install (run: sudo $0)"
	exit 0
fi
for t in sgdisk blkid losetup jq podman mkfs.ext4 mkfs.vfat; do
	command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 0; }
done

FISHERMAN_BIN="${FISHERMAN_BIN:-$(command -v fisherman 2>/dev/null || true)}"
if [ -z "$FISHERMAN_BIN" ] || [ ! -x "$FISHERMAN_BIN" ]; then
	# Loud, not silent. This is the only test in the tree that can observe what
	# an install does to a disk; skipping it quietly would let the suite report
	# green while the single most expensive question stays unasked.
	echo "SKIP: no fisherman binary."
	echo "      This is the ONLY test that runs a real install, so its absence means"
	echo "      consumer semantics are unverified — the ESP-preservation and"
	echo "      neighbour-preservation guarantees are assertions, not observations."
	echo "      Set FISHERMAN_BIN=/path/to/fisherman to enable."
	exit 0
fi

WORK=$(mktemp -d)
LOOP=""
cleanup() {
	for m in "$WORK"/mnt-*; do
		[ -d "$m" ] && umount -R "$m" 2>/dev/null
	done
	# Only ever detach a loop device this script created.
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

fail=0
check() { # description expected actual
	if [ "$2" != "$3" ]; then
		echo "FAIL: $1"
		echo "      expected: $2"
		echo "      actual:   $3"
		fail=1
	else
		echo "ok: $1"
	fi
}

echo "==> target image: $TARGET_IMAGE"
echo "    fisherman:    $("$FISHERMAN_BIN" version 2>/dev/null | head -1)"

# ── A disk shaped like a Mac mid-install ────────────────────────────────────
# ESP + a stand-in for the user's macOS data + the bootstrap we are running
# from + the target. The macOS stand-in is the whole point of the neighbour
# assertion: on real hardware that partition is everything the user owns.
echo
echo "==> Building a GPT loop disk (ESP + macOS-stand-in + Bootstrap + Target)"
truncate -s "$DISK_SIZE" "$WORK/disk.img"
sgdisk --clear \
	--new=1:0:+512M --typecode=1:EF00 --change-name=1:"EFI - selftest" \
	--new=2:0:+64M  --typecode=2:AF00 --change-name=2:"macOS - selftest" \
	--new=3:0:+512M --typecode=3:8300 --change-name=3:"Bootstrap - selftest" \
	--new=4:0:0     --typecode=4:8300 --change-name=4:"Root - selftest" \
	"$WORK/disk.img" >/dev/null
LOOP=$(losetup --find --show -P "$WORK/disk.img")
udevadm settle 2>/dev/null || sleep 1

case "$LOOP" in
	/dev/loop*) ;;
	*) echo "FAIL: refusing to continue — $LOOP is not a loop device"; exit 1 ;;
esac

ESP_DEV="${LOOP}p1"
MACOS_DEV="${LOOP}p2"
BOOTSTRAP_DEV="${LOOP}p3"
TARGET_DEV="${LOOP}p4"
for d in "$ESP_DEV" "$MACOS_DEV" "$BOOTSTRAP_DEV" "$TARGET_DEV"; do
	[ -b "$d" ] || { echo "FAIL: $d did not appear; loop partition scanning unavailable"; exit 1; }
done

# ── Seed canaries ───────────────────────────────────────────────────────────
# The ESP canary deliberately imitates what is actually at risk: the vendor
# firmware directory asahi-installer extracts on-device. It cannot be
# re-downloaded — Apple does not permit redistributing it — so if a bug ever
# mkfs'd the ESP, this is the file whose loss forces a DFU restore.
echo "==> Seeding canaries"
mkfs.vfat -F 32 -n EFI "$ESP_DEV" >/dev/null
mkdir -p "$WORK/mnt-esp"
mount "$ESP_DEV" "$WORK/mnt-esp"
mkdir -p "$WORK/mnt-esp/vendorfw" "$WORK/mnt-esp/m1n1"
echo "APPLE-VENDORFW-CANARY" >"$WORK/mnt-esp/vendorfw/firmware.tar"
echo "M1N1-CANARY"           >"$WORK/mnt-esp/m1n1/boot.bin"
umount "$WORK/mnt-esp"

seed_ext4() { # dev label canary-content
	mkfs.ext4 -q -F -L "$2" "$1"
	local m="$WORK/mnt-seed"
	mkdir -p "$m"
	mount "$1" "$m"
	echo "$3" >"$m/CANARY"
	umount "$m"
}
seed_ext4 "$MACOS_DEV"     macos     "MACOS-USER-DATA-CANARY"
seed_ext4 "$BOOTSTRAP_DEV" bootstrap "BOOTSTRAP-CANARY"
seed_ext4 "$TARGET_DEV"    target    "TARGET-CANARY-SHOULD-BE-DESTROYED"

partuuid() { blkid -s PARTUUID -o value "$1"; }
ESP_UUID=$(partuuid "$ESP_DEV")
BOOTSTRAP_UUID=$(partuuid "$BOOTSTRAP_DEV")
TARGET_UUID=$(partuuid "$TARGET_DEV")

PU="$WORK/by-partuuid"
mkdir -p "$PU"
ln -sf "$ESP_DEV" "$PU/$ESP_UUID"
ln -sf "$BOOTSTRAP_DEV" "$PU/$BOOTSTRAP_UUID"
ln -sf "$TARGET_DEV" "$PU/$TARGET_UUID"

# The partition fields are deliberately bogus AND deliberately distinct. Bogus
# because the agent resolves the real devices by PARTUUID and role (#22) and
# must ignore whatever the config claims — if these values ever reached
# fisherman the install would fail loudly rather than silently do the wrong
# thing. Distinct because the agent refuses when root and ESP name the same
# device, which is a correct refusal that would otherwise mask the whole test:
# the first run of this had both as /dev/null and never installed anything.
cat >"$WORK/install-config.json" <<EOF
{
  "targetImgref": "$TARGET_IMAGE",
  "rootPartition": "/dev/null",
  "espPartition": "/dev/zero",
  "filesystem": "ext4",
  "hostname": "install-selftest",
  "encryption": {"type": "none"}
}
EOF

cat >"$WORK/stub_info.json" <<EOF
{"vgid": "selftest",
 "partitions": [
  {"name": "EFI", "role": "esp", "type": "EFI", "uuid": "$ESP_UUID"},
  {"name": "Bootstrap", "role": "bootstrap", "type": "Linux", "uuid": "$BOOTSTRAP_UUID"},
  {"name": "Root", "role": "target", "type": "Linux", "uuid": "$TARGET_UUID"}
 ]}
EOF

# ── Run the real thing ──────────────────────────────────────────────────────
echo
echo "==> Running the agent with the REAL fisherman (this performs an install)"
RUNDIR="$WORK/run"
mkdir -p "$RUNDIR"
cp "$WORK/install-config.json" "$RUNDIR/install-config.json"
set +e
env BOOTSAHI_RUN_DIR="$RUNDIR" BOOTSAHI_NO_REBOOT=1 \
	BOOTSAHI_CONFIG_PATH="$RUNDIR/install-config.json" \
	BOOTSAHI_STUB_INFO_PATH="$WORK/stub_info.json" \
	BOOTSAHI_PARTUUID_DIR="$PU" \
	BOOTSAHI_SKIP_HW_CHECK=1 \
	BOOTSAHI_FISHERMAN_BIN="$FISHERMAN_BIN" \
	bash "$AGENT" >"$RUNDIR/stdout" 2>&1
agent_rc=$?
set -e
echo "    agent exit: $agent_rc"

if [ "$agent_rc" -ne 0 ]; then
	echo "FAIL: the agent did not complete the install (exit $agent_rc)"
	echo "      ---- agent stdout ----"
	sed 's/^/      | /' "$RUNDIR/stdout" 2>/dev/null | tail -60
	echo "      ---- install.log ----"
	sed 's/^/      | /' "$RUNDIR/install.log" 2>/dev/null | tail -80
	fail=1
fi

# ── What survived, and what did not ─────────────────────────────────────────
# These run even when the install failed. A failed install that ALSO ate the
# ESP is a materially worse bug than a failed install, and the canaries are the
# only way to tell those apart.
echo
echo "==> Canaries: what the install touched"

read_canary() { # dev path-within
	local m="$WORK/mnt-check"
	mkdir -p "$m"
	if mount -o ro "$1" "$m" 2>/dev/null; then
		local v
		v=$(cat "$m/$2" 2>/dev/null || echo "<absent>")
		umount "$m"
		echo "$v"
	else
		echo "<unmountable>"
	fi
}

# The ESP must keep its pre-existing contents. "unformatted" means fisherman
# skips the mkfs, NOT that it leaves the partition alone — it still writes boot
# entries there, which is correct and required. So this asserts the vendor
# firmware and m1n1 payload SURVIVE alongside whatever was added.
check "ESP: Apple vendor firmware preserved" \
	"APPLE-VENDORFW-CANARY" "$(read_canary "$ESP_DEV" vendorfw/firmware.tar)"
check "ESP: m1n1 payload preserved" \
	"M1N1-CANARY" "$(read_canary "$ESP_DEV" m1n1/boot.bin)"

# The neighbour. On hardware this is the user's macOS install, and nothing in a
# correct install has any reason to touch it.
check "neighbour (macOS stand-in): untouched" \
	"MACOS-USER-DATA-CANARY" "$(read_canary "$MACOS_DEV" CANARY)"

# The partition the agent is running from. #22 covers selecting it correctly;
# this proves the consumer honours that selection.
check "bootstrap partition: untouched" \
	"BOOTSTRAP-CANARY" "$(read_canary "$BOOTSTRAP_DEV" CANARY)"

# And the inverse: the target MUST have been formatted. Without this the three
# assertions above are satisfied perfectly by an install that did nothing at
# all — the exact failure mode where a test passes and the product is broken.
target_canary=$(read_canary "$TARGET_DEV" CANARY)
if [ "$target_canary" = "TARGET-CANARY-SHOULD-BE-DESTROYED" ]; then
	echo "FAIL: target still holds its canary — nothing was installed, so every"
	echo "      preservation check above is vacuous"
	fail=1
else
	echo "ok: target was formatted (canary gone: $target_canary)"
fi

# ── Did it deploy something bootable-shaped? ────────────────────────────────
echo
echo "==> Deployment on the target"
mkdir -p "$WORK/mnt-target"
if mount -o ro "$TARGET_DEV" "$WORK/mnt-target" 2>/dev/null; then
	for p in ostree boot; do
		if [ -e "$WORK/mnt-target/$p" ]; then
			echo "ok: /$p present on the target"
		else
			echo "FAIL: /$p missing on the target — no bootc deployment landed"
			fail=1
		fi
	done
	# A deployment carrying actual content, not just the directory skeleton.
	#
	# Deliberately layout-agnostic. The obvious check — a `deploy` directory
	# under ostree/deploy/<stateroot>/ — is the CLASSIC ostree layout, and this
	# install path is composefs-native, which does not use it. Asserting the
	# classic shape reported "no populated ostree deployment" against a
	# bonito:gnome-asahi install that had in fact succeeded (agent exit 0, boot
	# entries written). Pinning a test to one backend's on-disk layout makes it
	# fail on the backend we actually ship.
	#
	# So: require real bytes deployed, by either layout. `|| true` on each is
	# load-bearing under `set -euo pipefail` — find and du exit non-zero on a
	# missing path, and a bare command substitution assignment adopts that
	# status, which silently killed the script here once already.
	objects=$(find "$WORK/mnt-target/ostree" -mindepth 1 -maxdepth 4 \
		\( -name "*.commit" -o -name "*.composefs" -o -name "*.dirtree" \) 2>/dev/null | head -1 || true)
	deploy_kb=$(du -sk "$WORK/mnt-target/ostree" 2>/dev/null | cut -f1 || echo 0)
	if [ -n "$objects" ] || [ "${deploy_kb:-0}" -gt 102400 ]; then
		echo "ok: ostree tree holds a real deployment (${deploy_kb} KB)"
	else
		echo "FAIL: /ostree exists but holds no deployment (${deploy_kb} KB, no objects found)"
		echo "      ---- layout under /ostree ----"
		find "$WORK/mnt-target/ostree" -maxdepth 3 2>/dev/null | head -30 | sed 's/^/      | /' || true
		fail=1
	fi
	umount "$WORK/mnt-target"
else
	echo "FAIL: target partition is not mountable after the install"
	fail=1
fi

# The ESP should have gained boot entries — otherwise the install deployed a
# root nothing can boot into.
echo
echo "==> Boot entries on the ESP"
if mount -o ro "$ESP_DEV" "$WORK/mnt-esp" 2>/dev/null; then
	if [ -d "$WORK/mnt-esp/EFI" ] || [ -d "$WORK/mnt-esp/loader" ]; then
		echo "ok: ESP carries boot entries (EFI/ or loader/)"
	else
		echo "FAIL: ESP has no EFI/ or loader/ — nothing would boot"
		fail=1
	fi
	umount "$WORK/mnt-esp"
else
	echo "FAIL: ESP is not mountable after the install"
	fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "INSTALL SELFTEST FAILED"
	exit 1
fi
echo "INSTALL SELFTEST PASSED"
