import SwiftUI

// MARK: - Layout metrics

/// One source of truth for the numbers AppKit apps share.
///
/// The single biggest reason the old screens read as "not a Mac app" was not a
/// missing effect — it was that every screen invented its own metrics. Welcome
/// used `.padding(40)`, Catalog `.padding()`, Options `.padding()`, spacing
/// ranged over 12/16/24 with no rule. macOS reads as native mostly through
/// consistency of margins, control sizing and type ramp; a user cannot name
/// the rule but sees it break immediately.
enum Metrics {
    /// Standard window content margin in macOS (matches the system's own
    /// preference panes and setup assistants).
    static let margin: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 12
}

// MARK: - Liquid Glass seam

/// The one place the app opts into macOS 26 (Tahoe) Liquid Glass.
///
/// Two gates, and both are load-bearing:
///
/// - `#if compiler(>=6.2)` — `glassEffect` does not merely require macOS 26 at
///   *runtime*, it requires the macOS 26 SDK to compile at all. The repo's
///   long-standing runner is `macos-14` (Xcode 15.4 / Swift 5.10), where an
///   `#available` check alone would still fail to build. The compiler gate is
///   what lets one source tree build on both.
/// - `#available(macOS 26.0, *)` — the package's deployment target is macOS 13,
///   matching asahi-installer's own MIN_MACOS_VERSION. Raising it to 26 would
///   mean telling someone they must upgrade macOS before they are allowed to
///   install Linux, which is a worse trade than a fallback surface.
///
/// So on Tahoe this is real Liquid Glass, and on Ventura/Sonoma/Sequoia it is
/// the material that was already idiomatic there. Neither is a mock of the
/// other.
extension View {
    /// A raised surface: asks, cards, anything that floats above the page.
    @ViewBuilder
    func wizardSurface() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        } else {
            self.legacySurface()
        }
        #else
        self.legacySurface()
        #endif
    }

    fileprivate func legacySurface() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1))
    }
}

// MARK: - Page scaffold

/// Every step of the wizard is this shape: an icon, a title, a subtitle, a body
/// that grows, and a bottom bar whose primary button sits trailing.
///
/// The bottom bar is a `safeAreaInset` rather than the last child of a VStack so
/// that scrollable content scrolls *under* it. That is what macOS does, and it
/// is why a long install log no longer pushes "Continue" off the window.
struct WizardPage<Content: View, Actions: View>: View {
    private let symbol: String
    private let title: String
    private let subtitle: String?
    private let content: Content
    private let actions: Actions

    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            // Hierarchical rendering is what makes a single-colour SF Symbol
            // look like a system icon rather than a pasted glyph.
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title.weight(.semibold))
                Text(subtitle ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(subtitle == nil ? 0 : 1)
                    // Reserve the line even when empty so the body content does
                    // not shift vertically between steps that have a subtitle
                    // and steps that do not. Jumping chrome is the tell of a
                    // web app in a window.
                    .frame(height: subtitle == nil ? 0 : nil)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.horizontal, Metrics.margin)
            .padding(.vertical, 14)
        }
        // `.bar` is the system's own toolbar/inspector material: it picks up
        // vibrancy and the correct light/dark treatment for free.
        .background(.bar)
    }
}

// MARK: - Buttons

extension View {
    /// The one call to action on a screen. `.large` + prominent + default-action
    /// is the macOS setup-assistant convention, and wiring Return to it means
    /// the keyboard flow works without a single extra line per screen.
    func primaryAction() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    func secondaryAction() -> some View {
        self
            .buttonStyle(.bordered)
            .controlSize(.large)
    }
}
