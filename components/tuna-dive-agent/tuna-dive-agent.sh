#!/usr/bin/env bash
# tuna-dive-agent — D1 first-boot agent for the "tuna-dive" bootstrap image.
#
# Reads install-config.json (written by the Tuna Dive macOS app onto the ESP)
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

AGENT_NAME="tuna-dive-agent"
RUN_DIR="${TUNA_DIVE_RUN_DIR:-/run/tuna-dive}"
LOG_FILE="$RUN_DIR/install.log"
RECIPE_FILE="$RUN_DIR/recipe.json"
FISHERMAN_BIN="${TUNA_DIVE_FISHERMAN_BIN:-fisherman}"

log() { echo "$AGENT_NAME: $*" | tee -a "$LOG_FILE" >&2; }

find_install_config() {
    # ${TUNA_DIVE_CONFIG_PATH} is the test/dev override; production always reads
    # from the ESP, mirroring asahi-bootbin-sync's own ESP-detection candidates.
    #
    # Always returns 0 — "not found" is signalled by empty stdout, not a
    # nonzero exit, because the caller runs under `set -e` and "no config yet"
    # is an expected first-boot state, not a script error.
    if [ -n "${TUNA_DIVE_CONFIG_PATH:-}" ]; then
        [ -f "$TUNA_DIVE_CONFIG_PATH" ] && echo "$TUNA_DIVE_CONFIG_PATH"
        return 0
    fi
    for c in /boot/efi /efi /boot; do
        if [ -f "$c/tuna-dive/install-config.json" ]; then
            echo "$c/tuna-dive/install-config.json"
            return 0
        fi
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

    if [ "${TUNA_DIVE_SKIP_VERIFY:-0}" = "1" ]; then
        log "WARNING: TUNA_DIVE_SKIP_VERIFY=1 — skipping cosign verification (dev/test only, never set this in production)"
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
                { partition: $c.espPartition, target: "/boot/efi", fstype: "vfat" },
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
            distroID: "tuna-dive"
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
    shred -u "$RECIPE_FILE" 2>/dev/null || rm -f "$RECIPE_FILE"

    if [ "${TUNA_DIVE_NO_REBOOT:-0}" != "1" ]; then
        log "rebooting into the installed system"
        systemctl reboot
    fi
}

main "$@"
