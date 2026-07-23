#!/usr/bin/env bash
# test-boot-payload.sh — boot-test what the asahi-installer would lay down.
#
# Reconstructs a disk EXACTLY the way the installer partitions a Mac (GPT with
# an ESP populated from the payload's esp/ tree + the root image), then boots
# it under qemu with U-Boot as firmware — the same U-Boot EFI implementation
# (BOOTAA64 fallback scan, devicetree handoff, no persistent EFI variables) an
# Asahi Mac runs after m1n1. This is the deepest install-path fidelity CI can
# reach without Apple hardware; only m1n1 itself and Apple device drivers are
# out of scope.
#
# Usage: test-boot-payload.sh <payload.zip> [timeout-seconds]
# Needs root + qemu-system-aarch64 + u-boot-qemu.
set -euo pipefail

ZIP="${1:?usage: test-boot-payload.sh <payload.zip> [timeout-seconds]}"
BOOT_TIMEOUT="${2:-2400}"
UBOOT_BIN="${UBOOT_BIN:-/usr/lib/u-boot/qemu_arm64/u-boot.bin}"

WORK=$(mktemp -d)
LOOP=""
cleanup() {
	umount "$WORK/esp-mnt" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Reconstructing the installed-disk layout from the payload..."
unzip -q "$ZIP" -d "$WORK/payload"
ROOT_BYTES=$(stat -c%s "$WORK/payload/root.img")
ESP_MB=600
DISK_BYTES=$(( ROOT_BYTES + ESP_MB * 1048576 + 64 * 1048576 ))
truncate -s "$DISK_BYTES" "$WORK/disk.img"

parted -s "$WORK/disk.img" mklabel gpt \
	mkpart ESP fat32 1MiB "$((ESP_MB + 1))MiB" \
	set 1 esp on \
	mkpart root "$((ESP_MB + 1))MiB" 100%

LOOP=$(losetup --find --show -P "$WORK/disk.img")
mkfs.vfat -F 32 -n EFI "${LOOP}p1" >/dev/null
mkdir -p "$WORK/esp-mnt"
mount "${LOOP}p1" "$WORK/esp-mnt"
cp -a "$WORK/payload/esp/." "$WORK/esp-mnt/"
umount "$WORK/esp-mnt"
dd if="$WORK/payload/root.img" of="${LOOP}p2" bs=8M status=none conv=sparse
losetup -d "$LOOP"; LOOP=""

echo "==> Booting under U-Boot EFI (TCG unless /dev/kvm exists)..."
ACCEL=tcg; CPU=neoverse-n1
[ -e /dev/kvm ] && { ACCEL=kvm; CPU=host; }
timeout "$BOOT_TIMEOUT" qemu-system-aarch64 \
	-M virt -accel "$ACCEL" -cpu "$CPU" -smp 4 -m 6144 \
	-bios "$UBOOT_BIN" \
	-drive file="$WORK/disk.img",format=raw,if=none,id=hd0 \
	-device virtio-blk-pci,drive=hd0,romfile= \
	-nographic -serial mon:stdio \
	2>&1 | tee serial-payload-boot.log | tail -c 2000000 || true

echo "=== verdict ==="
if grep -qE "multi-user\.target|Reached target.*Multi-User|login:" serial-payload-boot.log; then
	echo "PASS: reconstructed install boots to userspace over the U-Boot EFI chain"
	exit 0
elif grep -qE "EFI stub|Linux version|Booting" serial-payload-boot.log; then
	echo "PARTIAL: kernel started but no userspace marker — see serial-payload-boot.log"
	exit 1
else
	echo "FAIL: the U-Boot EFI chain never started a kernel — see serial-payload-boot.log"
	exit 1
fi
