#!/usr/bin/env bash
# install-config.json -> fisherman recipe.json adapter.
#
# This file is sourced by bootsahi-agent.sh. RECIPE_FILE is intentionally an
# injected output path so the adapter has no first-boot lifecycle concerns.

build_recipe() {
    local cfg="$1" root="$2" esp="$3" deploy_ref="$4"
    : "${RECIPE_FILE:?RECIPE_FILE must name the recipe output}"

    jq -n \
        --argjson c "$(cat "$cfg")" \
        --arg root "$root" \
        --arg esp "$esp" \
        --arg deploy "$deploy_ref" \
        '
        {
            customMounts: [
                # Never format the existing ESP: it already holds the Apple
                # firmware and boot chain. Fisherman still mounts an
                # "unformatted" custom mount and records it as the ESP.
                { partition: $esp, target: "/boot/efi", fstype: "unformatted" },
                { partition: $root, target: "/", fstype: $c.filesystem }
            ],
            # Deploy exactly the digest cosign verified, while retaining the
            # mutable targetImgref as the installed-system update source.
            image: $deploy,
            targetImgref: $c.targetImgref,
            imageType: "bootc",
            # The Asahi m1n1 -> U-Boot -> EFI chain requires systemd-boot, and
            # bootc honours that choice only on its composefs deployment path.
            bootloader: "systemd",
            composeFsBackend: true,
            hostname: $c.hostname,
            encryption: ($c.encryption // {type: "none"}),
            user: ($c.user // {}),
            flatpaks: [],
            distroID: "bootsahi"
        }
        ' >"$RECIPE_FILE"
}
