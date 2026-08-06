import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Bootsahi

/// Renders every screen of the installer to PNG, plus an animated walkthrough,
/// for `docs/gui-walkthrough.md` and the README.
///
/// **Why a test target rather than a `swift run` tool.** `Bootsahi` is an
/// executable target, and SwiftPM will not let a second non-test target import
/// one. The choices were to split the app into a library plus a thin shim — a
/// refactor touching every file, verified by no local compiler — or to use the
/// one target that is already allowed to `@testable import` it and already runs
/// in CI. The second is smaller and reuses a harness that demonstrably works.
///
/// **Why `ImageRenderer` rather than launching the app and screenshotting it.**
/// wootc captures its GTK apps under Xvfb, which has no macOS equivalent:
/// AppKit needs a real window server, so a screenshot job would depend on the
/// runner's GUI session, window focus and animation timing — three sources of
/// flake that produce *plausible but wrong* images rather than clean failures.
/// `ImageRenderer` draws the same SwiftUI tree deterministically, offscreen,
/// with no window at all.
///
/// The trade is honest and worth stating: `ImageRenderer` renders the view
/// hierarchy, not the window. Title bar, vibrancy behind `.bar`, and the
/// macOS 26 glass effect are all window-server effects and will not appear.
/// These are screenshots of *layout, type and content*, which is what a
/// walkthrough needs and what a design review can act on — not a pixel-exact
/// portrait of the shipped window.
///
/// Writes nothing unless `BOOTSAHI_CAPTURE_DIR` is set, so a normal `swift
/// test` stays a test run.
@MainActor
final class ScreenshotCaptureTests: XCTestCase {

    private struct Shot {
        let name: String
        let caption: String
        let view: AnyView
    }

    private static let size = CGSize(width: 860, height: 640)

