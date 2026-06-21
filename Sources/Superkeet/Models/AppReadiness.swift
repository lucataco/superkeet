import Foundation
import AVFoundation
import AppKit

enum AppReadinessIssue: String, CaseIterable, Identifiable {
    case microphone
    case inputDevice
    case engine
    case model
    case runtimeDirectory
    case accessibility
    case architecture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone Access"
        case .inputDevice:
            return "Audio Input Device"
        case .engine:
            return "Speech Engine"
        case .model:
            return "Speech Model"
        case .runtimeDirectory:
            return "Runtime Directory"
        case .accessibility:
            return "Accessibility Access"
        case .architecture:
            return "Apple Silicon Mac"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            return "Grant microphone access so Superkeet can record your voice."
        case .inputDevice:
            return "Connect or enable a microphone so Parakeet has an input device to record from."
        case .engine:
            return "Point Superkeet at a working Parakeet engine build before recording."
        case .model:
            return "Download the on-device speech model so Superkeet can transcribe locally."
        case .runtimeDirectory:
            return "Superkeet needs a writable runtime directory for its local socket and PID file."
        case .accessibility:
            return "Accessibility enables global shortcuts and automatic paste."
        case .architecture:
            return "Superkeet's bundled speech engine is built for Apple Silicon. An Intel Mac cannot run it."
        }
    }
}

struct AppDiagnostics {
    let microphoneStatus: AVAuthorizationStatus
    let availableInputDeviceNames: [String]
    let engineBinaryExists: Bool
    let modelInstalled: Bool
    let runtimeDirectory: URL
    let runtimeDirectoryWritable: Bool
    let configuredInputDeviceFound: Bool
    let hostIsAppleSilicon: Bool

    var hasInputDevice: Bool {
        !availableInputDeviceNames.isEmpty
    }
}

struct AppReadinessReport {
    let issues: [AppReadinessIssue]
    let diagnostics: AppDiagnostics

    /// Issues that mean a fresh app install is genuinely broken (missing engine
    /// binary, unsupported architecture, or no writable runtime dir). A missing
    /// *model* is intentionally excluded — that's a recoverable first-run
    /// download, not a broken install.
    var hasDaemonBlockingIssue: Bool {
        issues.contains(.engine) || issues.contains(.runtimeDirectory) || issues.contains(.architecture)
    }

    var hasRecordingBlockingIssue: Bool {
        issues.contains(.microphone) || issues.contains(.inputDevice)
    }

    /// The on-device model still needs to be downloaded before recording works.
    var needsModelDownload: Bool {
        issues.contains(.model)
    }

    var isReadyForDaemon: Bool {
        !hasDaemonBlockingIssue
    }

    var isReadyForBasicRecording: Bool {
        !hasDaemonBlockingIssue && !needsModelDownload && !hasRecordingBlockingIssue
    }

    func hasConfiguredOutputBlockingIssue(autoPasteEnabled: Bool) -> Bool {
        autoPasteEnabled && issues.contains(.accessibility)
    }

    func isReadyForSelectedConfiguration(autoPasteEnabled: Bool) -> Bool {
        isReadyForBasicRecording && !hasConfiguredOutputBlockingIssue(autoPasteEnabled: autoPasteEnabled)
    }

    func passesSetupSmokeTest(daemonStarted: Bool, autoPasteEnabled: Bool = false) -> Bool {
        daemonStarted && isReadyForSelectedConfiguration(autoPasteEnabled: autoPasteEnabled)
    }

    var statusText: String {
        if issues.isEmpty {
            return "Ready to record"
        }
        if isReadyForBasicRecording {
            return "Ready with limited automation"
        }
        if isReadyForDaemon {
            return "Setup needs attention"
        }
        return "Setup required"
    }
}

enum AppReadiness {
    static func current(settings: AppSettings = .shared) -> AppReadinessReport {
        let diagnostics = collectDiagnostics(settings: settings)
        var issues: [AppReadinessIssue] = []

        if diagnostics.microphoneStatus != .authorized {
            issues.append(.microphone)
        }

        if !diagnostics.hostIsAppleSilicon {
            issues.append(.architecture)
        }

        if !diagnostics.engineBinaryExists {
            issues.append(.engine)
        }

        if !diagnostics.modelInstalled {
            issues.append(.model)
        }

        if !diagnostics.hasInputDevice || !diagnostics.configuredInputDeviceFound {
            issues.append(.inputDevice)
        }

        if !diagnostics.runtimeDirectoryWritable {
            issues.append(.runtimeDirectory)
        }

        if !HotkeyManager.shared.checkAccessibilitySilently() {
            issues.append(.accessibility)
        }

        return AppReadinessReport(issues: issues, diagnostics: diagnostics)
    }

    static func collectDiagnostics(settings: AppSettings = .shared) -> AppDiagnostics {
        let runtimeDirectory = runtimeFilesDirectory()
        let inputDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        let availableInputDeviceNames = inputDevices.map(\.localizedName).sorted()
        let configuredInputDeviceFound = settings.audioInputDevice.isEmpty ||
            availableInputDeviceNames.contains { $0.localizedCaseInsensitiveContains(settings.audioInputDevice) }

        let modelDirectory = URL(fileURLWithPath: settings.effectiveModelDirectory, isDirectory: true)

        return AppDiagnostics(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            availableInputDeviceNames: availableInputDeviceNames,
            engineBinaryExists: FileManager.default.isExecutableFile(atPath: settings.parakeetBinaryPath),
            modelInstalled: ModelProvisioning.modelExists(at: modelDirectory),
            runtimeDirectory: runtimeDirectory,
            runtimeDirectoryWritable: validateRuntimeDirectory(runtimeDirectory),
            configuredInputDeviceFound: configuredInputDeviceFound,
            hostIsAppleSilicon: Self.hostIsAppleSilicon
        )
    }

    static func runtimeFilesDirectory() -> URL {
        cachedRuntimeFilesDirectory
    }

    /// Resolved once on first access and memoized. `runtimeFilesDirectory()` was
    /// previously called on every read of `settings.socketPath` /
    /// `settings.pidFilePath` (15+ times per daemon lifecycle), each call
    /// issuing a `FileManager.createDirectory`. Caching drops that to one call.
    private static let cachedRuntimeFilesDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let directory = base.appendingPathComponent("com.superkeet.app/Runtime", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }()

    private static func validateRuntimeDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        let probeURL = directory.appendingPathComponent(".write-test-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probeURL)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    /// True when the host CPU is Apple Silicon (arm64 / arm64e).
    /// Used to refuse startup on Intel Macs, where the bundled engine binary
    /// cannot run and would produce a confusing launch failure.
    private static var hostIsAppleSilicon: Bool {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return true }  // fail open
        let machineSize = MemoryLayout.size(ofValue: sysinfo.machine)
        let machine = withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("arm64")
    }
}
