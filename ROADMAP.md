# Bootsahi release roadmap

This roadmap turns the existing Apple Silicon installer prototype into a
versioned product without weakening the hardware-safety gate in
[`docs/TESTING-CHECKLIST.md`](docs/TESTING-CHECKLIST.md). A green build is
necessary, but it is not evidence that repartitioning and installation are
safe on a real Mac.

## Current baseline (August 2026)

- The payload, first-boot agent, machine protocol, and recovery walkthrough
  have automated coverage.
- The SwiftUI app compiles and tests on a hosted macOS runner, but the complete
  flow has not been run on real Apple Silicon hardware.
- `bonito` and `grouper` are the only catalog entries currently recorded as
  harness-verified.
- The repository has no version tag, GitHub Release, or downloadable notarized
  application.
- Destructive Mac testing remains on hold pending the ordered hardware checks.

## Alpha: one reproducible, hardware-verified install

Alpha is the next release target. It is ready only when all of these outcomes
have durable evidence linked from the release notes:

- [ ] Run the non-destructive hardware checklist: app launch, backend JSON
      round trip, app-to-backend control, and install-config handoff.
- [ ] Complete one controlled end-to-end install on a supported M1 or M2 Mac,
      including recoveryOS blessing, first boot, and a successful boot into a
      harness-verified image.
- [ ] Confirm the installer refuses unsupported Macs and unverified catalog
      entries before making disk changes.
- [ ] Replace the hand-maintained catalog trust bit with CI-generated harness
      evidence ([#70](https://github.com/tuna-os/bootc-installer-asahi/issues/70)).
- [ ] Publish a signed and notarized DMG, checksums, supported-host statement,
      known limitations, recovery guidance, and the exact tested image digest.
- [ ] Tag the same commit used to build the artifact and publish it as the first
      GitHub prerelease.

Until these checks pass, documentation should call the project a prototype
and should not direct users to perform a destructive install.

## Beta: repeatability beyond the first machine

Beta demonstrates that Alpha was not a one-machine success:

- [ ] Repeat the install on a second supported hardware model and from a clean
      macOS host meeting the documented minimum version.
- [ ] Exercise failure and recovery paths after partitioning without damaging
      the neighbouring macOS installation.
- [ ] Publish a compatibility matrix for tested Mac models, macOS hosts,
      catalog images, and installer versions.
- [ ] Add an artifact promotion policy so only a tagged, hardware-qualified
      build is presented as the recommended download.
- [ ] Establish a release owner and response path for installation failures.

## Stable: supported upgrade and recovery lifecycle

Stable requires a supportable lifecycle, not only a successful fresh install:

- [ ] Document and test upgrade compatibility for the app, bootstrap payload,
      catalog schema, and installed operating system.
- [ ] Validate recovery or safe retry after each destructive boundary in the
      install flow.
- [ ] Define the supported release lifetime and deprecation policy for Mac
      models, macOS host versions, and catalog entries.
- [ ] Record release health signals: successful hardware sweeps, confirmed
      installs, installation failures by stage, and time to recovery.

## Decision log

Each release decision should link the exact CI runs, hardware checklist record,
artifact digest, catalog evidence, supported-hardware statement, and unresolved
risks. If a gate is waived, document the owner, rationale, user impact, and
expiry date in the release notes.
