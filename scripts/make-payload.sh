#!/usr/bin/env bash
# make-payload.sh — package a bootc aarch64 image as an asahi-installer payload.
#
# Produces the artifact set the asahi-installer consumes (layout modeled on
# fedora-asahi kiwi-descriptions' make-asahi-installer-package.sh and
# quinneden/nixos-asahi-package):
#
#   out/<name>.zip           — esp/ tree (incl. m1n1/boot.bin) + root.img
#   out/installer_data.json  — os_list entry pointing at the zip
#
# The payload here is the *bootstrap* strategy from docs/DESIGN.md: the root
# image is a minimal asahi-capable system whose first boot runs fisherman to
# `bootc install` the user's chosen TunaOS/Bluefin/Dakota image ref. One
# payload serves every variant; the catalog is just image refs.
#
# Usage:
#   make-payload.sh <bootc-image-ref> <payload-name> [root-size-gb]
#
# Requirements: run as root on an aarch64 host (CI: ubuntu-24.04-arm),
# with podman. bootc install runs containerized from the target image.
set -euo pipefail

IMAGE="${1:?usage: make-payload.sh <bootc-image-ref> <payload-name> [root-size-gb]}"
NAME="${2:?usage: make-payload.sh <bootc-image-ref> <payload-name> [root-size-gb]}"
# Size of the loopback disk the bootstrap image is installed into, and therefore
# of the fixed-size Bootstrap partition. This is NOT the installed system's disk
# — that is the expanding "Root" partition, sized by TARGET_MIN_GB + user slack.
#
# The default stays 24 because the image we currently feed this is a full GNOME
# desktop image, not a bootstrap (issue #27: nothing in this pipeline builds an
# image containing bootsahi-agent yet). A real minimal bootstrap wants ~2-4 GB,
# and this default should drop with it — but lowering it before that image
# exists just buys an ENOSPC 40 minutes into an aarch64 build.
#
# Whatever this is, it becomes dead space on the installed machine until the
# bootstrap partition is reclaimed (ADR 0001, follow-up).
ROOT_GB="${3:-24}"
OUT="${OUT_DIR:-out}"
BASE_URL="${BASE_URL:-https://download.tunaos.org/asahi}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

echo "==> Installing ${IMAGE} to a loopback disk (bootc install to-disk)..."
truncate -s "${ROOT_GB}G" "$WORK/disk.img"
podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$WORK":/work \
    "$IMAGE" \
    bootc install to-disk --generic-image --skip-fetch-check \
    --filesystem xfs --via-loopback /work/disk.img

echo "==> Splitting ESP tree and root image out of the disk..."
LOOP=$(losetup --find --show -P "$WORK/disk.img")
cleanup_loop() { losetup -d "$LOOP" 2>/dev/null || true; }
trap 'cleanup_loop; rm -rf "$WORK"' EXIT

# Partition layout from bootc install to-disk: p1 reserved/bios, ESP, root —
# find them by filesystem type rather than assuming numbers.
ESP_PART=""
ROOT_PART=""
for part in "$LOOP"p*; do
    fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    case "$fstype" in
    vfat) ESP_PART="$part" ;;
    xfs | ext4 | btrfs) ROOT_PART="$part" ;;
    esac
done
[ -n "$ESP_PART" ] || { echo "ERROR: no ESP (vfat) partition found" >&2; exit 1; }
[ -n "$ROOT_PART" ] || { echo "ERROR: no root partition found" >&2; exit 1; }

mkdir -p "$WORK/esp"
mount -o ro "$ESP_PART" "$WORK/mnt-esp" --mkdir
cp -a "$WORK/mnt-esp/." "$WORK/esp/"
umount "$WORK/mnt-esp"

