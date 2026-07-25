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
    local cfg="$1"
    jq -n \
        --argjson c "$(cat "$cfg")" \
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
                { partition: $c.espPartition, target: "/boot/efi", fstype: "unformatted" },
                { partition: $c.rootPartition, target: "/", fstype: $c.filesystem }
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

main() {
    mkdir -p "$RUN_DIR"
    : >"$LOG_FILE"

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

    connect_wifi "$cfg"

    if ! verify_signature "$cfg" "$imgref"; then
        log "signature verification failed for $imgref; aborting install"
        exit 1
    fi

    build_recipe "$cfg"
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
