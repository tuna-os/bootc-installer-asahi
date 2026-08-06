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
/// **Why a real NSWindow rather than `ImageRenderer`.** The first version of
/// this used `ImageRenderer`, on the reasoning that offscreen rendering avoids
/// the window-server flake a screenshot job would have. That reasoning was
/// wrong in a way the output made obvious and the CI check did not:
/// `ImageRenderer` draws SwiftUI's own primitives fine — text, symbols, shapes,
/// the CoreImage QR — but it cannot draw AppKit-backed CONTROLS. Buttons came
/// out as the yellow/red "unsupported view" placeholder, and `Form`, `List`,
/// `Slider` and `TextField` did not come out at all. The settings screen
/// rendered as a title over an empty page, and the catalog screen was 57%
/// placeholder block. Every published screenshot was missing the very controls
/// a walkthrough exists to point at.
///
/// So the views are hosted in an `NSHostingView` inside a real (never ordered
/// on screen) `NSWindow`, and captured with `cacheDisplay(in:to:)`. The
/// controls are then genuine NSViews in a genuine view hierarchy and draw
/// themselves properly. It still needs no visible window, no focus and no
/// timing guesswork.
///
/// What is still absent, honestly: the title bar and the vibrancy behind
/// `.bar`, because those belong to window chrome the capture does not include.
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

    override func setUp() {
        super.setUp()
        // Touching NSApplication.shared is what creates the connection AppKit
        // needs before any NSWindow can be made. Without it the first window
        // construction traps rather than returning nil.
        _ = NSApplication.shared
    }

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
            try audit(image, name: shot.name)
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
        let content = view
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let host = NSHostingView(rootView: AnyView(content))
        host.frame = NSRect(origin: .zero, size: Self.size)

        // A real window, never ordered on screen. AppKit controls need to be in
        // a window's view hierarchy to draw — that is precisely what
        // ImageRenderer could not give them — but they do NOT need that window
        // to be visible, focused, or on any display.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }

    /// Fails the capture when a screen did not really render.
    ///
    /// The previous check asked whether the PNG files existed and were
    /// non-empty. They did and they were — while showing a blank settings page
    /// and a catalog screen that was more than half "unsupported view"
    /// placeholder. Existence was the wrong question; it is exactly the shape
    /// of bug this rig was built to catch, reintroduced by the rig itself.
    ///
    /// So: look at the pixels.
    private func audit(_ image: CGImage, name: String) throws {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else {
            XCTFail("could not read pixels back for \(name)")
            return
        }

        var placeholder = 0
        var ink = 0
        var samples = 0
        // Every 7th pixel: plenty for a ratio, and keeps the audit off the
        // critical path of a CI job.
        for i in stride(from: 0, to: w * h * 4, by: 4 * 7) {
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            samples += 1
            // SwiftUI's unsupported-view marker is a saturated yellow field.
            if r > 230, g > 170, g < 225, b < 70 { placeholder += 1 }
            // Anything that is not the window background counts as content.
            if abs(r - 236) > 12 || abs(g - 236) > 12 || abs(b - 236) > 12 { ink += 1 }
        }

        let placeholderRatio = Double(placeholder) / Double(samples)
        let inkRatio = Double(ink) / Double(samples)

        // 0.25%: an orange warning glyph is far below this; a placeholder BLOCK
        // standing in for a button is above it. Measured against the broken
        // output, the smallest real placeholder was 0.50% and the largest
        // legitimate orange icon well under 0.05%.
        XCTAssertLessThan(
            placeholderRatio, 0.0025,
            "\(name) is \(Int(placeholderRatio * 100))% SwiftUI "
                + "\"unsupported view\" placeholder — a control failed to draw")

        // A screen whose body did not render still has its header, which is
        // about 9% ink. Anything at or below that is a title over an empty page.
        XCTAssertGreaterThan(
            inkRatio, 0.12,
            "\(name) is only \(Int(inkRatio * 100))% non-background — the body "
                + "of the screen is missing, not merely sparse")
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
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