# The asahi-installer expects m1n1/boot.bin inside the ESP tree. On a real
# install update-m1n1 regenerates it; the payload must ship an initial one.
if [ ! -f "$WORK/esp/m1n1/boot.bin" ]; then
    echo "==> ESP has no m1n1/boot.bin — harvesting boot components from the image..."
    mkdir -p "$WORK/esp/m1n1"
    CTR=$(podman create "$IMAGE" true)
    trap 'podman rm -f "$CTR" >/dev/null 2>&1 || true; cleanup_loop; rm -rf "$WORK"' EXIT
    MNT=$(podman mount "$CTR")
    # m1n1 + DTBs + gzipped u-boot, concatenated — same recipe as update-m1n1.
    M1N1_BIN=""
    for c in usr/lib64/m1n1/m1n1.bin usr/lib/m1n1/m1n1.bin usr/lib/asahi-boot/m1n1.bin; do
        [ -f "$MNT/$c" ] && M1N1_BIN="$MNT/$c" && break
    done
    UBOOT_BIN=""
    for c in usr/share/uboot/apple_m1/u-boot-nodtb.bin usr/lib/u-boot-asahi/u-boot-nodtb.bin usr/lib/u-boot/apple_m1/u-boot-nodtb.bin usr/lib/asahi-boot/u-boot-nodtb.bin usr/lib/asahi-boot/u-boot.bin; do
        [ -f "$MNT/$c" ] && UBOOT_BIN="$MNT/$c" && break
    done
    KVER=$(for kd in "$MNT/usr/lib/modules"/*; do [ -d "$kd/dtb/apple" ] && basename "$kd"; done | sort -V | tail -1)
    [ -n "$KVER" ] || { echo "ERROR: no Asahi kernel found (no dtb/apple/ in any /usr/lib/modules/*)" >&2; exit 1; }
    echo "==> Selected Asahi kernel: $KVER"
    DTBS=$(find "$MNT/usr/lib/modules/$KVER/dtb/apple" -name '*.dtb' 2>/dev/null | sort)
    [ -n "$M1N1_BIN" ] && [ -n "$UBOOT_BIN" ] && [ -n "$DTBS" ] || {
        echo "ERROR: image lacks m1n1/u-boot/DTBs — not an asahi-capable image?" >&2
        exit 1
    }
    { cat "$M1N1_BIN"; cat $DTBS; gzip -c "$UBOOT_BIN"; } > "$WORK/esp/m1n1/boot.bin"
    podman umount "$CTR" >/dev/null
    podman rm -f "$CTR" >/dev/null
fi

echo "==> Extracting root partition image..."
ROOT_BYTES=$(blockdev --getsize64 "$ROOT_PART")
dd if="$ROOT_PART" of="$WORK/root.img" bs=8M status=progress
cleanup_loop

# ── Three partitions, per docs/adr/0001-bootstrap-partition-layout.md ────────
# The bootstrap must NOT boot from the partition fisherman is going to format:
# disk.ApplyCustomLayout() runs mkfs on the mount it installs "/" onto, and you
# cannot mkfs the filesystem containing PID 1. Previously there was one Linux
# partition (Root, expand:true) serving as both, which could never have worked
# (issue #19).
#
# So: "Bootstrap" is fixed-size and carries root.img; "Root" is a bare
# %noformat% partition that absorbs the remaining space and is what the
# first-boot agent installs into. asahi-installer needs no changes for this —
# osinstall.py's partition_disk() iterates the template generically, and a
# partition with neither "format" nor "image" is created and left untouched.
#
# TARGET_MIN_BYTES is the floor before "expand" adds the user's chosen slack.
# It has to be big enough for the pulled image plus podman's working storage:
# fisherman redirects podman's graphroot onto the target disk precisely because
# the VFS driver's byte-for-byte layer copy OOM-kills small-memory machines
# (internal/install/bootc.go). Undersizing this trades an OOM for an ENOSPC.
TARGET_MIN_GB="${TARGET_MIN_GB:-12}"
TARGET_MIN_BYTES=$((TARGET_MIN_GB * 1024 * 1024 * 1024))

ESP_BYTES=$(du -sb "$WORK/esp" | cut -f1)
# ESP partition needs headroom for vendor firmware the installer copies in.
ESP_SIZE=$(( (ESP_BYTES / 1048576 + 500) ))MB

echo "==> Zipping payload..."
(cd "$WORK" && zip -r9 -q "$OLDPWD/$OUT/${NAME}.zip" esp root.img)

echo "==> Writing installer_data.json..."
cat > "$OUT/installer_data.json" <<EOF
{
  "os_list": [
    {
      "name": "${INSTALLER_TITLE:-TunaOS (fisherman bootstrap)}",
      "default_os_name": "${INSTALLER_OS_NAME:-TunaOS}",
      "boot_object": "m1n1.bin",
      "next_object": "m1n1/boot.bin",
      "package": "${BASE_URL}/${NAME}.zip",
      "supported_fw": ["12.3", "12.3.1", "13.5"],
      "partitions": [
        {
          "name": "EFI",
          "role": "esp",
          "type": "EFI",
          "size": "${ESP_SIZE}",
          "format": "fat",
          "volume_id": "0x54756e61",
          "copy_firmware": true,
          "copy_installer_data": true,
          "source": "esp"
        },
        {
          "name": "Bootstrap",
          "role": "bootstrap",
          "type": "Linux",
          "size": "${ROOT_BYTES}B",
          "image": "root.img"
        },
        {
          "name": "Root",
          "role": "target",
          "type": "Linux",
          "size": "${TARGET_MIN_BYTES}B",
          "expand": true
        }
      ]
    }
  ]
}
EOF

echo "==> Done:"
ls -la "$OUT/"
