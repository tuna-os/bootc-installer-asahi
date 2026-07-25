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
 {"name":"Bootstrap","type":"Linux","size":"${ROOT_BYTES}B","image":"root.img"},
 {"name":"Root","type":"Linux","size":"12884901888B","expand":true}]}]}
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

# ── installer_data layout contract (issue #19 / ADR 0001) ────────────────────
# The layout rules are the difference between "fisherman formats the target"
# and "fisherman formats the filesystem the agent is running from", so each rule
# gets a negative fixture. These need no loop mounts or root — only the
# installer_data checker — so they run fast and catch producer/verifier drift.
#
# Extract the checker from test-payload.sh rather than duplicating it: a copy
# would let the two versions disagree, which is the failure mode issue #27
# describes (verifier echoing the producer's assumption).
echo "==> installer_data layout contract:"
CHECK="$WORK/check-installer-data.py"
sed -n '/^python3 - "\$DATA" "\$ZIP" <<.EOF.$/,/^EOF$/p' "$HERE/test-payload.sh" |
	sed '1d;$d' >"$CHECK"
[ -s "$CHECK" ] || { echo "SELFTEST FAIL: could not extract the installer_data checker"; exit 1; }

layout_case() { # description expect(pass|fail) partitions-json
	local desc="$1" expect="$2" parts="$3" rc=0
	python3 - "$WORK/case.json" "$parts" <<'PYEOF'
import json, sys
json.dump({"os_list": [{"name": "c", "boot_object": "m1n1.bin",
                        "next_object": "m1n1/boot.bin",
                        "package": "https://example.invalid/selftest-good.zip",
                        "partitions": json.loads(sys.argv[2])}]},
          open(sys.argv[1], "w"))
PYEOF
	python3 "$CHECK" "$WORK/case.json" "$G/selftest-good.zip" >"$WORK/case.out" 2>&1 || rc=$?
	if [ "$expect" = "pass" ] && [ "$rc" -ne 0 ]; then
		echo "  FAIL $desc — expected accept, got reject:"; sed 's/^/    /' "$WORK/case.out"
		return 1
	fi
	if [ "$expect" = "fail" ] && [ "$rc" -eq 0 ]; then
		echo "  FAIL $desc — expected reject, got accept"
		return 1
	fi
	echo "  ok   $desc"
	return 0
}

# Base layout, mutated per case with jq. Deliberately jq rather than bash
# parameter expansion: building JSON by stripping trailing braces off strings is
# unreadable and silently wrong the moment a field order changes.
LAYOUT_BASE=$(cat <<EOF
[{"name":"EFI","type":"EFI","size":"600MB","source":"esp","copy_firmware":true,"copy_installer_data":true},
 {"name":"Bootstrap","type":"Linux","size":"${ROOT_BYTES}B","image":"root.img"},
 {"name":"Root","type":"Linux","size":"12884901888B","expand":true}]
EOF
)
mutate() { jq -c "$1" <<<"$LAYOUT_BASE"; }

layout_fail=0
layout_case "three-partition layout accepted" pass "$LAYOUT_BASE" || layout_fail=1
layout_case "old two-partition layout rejected (issue #19)" fail \
	"$(mutate '[.[0], (.[1] + {expand: true})]')" || layout_fail=1
layout_case "bootstrap that also expands rejected" fail \
	"$(mutate '.[1] += {expand: true}')" || layout_fail=1
layout_case "non-expanding target rejected" fail \
	"$(mutate '.[2] += {expand: false}')" || layout_fail=1
layout_case "target carrying a format rejected (fisherman formats it)" fail \
	"$(mutate '.[2] += {format: "xfs"}')" || layout_fail=1
layout_case "ESP without copy_installer_data rejected (no config channel)" fail \
	"$(mutate '.[0] += {copy_installer_data: false}')" || layout_fail=1
layout_case "two image-bearing partitions rejected" fail \
	"$(mutate '. + [(.[1] + {name: "Bootstrap2"})]')" || layout_fail=1
layout_case "bootstrap size not matching the image rejected" fail \
	"$(mutate '.[1] += {size: "999B"}')" || layout_fail=1

[ "$layout_fail" -eq 0 ] || { echo "SELFTEST FAIL: installer_data layout contract"; exit 1; }

echo "SELFTEST PASS: harness accepts good payloads and rejects bad ones"
