import Foundation
import Combine

/// Drives the wizard flow from DESIGN.md: welcome -> catalog -> disk-space
/// slider -> options (user/Wi-Fi/LUKS) -> run backend with progress ->
/// guided recoveryOS walkthrough.
///
/// Catalog/options selection happens entirely in this app, before the
/// backend process is even started — the forked asahi-installer only ever
/// installs the single "tuna-dive-boot" bootstrap OS (per DESIGN.md's core
/// idea: one bootstrap payload per architecture, not per variant), so it
/// has no reason to know about variant/desktop/stream at all. Those choices
/// only matter for install-config.json, written after the backend finishes
/// creating the target partitions — see writeInstallConfig() below, which
/// is a TODO: the exact handoff point (which ESP, which partition device
/// names) depends on what the backend reports back, and that reporting
/// contract doesn't exist yet. Flagged in README.md, not invented here.
@MainActor
final class InstallFlowViewModel: ObservableObject {
    enum Step: Equatable {
        case welcome
        case catalog
        case options
        case diskSlider
        case installing
        case recoveryWalkthrough
        case done
        case failed(String)
    }

    @Published private(set) var step: Step = .welcome
    @Published private(set) var log: [BackendMessage] = []
    @Published private(set) var pendingAsk: BackendAsk?
    @Published var catalog: Catalog?
    @Published var selectedEntry: CatalogEntry?
    @Published var config = InstallConfig(
        targetImgref: "", rootPartition: "", espPartition: "",
        filesystem: "btrfs", hostname: "")

    private var process: InstallerProcess?
    private var e2eTimer: Timer?

    /// Starts polling for drive-mode directives (tuna-dive-agent#6 §2). No-op
    /// unless TUNADIVE_E2E_DRIVE=1 — see E2EDrive's doc comment. Call once,
    /// e.g. from the app's init.
    func startE2EDriveIfEnabled() {
        guard E2EDrive.isEnabled else { return }
        reportE2EState()
        e2eTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollE2EDirective() }
        }
    }

    private func pollE2EDirective() {
        guard let directive = E2EDrive.nextDirective() else { return }
        switch directive {
        case .selectCatalogEntry(let imgref):
            selectedEntry = catalog?.entries.first { $0.imgref == imgref }
        case .setHostname(let value):
            config.hostname = value
        case .advance:
            switch step {
            case .welcome: advanceToCatalog()
            case .catalog: advanceToOptions()
            case .options: advanceToDiskSlider()
            case .recoveryWalkthrough: confirmRecoveryOSComplete()
            default: break
            }
        case .answerAsk(let value):
            answer(value)
        }
        reportE2EState()
    }

    private func reportE2EState() {
        var state: [String: Any] = ["step": "\(step)"]
        if let entry = selectedEntry { state["selectedEntry"] = entry.imgref }
        state["hostname"] = config.hostname
        state["pendingAskKind"] = pendingAsk?.kind.rawValue ?? NSNull()
        state["logCount"] = log.count
        E2EDrive.report(state)
    }

    func loadCatalog(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        catalog = try? JSONDecoder().decode(Catalog.self, from: data)
    }

    func advanceToCatalog() {
        guard step == .welcome else { return }
        step = .catalog
    }

    func advanceToOptions() {
        guard step == .catalog, let entry = selectedEntry else { return }
        config.targetImgref = entry.imgref
        step = .options
    }

    func advanceToDiskSlider() {
        guard step == .options, !config.hostname.isEmpty else { return }
        step = .diskSlider
    }

    /// Launches the forked asahi-installer in --json mode. See
    /// InstallerProcess's doc comment for the unresolved python3-location
    /// packaging question.
    func startBackend(pythonPath: String, mainPyPath: String, workingDirectory: URL) {
        let proc = InstallerProcess(pythonPath: pythonPath, mainPyPath: mainPyPath,
                                     workingDirectory: workingDirectory)
        proc.onEvent = { [weak self] event in self?.handle(event) }
        proc.onLog = { [weak self] text in
            self?.log.append(BackendMessage(level: .plain, text: "[unparsed] \(text)"))
        }
        proc.onTerminate = { [weak self] code in
            guard let self else { return }
            if code == 0 {
                self.step = .recoveryWalkthrough
            } else {
                self.step = .failed("installer backend exited with status \(code)")
            }
        }
        process = proc
        step = .installing
        do {
            try proc.start()
        } catch {
            step = .failed("failed to launch installer backend: \(error)")
        }
    }

    /// Called by whichever view is currently rendering pendingAsk once the
    /// user (or an automatic default, e.g. the disk slider's initial value)
    /// has produced an answer.
    func answer(_ value: JSONValue?) {
        guard let ask = pendingAsk else { return }
        process?.send(answerId: ask.id, value: value)
        pendingAsk = nil
    }

    func confirmRecoveryOSComplete() {
        guard step == .recoveryWalkthrough else { return }
        step = .done
    }

    private func handle(_ event: BackendEvent) {
        switch event {
        case .message(let msg):
            log.append(msg)
        case .ask(let ask):
            pendingAsk = ask
        }
        reportE2EState()
    }
}
