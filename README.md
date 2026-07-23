# fisherman-asahi

The Apple Silicon (Asahi Linux) installer path for TunaOS-family bootc images
— and anyone else's (Dakota, Bluefin, Bazzite): a macOS-driven install flow
for M1/M2 Macs.

**Architecture** (see [docs/DESIGN.md](docs/DESIGN.md)): instead of one
installer payload per variant×desktop, we ship **one minimal bootstrap
payload** whose first boot runs [fisherman](https://github.com/projectbluefin/fisherman)
to `bootc install` the image ref the user picked in the macOS app. The catalog
is just registry refs (`bonito:gnome-asahi`, …) — new variants appear without
touching the installer.

## Status

- [x] Design (docs/DESIGN.md)
- [x] D0 scaffold: `scripts/make-payload.sh` + `build-payload.yml` — package
      any asahi-capable bootc image as an asahi-installer zip +
      `installer_data.json` (artifact-only; R2 upload TODO)
- [ ] D0 validated against a real asahi image (`bonito:gnome-asahi`, tunaOS#774)
- [ ] D1 first-boot fisherman agent config (`install-config.json` → unattended `bootc install`)
- [ ] D2 asahi-installer `--json` machine mode (upstreamable)
- [ ] D3 macOS app (SwiftUI, wraps the asahi-installer Python backend)
- [ ] D4 recoveryOS walkthrough UX, LUKS, Wi-Fi handoff

Payload layout & `installer_data.json` schema modeled on
fedora-asahi kiwi-descriptions and
[nixos-asahi-package](https://github.com/quinneden/nixos-asahi-package).
M1/M2 only — M3+ has no Asahi installer support yet.
