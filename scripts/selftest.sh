#!/usr/bin/env bash
# selftest.sh — prove the payload test harness detects what it claims to.
#
# Builds two synthetic payloads:
#   good/ — structurally complete (fake but shaped like a real payload)
#   bad/  — missing boot.bin DTBs, no asahi kernel, broken installer_data
# and asserts test-payload.sh passes the first and fails the second.
# Runs on every PR; needs root (loop mounts) but no real image and no qemu.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

make_root_img() { # dir-with-content -> img path
	local content="$1" img="$2"
	truncate -s 64M "$img"
	mkfs.ext4 -q "$img"
	mkdir -p "$WORK/mnt"
	mount -o loop "$img" "$WORK/mnt"
	cp -a "$content/." "$WORK/mnt/"
	umount "$WORK/mnt"
}

echo "==> Building synthetic GOOD payload..."
G="$WORK/good"
KVER="7.0.13-400.asahi.selftest.aarch64+16k"
mkdir -p "$G/esp/m1n1" "$G/esp/EFI/BOOT" "$G/esp/loader/entries" \
	"$G/rootfs/usr/lib/modules/$KVER/dtb/apple" \
	"$G/rootfs/usr/lib/dracut/modules.d/99asahi-firmware" \
	"$G/rootfs/usr/bin"
# boot.bin: fake m1n1 + 60 DTB magics + a real gzip stream
{
	head -c 2097152 /dev/zero
	for _ in $(seq 60); do printf '\xd0\x0d\xfe\xed'; head -c 512 /dev/zero; done
	echo "u-boot" | gzip -c
} > "$G/esp/m1n1/boot.bin"
echo stub > "$G/esp/EFI/BOOT/BOOTAA64.EFI"
printf 'title selftest\nlinux /vmlinuz\n' > "$G/esp/loader/entries/selftest.conf"
touch "$G/rootfs/usr/lib/modules/$KVER/vmlinuz" "$G/rootfs/usr/lib/modules/$KVER/initramfs.img"
for i in $(seq 55); do touch "$G/rootfs/usr/lib/modules/$KVER/dtb/apple/t8103-j$i.dtb"; done
for mod in asahi.ko appledrm.ko nvme-apple.ko hci_bcm4377.ko spi-hid-apple.ko; do
	echo "kernel/drivers/fake/${mod}: kernel/dep.ko" >> "$G/rootfs/usr/lib/modules/$KVER/modules.dep"
done
touch "$G/rootfs/usr/bin/update-m1n1" "$G/rootfs/usr/bin/speakersafetyd"
chmod +x "$G/rootfs/usr/bin/update-m1n1" "$G/rootfs/usr/bin/speakersafetyd"
make_root_img "$G/rootfs" "$G/root.img"
(cd "$G" && mkdir -p pkg && cp -a esp pkg/ && cp root.img pkg/ && cd pkg && zip -r9 -q ../selftest-good.zip esp root.img)
ROOT_BYTES=$(stat -c%s "$G/root.img")
cat > "$G/installer_data.json" <<EOF
{"os_list":[{"name":"selftest","default_os_name":"selftest",
"boot_object":"m1n1.bin","next_object":"m1n1/boot.bin",
"package":"https://example.invalid/selftest-good.zip",
"partitions":[
 {"name":"EFI","type":"EFI","size":"600MB","format":"fat","volume_id":"0x1","copy_firmware":true,"copy_installer_data":true,"source":"esp"},
 {"name":"Root","type":"Linux","size":"${ROOT_BYTES}B","expand":true,"image":"root.img"}]}]}
EOF

echo "==> Building synthetic BAD payload..."
B="$WORK/bad"
mkdir -p "$B/esp/m1n1" "$B/rootfs/usr/lib/modules/6.1.0-generic/"
head -c 1024 /dev/zero > "$B/esp/m1n1/boot.bin" # no DTBs, no gzip, tiny
touch "$B/rootfs/usr/lib/modules/6.1.0-generic/vmlinuz"
make_root_img "$B/rootfs" "$B/root.img"
(cd "$B" && zip -r9 -q selftest-bad.zip esp root.img)
echo '{"os_list":[{"name":"bad","partitions":[]}]}' > "$B/installer_data.json"

echo "==> GOOD payload must PASS:"
"$HERE/test-payload.sh" "$G/selftest-good.zip" "$G/installer_data.json" ||
	{ echo "SELFTEST FAIL: good payload was rejected"; exit 1; }

echo "==> BAD payload must FAIL:"
if "$HERE/test-payload.sh" "$B/selftest-bad.zip" "$B/installer_data.json"; then
	echo "SELFTEST FAIL: bad payload was accepted"; exit 1
fi

echo "SELFTEST PASS: harness accepts good payloads and rejects bad ones"
