#!/usr/bin/env bash
# bootsahi-agent — D1 first-boot agent for the "bootsahi" bootstrap image.
#
# Reads install-config.json (written by the Bootsahi macOS app onto the ESP)
# and drives `bootc install to-filesystem` via fisherman — NOT
# `bootc install to-disk`, which is debug/QEMU-only (see D0's make-payload.sh /
# test-payload.sh). By the time this agent runs, the asahi-installer backend
# has already partitioned the disk (stub macOS, ESP, root partition); fisherman
# is handed those pre-made partitions through recipe.json's customMounts, not
# its own disk auto-partition path.
#
# Exit codes are deliberate, not incidental — the bootstrap's greetd session
# branches on them to decide whether to show progress or fall back to the
# interactive fisherman-driven UI (tuna-installer-*, see INSTALLER-FRONTENDS.md):
#   0 = installed successfully (system reboots into the target OS)
#   2 = no install-config.json found; fall through to interactive UI (not an error)
#   1 = install-config.json present but the install failed; log preserved for the UI
set -euo pipefail

AGENT_NAME="bootsahi-agent"
RUN_DIR="${BOOTSAHI_RUN_DIR:-/run/bootsahi}"
LOG_FILE="$RUN_DIR/install.log"
RECIPE_FILE="$RUN_DIR/recipe.json"
FISHERMAN_BIN="${BOOTSAHI_FISHERMAN_BIN:-fisherman}"

# Write to both the log file and stderr WITHOUT a pipeline. The obvious
# `echo ... | tee -a "$LOG_FILE" >&2` puts a pipe on the hot path of every
# log line, and under `set -o pipefail` any tee hiccup kills the whole agent
# — including between "fisherman succeeded" and the credential cleanup
# below, which would leave recipe.json (LUKS passphrase, user password) on
# disk. No pipeline, no pipefail exposure.
log() {
	printf '%s: %s\n' "$AGENT_NAME" "$*" >>"$LOG_FILE" 2>/dev/null || true
	printf '%s: %s\n' "$AGENT_NAME" "$*" >&2
}

find_install_config() {
    # ${BOOTSAHI_CONFIG_PATH} is the test/dev override; production always reads
    # from the ESP, mirroring asahi-bootbin-sync's own ESP-detection candidates.
    #
    # Always returns 0 — "not found" is signalled by empty stdout, not a
    # nonzero exit, because the caller runs under `set -e` and "no config yet"
    # is an expected first-boot state, not a script error.
    if [ -n "${BOOTSAHI_CONFIG_PATH:-}" ]; then
        [ -f "$BOOTSAHI_CONFIG_PATH" ] && echo "$BOOTSAHI_CONFIG_PATH"
        return 0
    fi
    # <ESP>/asahi/ is checked first and is the intended production location:
    # asahi-installer already creates that directory and copies files into it
    # via copy_installer_data/collect_installer_data, AFTER partitioning — so
    # delivering install-config.json needs no new mechanism, just an entry in
    # the backend's copy_idata list. See docs/UNIFIED-INSTALL-CONTRACT.md.
    # <ESP>/bootsahi/ stays supported for hand-placed files and dev/test.
    for c in /boot/efi /efi /boot; do
        for d in asahi bootsahi; do
            if [ -f "$c/$d/install-config.json" ]; then
                echo "$c/$d/install-config.json"
                return 0
            fi
        done
    done
    return 0
}

connect_wifi() {
    local cfg="$1"
    local ssid psk
    ssid=$(jq -r '.wifi.ssid // empty' "$cfg")
    [ -n "$ssid" ] || return 0
    psk=$(jq -r '.wifi.psk // empty' "$cfg")
    log "connecting to Wi-Fi network '$ssid'"
    if [ -n "$psk" ]; then
        nmcli device wifi connect "$ssid" password "$psk" || log "Wi-Fi connect failed; continuing (ethernet may still work)"
    else
        nmcli device wifi connect "$ssid" || log "Wi-Fi connect failed; continuing (ethernet may still work)"
    fi
}