    func testCaptureWalkthrough() throws {
        guard let dir = ProcessInfo.processInfo.environment["BOOTSAHI_CAPTURE_DIR"] else {
            throw XCTSkip("BOOTSAHI_CAPTURE_DIR not set — capture is opt-in")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var frames: [CGImage] = []
        for shot in Self.shots() {
            let image = try XCTUnwrap(
                render(shot.view),
                "failed to render \(shot.name) — an ImageRenderer nil here means the "
                    + "view tree could not be laid out at \(Self.size)")
            try writePNG(image, to: out.appendingPathComponent("\(shot.name).png"))
            frames.append(image)
        }

        XCTAssertEqual(
            frames.count, Self.shots().count,
            "every screen must render; a missing frame would silently shorten the "
                + "walkthrough rather than fail the docs build")

        try writeAnimation(frames, to: out.appendingPathComponent("walkthrough.gif"))
    }

    // MARK: - The screens, in the order a user meets them

    private static func shots() -> [Shot] {
        let catalog = Catalog(
            generatedAt: "2026-08-01T00:00:00Z",
            entries: [
                CatalogEntry(variant: "bonito", desktop: "GNOME", stream: "stable",
                             imgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
                             description: "TunaOS with the GNOME desktop. The default, "
                                        + "and the best-tested combination."),
                CatalogEntry(variant: "dakota", desktop: "KDE Plasma", stream: "stable",
                             imgref: "ghcr.io/tuna-os/dakota:kde-asahi",
                             description: "TunaOS with KDE Plasma, for a more "
                                        + "customisable desktop."),
                CatalogEntry(variant: "bluefin", desktop: "GNOME", stream: "testing",
                             imgref: "ghcr.io/ublue-os/bluefin:asahi",
                             description: "Universal Blue's developer-focused image. "
                                        + "Tracks upstream more closely."),
            ])

        var configured = InstallConfig(
            targetImgref: "ghcr.io/tuna-os/bonito:gnome-asahi",
            rootPartition: "", espPartition: "",
            filesystem: "ext4", hostname: "seans-air")
        // A hash, not a typed password: the model only ever holds the $6$ form
        // (see InstallConfig.UserSpec), so a plaintext fixture would document a
        // state the app cannot actually be in.
        configured.user = .init(username: "sean", fullname: "Sean",
                                password: PasswordHash.hash("correct horse battery"),
                                groups: ["wheel"])

        // A believable APFS split on a 512 GB Mac: the numbers are what the
        // reader checks first, so round, plausible ones matter more here than
        // in most fixtures.
        let sizeAsk = BackendAsk(
            kind: .size,
            id: "resize",
            prompt: "How much space should Linux get?",
            defaultValue: .int(120_000_000_000),
            options: nil,
            min: 45_000_000_000,
            max: 380_000_000_000,
            total: 500_000_000_000)

        let installLog: [BackendMessage] = [
            .init(level: .info, text: "Collecting system information..."),
            .init(level: .success, text: "Apple Silicon (t8103), macOS 15.5"),
            .init(level: .progress, text: "Resizing the macOS container..."),
            .init(level: .success, text: "Created 120 GB of free space"),
            .init(level: .progress, text: "Downloading bootsahi-boot payload..."),
            .init(level: .warning, text: "Mirror slow, retrying with fallback"),
            .init(level: .progress, text: "Installing m1n1 + U-Boot to the EFI system partition"),
        ]

        return [
            Shot(name: "01-welcome",
                 caption: "What the install will do, before anything is touched.",
                 view: AnyView(WelcomeView()
                    .environmentObject(InstallFlowViewModel.fixture(step: .welcome)))),

            Shot(name: "02-choose-image",
                 caption: "Pick a desktop. Every option is a bootc image.",
                 view: AnyView(CatalogView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .catalog,
                        catalog: catalog,
                        selectedEntry: catalog.entries[0])))),

            Shot(name: "03-settings",
                 caption: "Account, computer name and Wi-Fi network.",
                 view: AnyView(OptionsView(previewPassword: "correct horse battery")
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .options, config: configured)))),

            Shot(name: "04-disk-space",
                 caption: "Choose the split. macOS keeps the rest.",
                 view: AnyView(InstallProgressView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .diskSlider, config: configured, pendingAsk: sizeAsk)))),

            Shot(name: "05-installing",
                 caption: "Progress, with the full log one click away.",
                 view: AnyView(InstallProgressView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .installing, config: configured, log: installLog)))),

            Shot(name: "06-recoveryos",
                 caption: "The one step no software can do for you.",
                 view: AnyView(RecoveryWalkthroughView()
                    .environmentObject(InstallFlowViewModel.fixture(
                        step: .recoveryWalkthrough)))),
        ]
    }

    // MARK: - Rendering

    private func render(_ view: AnyView) -> CGImage? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: Self.size.width, height: Self.size.height)
                // Without an explicit background the render is transparent, which
                // reads as a black rectangle in most Markdown viewers' dark mode
                // and as ragged edges in light. Ask for the real window colour.
                .background(Color(nsColor: .windowBackgroundColor)))
        // Retina: the screenshots are viewed on the machines this app targets.
        renderer.scale = 2
        return renderer.cgImage
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = Self.size
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError.encodingFailed(url.lastPathComponent)
        }
        try data.write(to: url)
    }

    /// An animated GIF, assembled with ImageIO.
    ///
    /// wootc builds its timelapse with ffmpeg, which is not preinstalled on
    /// GitHub's macOS runners — `brew install ffmpeg` would add minutes to every
    /// run for one file. ImageIO ships with the OS and writes GIF natively, and
    /// GitHub renders animated GIFs inline in READMEs.
    private func writeAnimation(_ frames: [CGImage], to url: URL) throws {
        guard !frames.isEmpty else { throw CaptureError.noFrames }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw CaptureError.encodingFailed(url.lastPathComponent) }

        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        // 2.4s a frame. These are dense screens of text, not motion — a
        // walkthrough the reader cannot finish reading is decoration.
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 2.4]
        ] as CFDictionary

        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.encodingFailed(url.lastPathComponent)
        }
    }

    private enum CaptureError: Error {
        case encodingFailed(String)
        case noFrames
    }
}
