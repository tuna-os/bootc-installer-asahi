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
ROOT_GB="${3:-16}"
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
    for c in usr/share/uboot/apple_m1/u-boot-nodtb.bin usr/lib/u-boot/apple_m1/u-boot-nodtb.bin usr/lib/asahi-boot/u-boot.bin; do
        [ -f "$MNT/$c" ] && UBOOT_BIN="$MNT/$c" && break
    done
    KVER=$(ls "$MNT/usr/lib/modules" | sort -V | tail -1)
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
          "type": "EFI",
          "size": "${ESP_SIZE}",
          "format": "fat",
          "volume_id": "0x54756e61",
          "copy_firmware": true,
          "copy_installer_data": true,
          "source": "esp"
        },
        {
          "name": "Root",
          "type": "Linux",
          "size": "${ROOT_BYTES}B",
          "expand": true,
          "image": "root.img"
        }
      ]
    }
  ]
}
EOF

echo "==> Done:"
ls -la "$OUT/"
