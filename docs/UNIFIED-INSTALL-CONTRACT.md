# Unified install contract — draft spec (responds to issue #6 §1)

Status: **first draft, not agreed**. Written to make issue #6's proposal
concrete enough to react to, not to settle it. Corrects one oversimplification
in the RFC text along the way (see "What wootc actually does" below).

## What wootc actually does

The RFC describes wootc's contract as a single `vault.json` matching
`install-config.json`'s shape. In the real code
(`app/vault_windows.go`, `app/installer_windows.go`) it's split across
**three channels**, not one file:

1. **`vault.json`** (`0o600`, ACL-restricted to SYSTEM/Administrators) —
   only `username`, `hostname`, `image`, `password_hash`. The password is
   hashed with `sha512_crypt` (`$6$...`) **before** the file ever touches
   disk; plaintext never lands anywhere.
2. **Bootloader-entry kernel cmdline args** — `wootc.image=`,
   `wootc.hostname=` (duplicated from vault.json — readable before NTFS is
   even mounted), `wootc.bootloader=`, `wootc.luks=<encryption-type>`.
3. **fisherman's `recipe.json`**, assembled by the deployer script from (1)
   and (2) at runtime, not written by the Windows app directly.

This split exists because of a real Windows constraint: the deployer
initramfs needs some config (image ref, LUKS type) available from
`/proc/cmdline` *before* it has mounted anything, while richer config
(username, password hash) can wait until the NTFS volume holding
`vault.json` is mounted.

## Why Asahi doesn't need the split

`install-config.json` already lives on the ESP (per `DESIGN.md`), and the
tuna-dive bootstrap mounts the ESP as one of its first actions regardless
(it needs `<ESP>/m1n1/boot.bin` and the bootstrap root itself lives there
too) — there's no "before any mount" phase analogous to wootc's Windows
cmdline trick where a single JSON file doesn't already work. **Recommend
keeping Asahi's contract as the single-file `install-config.json`** already
specified in `components/tuna-dive-agent/install-config.schema.json` —
simpler, and wootc's split is solving a problem Asahi doesn't have, not a
pattern worth importing for its own sake.

## What to actually converge on

Not the file split — the **field shapes and security conventions**, since
fisherman's `recipe.json` is the true shared contract underneath both:

| Concern | wootc | Asahi (current) | Converge? |
|---|---|---|---|
| Password | `$6$` hash, hashed client-side, `password_hash` field | plaintext `password` field | **Yes** — see below |
| Image ref | `image` | `targetImgref` | No — Asahi's name is clearer (wootc's `image` is also the *current* value in other structs); not worth a rename fight |
| LUKS type | `Encryption` string (`none`/`tpm2-luks`/...) on `InstallConfig`, forwarded as `wootc.luks=` cmdline | `encryption.type` object | Already aligned in spirit; Asahi's object form is finer-grained (carries `passphrase` alongside `type`) and should stay |
| Hostname | `hostname` | `hostname` | Already aligned |

**Concrete action taken in this PR:** `install-config.schema.json`'s
`user.password` field now documents the `$6$`-hash convention explicitly
(fisherman's `chpasswd` step — `projectbluefin/fisherman` only, see below —
already auto-detects a `$`-prefixed value and passes `chpasswd -e`; a plain
string is also accepted but means the password sat in the file in the clear
until install completed). The macOS app should hash client-side the same
way `vault_windows.go` does, before `install-config.json` is ever written to
the ESP.

## A real, non-hypothetical blocker found while writing this

`components/tuna-dive-agent` was built against `github.com/tuna-os/fisherman`.
wootc actually vendors `github.com/projectbluefin/fisherman`, which is **six
days ahead** (as of this writing) and has two fixes `tuna-os/fisherman`
lacks entirely:

- **`MountType`** — an explicit `mount -t <fstype>` for the freshly-formatted
  root. Without it, the deployer initramfs (no libblkid probe path) can
  attempt an xfs root as ext4 and fail outright. The Asahi dracut/initramfs
  likely has the same no-probe property (unverified — needs an aarch64
  re-check, tracked in the hardware testing checklist).
- **`chroot <target> useradd`** instead of **`useradd --root <target>`** —
  `--root` also initializes the *host's* PAM/SELinux stack and fails against
  a target whose `/etc` is otherwise perfectly writable (proven on
  bluefin:lts per wootc's fisherman fork commit history).

`tuna-dive-agent`'s README and the hardware testing checklist have been
updated to point at `projectbluefin/fisherman` accordingly. This should be
fixed before any real-disk testing, not after — these are exactly the kind
of failures that only show up once you're not on a mocked stdin.

## One correction to issue #6 §5

The RFC lists the clevis/dracut-omit landmine under "already fixed for you"
in the shared fisherman. It isn't — it lives in **wootc's own deployer
script** (`payload/deployer/deploy.sh`'s `DRACUT_OMIT` handling), a
post-install dracut regen step wootc runs that `tuna-dive-agent` doesn't
currently have an equivalent of. Not urgent today (D1 has no dracut-regen
step yet), but worth a comment marker if/when Asahi's agent ever grows one.