verify_signature() {
    local cfg="$1" imgref="$2"
    local identity issuer
    identity=$(jq -r '.cosignIdentity // empty' "$cfg")
    issuer=$(jq -r '.cosignIssuer // empty' "$cfg")
    [ -n "$identity" ] || return 0

    if [ "${BOOTSAHI_SKIP_VERIFY:-0}" = "1" ]; then
        log "WARNING: BOOTSAHI_SKIP_VERIFY=1 — skipping cosign verification (dev/test only, never set this in production)"
        return 0
    fi
    if ! command -v cosign >/dev/null 2>&1; then
        log "cosignIdentity set but cosign is not installed in the bootstrap image; refusing to deploy an unverified image"
        return 1
    fi
    log "verifying cosign signature for $imgref"
    cosign verify \
        --certificate-identity "$identity" \
        --certificate-oidc-issuer "$issuer" \
        "$imgref" >>"$LOG_FILE" 2>&1
}

# build_recipe translates install-config.json into a fisherman recipe.json.
# customMounts is used (not disk/filesystem auto-partition) because the
# asahi-installer backend has already created espPartition/rootPartition.
build_recipe() {
    local cfg="$1" root="$2" esp="$3"
    jq -n \
        --argjson c "$(cat "$cfg")" \
        --arg root "$root" \
        --arg esp "$esp" \
        '
        {
            customMounts: [
                # The ESP fstype MUST be "unformatted". Two reasons, both load-bearing:
                #
                # 1. "vfat" (what this said before) is not a token fisherman
                #    accepts at all. recipe.Validate() does not check fstype for
                #    customMounts, so it passes validation and then dies inside
                #    disk.formatPartition() — whose switch knows "fat32", not
                #    "vfat" — with `unsupported filesystem: "vfat"`. This recipe
                #    has therefore never been valid; it fails at fisherman step 1.
                #
                # 2. The obvious fix — "fat32" — is the dangerous one. Any token
                #    other than "unformatted"/"" makes ApplyCustomLayout run mkfs
                #    on the partition, and by the time this agent runs, the ESP
                #    already holds m1n1/boot.bin, the bootloader, stub_info.json,
                #    and vendorfw/ — Apple firmware extracted on-device, which we
                #    are not permitted to redistribute and therefore cannot get
                #    back. mkfs.fat on the ESP means a DFU restore.
                #
                # "unformatted" skips only the mkfs; the mount and the efiPart
                # bookkeeping fisherman needs for the boot entry both still happen.
                { partition: $esp, target: "/boot/efi", fstype: "unformatted" },
                { partition: $root, target: "/", fstype: $c.filesystem }
            ],
            image: $c.targetImgref,
            targetImgref: $c.targetImgref,
            imageType: "bootc",
            bootloader: "systemd",
            hostname: $c.hostname,
            encryption: ($c.encryption // {type: "none"}),
            user: ($c.user // {}),
            flatpaks: [],
            distroID: "bootsahi"
        }
        ' >"$RECIPE_FILE"
}

# Authoritative Apple Silicon check, mirroring asahi-bootbin-sync.sh. The unit's
# ConditionPathExists only proves we're on *some* device-tree machine; this
# proves it's Apple. Defence in depth, and the reason it exists in the script
# rather than only the unit: issue #23 was a unit-level predicate that silently
# never matched, which no amount of script correctness would have caught.
# Exits 2 (nothing to do), never 0 — 0 means "installed, go ahead and reboot".
check_apple_hardware() {
    [ "${BOOTSAHI_SKIP_HW_CHECK:-0}" = "1" ] && return 0
    if ! grep -q "apple," /proc/device-tree/compatible 2>/dev/null; then
        log "not Apple Silicon hardware (no 'apple,' in /proc/device-tree/compatible); nothing to do"
        exit 2
    fi
    return 0
}

# fisherman's manual/customMounts path does NOT do LUKS: luksFormat/luksOpen
# happen only in its auto-partition branch, and TPM enrolment needs an
# activeRootPart that manual mode leaves empty. Since this agent always sets
# customMounts, an encrypted install would silently complete UNENCRYPTED while
# the app's UI said otherwise — a security-boundary failure, not a missing
# feature (issue #20). Fail closed BEFORE any disk mutation until fisherman's
# manual path implements encryption.
reject_unsupported_encryption() {
    local cfg="$1" etype
    etype=$(jq -r '.encryption.type // "none"' "$cfg")
    if [ "$etype" != "none" ]; then
        log "encryption.type='$etype' requested, but fisherman's customMounts path does not apply LUKS"
        log "refusing to continue: an install would silently complete UNENCRYPTED (see issue #20)"
        return 1
    fi
    return 0
}

# block_device_id echoes a device's "major:minor" in decimal, or nothing.
# Comparing major:minor rather than paths is deliberate: /dev/nvme0n1p5,
# /dev/disk/by-partuuid/<uuid>, and a symlink chain all name the same device,
# and a path comparison would call them different.
block_device_id() {
    local dev="$1" hex
    hex=$(stat -Lc '%t:%T' "$dev" 2>/dev/null) || return 0
    [ -n "$hex" ] && [ "$hex" != ":" ] || return 0
    printf '%d:%d\n' "0x${hex%%:*}" "0x${hex##*:}" 2>/dev/null || true
}

# active_root_device_id echoes major:minor of whatever backs "/", from
# /proc/self/mountinfo — a plain file read, no findmnt/util-linux dependency,
# and mountinfo reports major:minor directly (field 3).
active_root_device_id() {
    awk '$5 == "/" { print $3; exit }' /proc/self/mountinfo 2>/dev/null || true
}

# refuse_active_root is the guard that makes the current half-finished state
# safe to have in tree. Since ADR 0001 the disk carries TWO Linux partitions —
# the bootstrap this agent is running from, and the target it installs into —
# so a stale or guessed rootPartition now names a plausible-looking Linux
# partition either way. Handing fisherman the bootstrap's own partition means
# mkfs on the filesystem containing PID 1 (issue #19).
#
# Until the runtime PARTUUID resolution in #22 lands, positively refusing the
# one catastrophic value is what stands between "documented as wrong" and
# "destroys the running system".
refuse_active_root() {
    local cfg="$1" root esp root_id esp_id active_id
    root=$(jq -r '.rootPartition // empty' "$cfg")
    esp=$(jq -r '.espPartition // empty' "$cfg")

    if [ -n "$root" ] && [ "$root" = "$esp" ]; then
        log "rootPartition and espPartition are the same device ($root); refusing"
        return 1
    fi

    active_id=$(active_root_device_id)
    if [ -z "$active_id" ]; then
        # Cannot read mountinfo: not a running Linux system (the test harness on
        # macOS, for instance). Nothing destructive can be verified here, and
        # check_apple_hardware has already gated real hardware.
        log "cannot determine the device backing /; skipping active-root check"
        return 0
    fi

    root_id=$(block_device_id "$root")
    if [ -n "$root_id" ] && [ "$root_id" = "$active_id" ]; then
        log "rootPartition ($root) is the device backing / — fisherman would mkfs the"
        log "filesystem this agent is running from. Refusing (see issue #19 / ADR 0001)."
        return 1
    fi
    esp_id=$(block_device_id "$esp")
    if [ -n "$esp_id" ] && [ "$esp_id" = "$active_id" ]; then
        log "espPartition ($esp) is the device backing /; refusing"
        return 1
    fi
    return 0
}

# ── Target resolution by PARTUUID (issue #22) ────────────────────────────────
# The macOS app cannot name the target: it knows the partition as disk0s5 while
# this agent sees nvme0n1p5. And a partition ORDINAL must never be trusted —
# since ADR 0001 there are two Linux partitions, and picking the wrong one means
# mkfs on the filesystem this agent is running from.
#
# So the backend records each partition it created (PARTUUID + declared role)
# into <ESP>/asahi/stub_info.json, and we resolve from that. PARTUUID is stable
# across macOS/Linux and immune to renumbering.
PARTUUID_DIR="${BOOTSAHI_PARTUUID_DIR:-/dev/disk/by-partuuid}"
TARGET_DEV=""
ESP_DEV=""

# find_stub_info echoes the backend's stub_info.json, or nothing. It lives
# beside install-config.json because both arrive through the same
# copy_installer_data channel into <ESP>/asahi/. Always exits 0 — absence is a
# valid dev/test state, and the caller runs under `set -e`.
find_stub_info() {
    local cfg="$1" candidate
    if [ -n "${BOOTSAHI_STUB_INFO_PATH:-}" ]; then
        [ -f "$BOOTSAHI_STUB_INFO_PATH" ] && printf '%s\n' "$BOOTSAHI_STUB_INFO_PATH"
        return 0
    fi
    candidate="$(dirname "$cfg")/stub_info.json"
    [ -f "$candidate" ] && printf '%s\n' "$candidate"
    return 0
}

# parent_disk_of echoes the parent block device name for a partition device,
# via sysfs (/sys/class/block/<part> is a symlink into its parent disk), or
# nothing. Used to prove the target lives on the same disk as our ESP.
parent_disk_of() {
    local dev base parent
    base=$(basename "$(readlink -f "$1" 2>/dev/null)" 2>/dev/null) || return 0
    [ -n "$base" ] || return 0
    parent=$(readlink -f "/sys/class/block/$base" 2>/dev/null) || return 0
    dev=$(basename "$(dirname "$parent")" 2>/dev/null) || return 0
    # A whole disk's sysfs parent is "block", not another device.
    [ "$dev" != "block" ] && printf '%s\n' "$dev"
    return 0
}

# device_is_mounted reports whether a device is mounted anywhere right now.
# Formatting a mounted filesystem is how you destroy a running system, so this
# is a refusal, not a warning.
device_is_mounted() {
    local id
    id=$(block_device_id "$1")
    [ -n "$id" ] || return 1
    awk -v want="$id" '$3 == want { found = 1 } END { exit !found }' \
        /proc/self/mountinfo 2>/dev/null
}

# resolve_role_device maps a declared role ("target"/"esp"/"bootstrap") to a
# block device via its recorded PARTUUID. Refuses on zero or multiple matches
# rather than picking one — an ambiguous identity is not an identity.
resolve_role_device() {
    local stub="$1" role="$2" uuid n dev
    n=$(jq -r --arg r "$role" '[.partitions[]? | select(.role == $r)] | length' "$stub" 2>/dev/null)
    case "$n" in
    1) : ;;
    ""|0) log "stub_info.json records no partition with role '$role'"; return 1 ;;
    *) log "stub_info.json records $n partitions with role '$role'; ambiguous, refusing"; return 1 ;;
    esac
    uuid=$(jq -r --arg r "$role" '.partitions[] | select(.role == $r) | .uuid' "$stub")
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        log "partition with role '$role' has no recorded PARTUUID"
        return 1
    fi
    dev=$(readlink -f "$PARTUUID_DIR/$uuid" 2>/dev/null || true)
    if [ -z "$dev" ] || [ ! -b "$dev" ]; then
        log "PARTUUID $uuid (role '$role') does not resolve to a block device under $PARTUUID_DIR"
        return 1
    fi
    printf '%s\n' "$dev"
    return 0
}

