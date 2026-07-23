#!/usr/bin/env bash
# test-payload.sh — thorough static verification of an asahi-installer payload.
#
# Validates the three contracts a payload must honor:
#   1. Zip layout the asahi-installer extracts (esp/ tree + root.img)
#   2. Boot chain artifacts inside the ESP (m1n1/boot.bin structure: m1n1 +
#      >=50 Apple DTBs + gzipped U-Boot; EFI fallback path present)
#   3. The root filesystem is actually an asahi-capable OS (16K asahi kernel,
#      hardware modules, dracut firmware flow, boot payload sources, audio)
#   4. installer_data.json consistency with the zip it describes
#
# Usage: test-payload.sh <payload.zip> <installer_data.json>
# Needs root (loop-mounts root.img read-only).
set -euo pipefail

ZIP="${1:?usage: test-payload.sh <payload.zip> <installer_data.json>}"
DATA="${2:?usage: test-payload.sh <payload.zip> <installer_data.json>}"

pass=0 fail=0
ok() { echo "  ok   $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

WORK=$(mktemp -d)
cleanup() {
	umount "$WORK/root" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1. zip layout =="
unzip -q "$ZIP" -d "$WORK/payload"
[ -d "$WORK/payload/esp" ] && ok "esp/ tree present" || bad "esp/ missing"
[ -f "$WORK/payload/root.img" ] && ok "root.img present" || bad "root.img missing"

echo "== 2. ESP boot chain =="
ESP="$WORK/payload/esp"
[ -f "$ESP/m1n1/boot.bin" ] && ok "m1n1/boot.bin" || bad "m1n1/boot.bin missing"
[ -f "$ESP/EFI/BOOT/BOOTAA64.EFI" ] && ok "EFI/BOOT/BOOTAA64.EFI (U-Boot fallback path)" \
	|| bad "EFI/BOOT/BOOTAA64.EFI missing — U-Boot's bootmgr fallback will find nothing"
ls "$ESP"/loader/entries/*.conf >/dev/null 2>&1 && ok "BLS loader entries" \
	|| ls "$ESP"/EFI/*/grub.cfg >/dev/null 2>&1 && ok "grub config" \
	|| bad "no BLS entries and no grub.cfg on ESP"

# boot.bin structure: count devicetree magics (d0 0d fe ed) and check for a
# gzip stream (1f 8b) after them — the update-m1n1 concatenation contract.
python3 - "$ESP/m1n1/boot.bin" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
dtbs = data.count(b"\xd0\x0d\xfe\xed")
gz = data.rfind(b"\x1f\x8b")
size_mb = len(data) / 1048576
problems = []
if dtbs < 50:
    problems.append(f"only {dtbs} DTB magics (expect >=50 Apple devicetrees)")
if gz < 0:
    problems.append("no gzip stream (U-Boot) found")
if size_mb < 2:
    problems.append(f"suspiciously small ({size_mb:.1f} MB)")
if problems:
    print("  FAIL boot.bin structure: " + "; ".join(problems)); sys.exit(1)
print(f"  ok   boot.bin structure ({dtbs} DTBs, gzip@+{gz}, {size_mb:.1f} MB)")
EOF
case $? in 0) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac

echo "== 3. root filesystem is asahi-capable =="
mkdir -p "$WORK/root"
mount -o ro,loop "$WORK/payload/root.img" "$WORK/root"
R="$WORK/root"
# bootc roots put the OS under a deployment; tolerate both plain and ostree layouts
OSROOT="$R"
if [ ! -d "$R/usr/lib/modules" ]; then
	dep=$(find "$R/ostree/deploy" -maxdepth 4 -type d -name "*.0" 2>/dev/null | head -1)
	[ -n "$dep" ] && OSROOT="$dep"
fi
if [ -d "$OSROOT/usr/lib/modules" ]; then
	KVER=$(ls "$OSROOT/usr/lib/modules" | sort -V | tail -1)
	case "$KVER" in
	*asahi* | *16k*) ok "asahi/16k kernel: $KVER" ;;
	*) bad "kernel is not asahi/16k: $KVER" ;;
	esac
	M="$OSROOT/usr/lib/modules/$KVER"
	[ -f "$M/vmlinuz" ] && ok "vmlinuz staged" || bad "vmlinuz missing"
	[ -f "$M/initramfs.img" ] && ok "initramfs present" || bad "initramfs missing"
	[ "$(ls "$M/dtb/apple/" 2>/dev/null | wc -l)" -ge 50 ] && ok "Apple DTBs in modules dir" || bad "Apple DTBs missing"
	for mod in asahi.ko appledrm.ko nvme-apple.ko hci_bcm4377.ko spi-hid-apple.ko; do
		grep -qE "/${mod}(\.xz|\.zst|\.gz)?:" "$M/modules.dep" 2>/dev/null &&
			ok "module $mod" || bad "module $mod missing"
	done
	[ -x "$OSROOT/usr/bin/update-m1n1" ] && ok "update-m1n1" || bad "update-m1n1 missing"
	ls -d "$OSROOT"/usr/lib/dracut/modules.d/99asahi-firmware >/dev/null 2>&1 &&
		ok "dracut asahi-firmware module" || bad "dracut asahi-firmware module missing"
	[ -x "$OSROOT/usr/bin/speakersafetyd" ] && ok "speakersafetyd" || bad "speakersafetyd missing (speakers stay disabled)"
else
	bad "no /usr/lib/modules found in root.img (unrecognized layout)"
fi
umount "$WORK/root"

echo "== 4. installer_data.json consistency =="
python3 - "$DATA" "$ZIP" <<'EOF'
import json, os, sys, zipfile
data = json.load(open(sys.argv[1]))
zpath = sys.argv[2]
z = zipfile.ZipFile(zpath)
names = set(z.namelist())
failures = []
oses = data.get("os_list", [])
if not oses:
    failures.append("os_list empty")
for os_entry in oses:
    for key in ("name", "boot_object", "next_object", "package", "partitions"):
        if key not in os_entry:
            failures.append(f"missing key: {key}")
    if os_entry.get("boot_object") != "m1n1.bin":
        failures.append(f"boot_object should be m1n1.bin, got {os_entry.get('boot_object')}")
    if os_entry.get("next_object") != "m1n1/boot.bin":
        failures.append(f"next_object should be m1n1/boot.bin, got {os_entry.get('next_object')}")
    if os.path.basename(os_entry.get("package", "")) != os.path.basename(zpath):
        failures.append("package URL basename does not match the zip filename")
    parts = os_entry.get("partitions", [])
    esp = [p for p in parts if p.get("type") == "EFI"]
    root = [p for p in parts if p.get("type") == "Linux"]
    if not esp or not esp[0].get("copy_firmware") or esp[0].get("source") != "esp":
        failures.append("EFI partition must have source=esp and copy_firmware=true")
    if not root or not root[0].get("expand"):
        failures.append("root partition should be expandable")
    if root and root[0].get("image") not in names:
        failures.append(f"root image {root[0].get('image')} not inside the zip")
    if root and root[0].get("image"):
        declared = root[0].get("size", "0B")
        actual = z.getinfo(root[0]["image"]).file_size
        if declared != f"{actual}B":
            failures.append(f"root size {declared} != actual image size {actual}B")
if failures:
    for f in failures:
        print(f"  FAIL installer_data: {f}")
    sys.exit(1)
print(f"  ok   installer_data.json consistent with {os.path.basename(zpath)}")
EOF
case $? in 0) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
