# asahi-bootbin-sync

The missing boot.bin lifecycle piece for **bootc/ostree Asahi systems**
(fedora-asahi-remix-atomic-desktops/images#2): package scriptlets never run on
bootc deploys, so `update-m1n1` is never re-run after `bootc upgrade` and new
DTBs/m1n1/U-Boot silently never reach `<ESP>/m1n1/boot.bin`.

This oneshot unit runs at boot on Apple Silicon machines only (DT compatible
check + `ConditionKernelVersion=asahi`), compares a sha256 stamp of the
deployed m1n1 + U-Boot + Apple DTBs against the stamp recorded on the ESP,
and when stale: backs up `boot.bin`, runs `update-m1n1`, records the stamp.
Failure restores the backup. Stage 1 (Apple-signed) is never touched.

Ship it in every asahi image:
- script → `/usr/libexec/asahi-bootbin-sync`
- unit → `/usr/lib/systemd/system/asahi-bootbin-sync.service` (+ preset enable)

Path candidates cover Fedora/EL (`/usr/lib64/m1n1`), Debian/Ubuntu
(`/usr/lib/m1n1`), and Arch (`/usr/lib/asahi-boot`) layouts.

Intended to be upstreamed to fedora-asahi-remix-atomic-desktops (issue #2) /
bootupd once proven on hardware.