# verify_target verifies a resolved target is safe to hand to a formatter, and
# prints the evidence. #22's requirement: never format anything whose identity
# and ownership have not been positively established.
verify_target() {
    local target="$1" esp="$2" active_id target_id tparent eparent sectors
    target_id=$(block_device_id "$target")
    active_id=$(active_root_device_id)

    if [ -n "$active_id" ] && [ "$target_id" = "$active_id" ]; then
        log "resolved target $target is the device backing /; refusing"
        return 1
    fi
    if device_is_mounted "$target"; then
        log "resolved target $target is currently mounted; refusing to format it"
        return 1
    fi
    tparent=$(parent_disk_of "$target")
    eparent=$(parent_disk_of "$esp")
    if [ -n "$tparent" ] && [ -n "$eparent" ] && [ "$tparent" != "$eparent" ]; then
        log "resolved target $target is on disk '$tparent' but our ESP is on '$eparent'; refusing"
        log "(a target on a different disk means the recorded identities are not from this install)"
        return 1
    fi

    sectors=$(cat "/sys/class/block/$(basename "$target")/size" 2>/dev/null || echo "?")
    log "preflight: target=$target parent=${tparent:-?} dev=$target_id sectors=$sectors mounted=no"
    log "preflight: esp=$esp parent=${eparent:-?} dev=$(block_device_id "$esp")"
    return 0
}

main() {
    # 0700 so the recipe (LUKS passphrase, Wi-Fi PSK) and log are not readable by
    # other local users under a permissive umask; umask 077 covers files created
    # by redirection below, which does not honour any mode argument (issue #21).
    umask 077
    # umask 077 above already makes mkdir create this 0700; the explicit chmod
    # covers the case where RUN_DIR already exists from an earlier boot/run.
    # (No -m on mkdir: with -p it applies only to the deepest directory, which
    # is a subtle enough footgun that shellcheck flags it — SC2174.)
    mkdir -p "$RUN_DIR"
    chmod 0700 "$RUN_DIR" 2>/dev/null || true
    : >"$LOG_FILE"

    # Remove the derived recipe on EVERY exit path, not just the success path.
    # Previously a fisherman failure exited before the cleanup below, leaving a
    # file containing the LUKS passphrase and Wi-Fi PSK on disk while the
    # fallback UI kept running indefinitely (issue #21).
    trap 'shred -u "$RECIPE_FILE" 2>/dev/null || rm -f "$RECIPE_FILE" 2>/dev/null || true' EXIT

    check_apple_hardware

    local cfg
    cfg=$(find_install_config)
    if [ -z "$cfg" ]; then
        log "no install-config.json found; nothing to do (interactive UI takes over)"
        exit 2
    fi
    log "found install-config.json at $cfg"

    if ! jq empty "$cfg" 2>>"$LOG_FILE"; then
        log "install-config.json is not valid JSON"
        exit 1
    fi

    local imgref
    imgref=$(jq -r '.targetImgref // empty' "$cfg")
    for field in targetImgref rootPartition espPartition filesystem hostname; do
        if [ -z "$(jq -r ".$field // empty" "$cfg")" ]; then
            log "install-config.json missing required field: $field"
            exit 1
        fi
    done

    # Before any network use or disk mutation: refuse configs we cannot honour,
    # and refuse the one that would destroy the running system.
    if ! reject_unsupported_encryption "$cfg"; then
        exit 1
    fi
    if ! refuse_active_root "$cfg"; then
        exit 1
    fi

    # Resolve the devices to operate on. Preference order is deliberate:
    #   1. stub_info.json's recorded PARTUUIDs — the only trustworthy source,
    #      written by the backend that created the partitions.
    #   2. install-config.json's rootPartition/espPartition — dev/test override
    #      only, and already screened by refuse_active_root above.
    # There is no third option: if neither yields a device we abort rather than
    # guess, because the failure mode of guessing is an unrecoverable machine.
    local stub
    stub=$(find_stub_info "$cfg")
    if [ -n "$stub" ]; then
        log "resolving install target from $stub (recorded PARTUUIDs)"
        TARGET_DEV=$(resolve_role_device "$stub" target) || exit 1
        ESP_DEV=$(resolve_role_device "$stub" esp) || exit 1
        if ! verify_target "$TARGET_DEV" "$ESP_DEV"; then
            exit 1
        fi
    else
        TARGET_DEV=$(jq -r '.rootPartition // empty' "$cfg")
        ESP_DEV=$(jq -r '.espPartition // empty' "$cfg")
        if [ -z "$TARGET_DEV" ] || [ -z "$ESP_DEV" ]; then
            log "no stub_info.json and no rootPartition/espPartition in the config; cannot identify a target"
            exit 1
        fi
        log "WARNING: no stub_info.json found; falling back to the config's device paths."
        log "WARNING: this is a dev/test path — production installs must resolve by PARTUUID (issue #22)."
    fi

    connect_wifi "$cfg"

    if ! verify_signature "$cfg" "$imgref"; then
        log "signature verification failed for $imgref; aborting install"
        exit 1
    fi

    build_recipe "$cfg" "$TARGET_DEV" "$ESP_DEV"
    log "running fisherman against $imgref"
    if ! "$FISHERMAN_BIN" "$RECIPE_FILE" >>"$LOG_FILE" 2>&1; then
        log "fisherman install failed; see $LOG_FILE"
        exit 1
    fi

    log "install complete"
    # Zero out the recipe (it carries the LUKS passphrase / user password in
    # the clear) before reboot; RUN_DIR is tmpfs so this is belt-and-braces.
    # shred(1) is GNU coreutils and absent on macOS/BSD — the `|| rm -f`
    # fallback covers that, and the trailing `|| true` guarantees a failure
    # here can never abort the agent before the file is gone. Removal is
    # what actually matters; overwriting is the bonus when shred exists.
    shred -u "$RECIPE_FILE" 2>/dev/null || rm -f "$RECIPE_FILE" || true

    # Same reasoning, one layer up and worse: install-config.json can carry a
    # LUKS passphrase and a Wi-Fi PSK, and unlike RUN_DIR the ESP is NOT tmpfs.
    # It's vfat — no permission bits, world-readable by anything that can read
    # the filesystem — and it stays mounted on the installed system forever.
    # Leaving it there would publish the disk-encryption passphrase to every
    # local user on the machine we just encrypted.
    #
    # Only after a successful install: on failure the interactive fisherman UI
    # wants it. shred is best-effort here and largely theatre on vfat over
    # wear-levelled flash — removal is the part that matters.
    log "removing install-config.json (carries LUKS passphrase / Wi-Fi PSK; the ESP is world-readable and persists)"
    shred -u "$cfg" 2>/dev/null || rm -f "$cfg" || true

    if [ "${BOOTSAHI_NO_REBOOT:-0}" != "1" ]; then
        log "rebooting into the installed system"
        systemctl reboot
    fi
}

main "$@"
