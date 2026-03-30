import Foundation
import AVFoundation
import AppKit

enum AppReadinessIssue: String, CaseIterable, Identifiable {
    case microphone
    case inputDevice
    case engine
    case runtimeDirectory
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:
            return "Microphone Access"
        case .inputDevice:
            return "Audio Input Device"
        case .engine:
            return "Speech Engine"
        case .runtimeDirectory:
            return "Runtime Directory"
        case .accessibility:
            return "Accessibility Access"
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
        case .runtimeDirectory:
            return "Superkeet needs a writable runtime directory for its local socket and PID file."
        case .accessibility:
            return "Accessibility is only needed for optional global shortcuts and auto-paste."
        }
    }
}

struct AppDiagnostics {
    let microphoneStatus: AVAuthorizationStatus
    let availableInputDeviceNames: [String]
    let engineBinaryExists: Bool
    let runtimeDirectory: URL
    let runtimeDirectoryWritable: Bool
    let configuredInputDeviceFound: Bool

    var hasInputDevice: Bool {
        !availableInputDeviceNames.isEmpty
    }
}

struct AppReadinessReport {
    let issues: [AppReadinessIssue]
    let diagnostics: AppDiagnostics

    var hasDaemonBlockingIssue: Bool {
        issues.contains(.engine) || issues.contains(.runtimeDirectory)
    }

    var hasRecordingBlockingIssue: Bool {
        issues.contains(.microphone) || issues.contains(.inputDevice)
    }

    var isReadyForDaemon: Bool {
        !hasDaemonBlockingIssue
    }

    var isReadyForBasicRecording: Bool {
        !hasDaemonBlockingIssue && !hasRecordingBlockingIssue
    }

    func passesSetupSmokeTest(daemonStarted: Bool) -> Bool {
        daemonStarted && isReadyForBasicRecording
    }

    var statusText: String {
        if issues.isEmpty {
            return "Ready to record"
        }
        if isReadyForDaemon {
            return "Ready with limited automation"
        }
        return "Setup required"
    }
}

enum AppReadiness {
    static func current(settings: AppSettings = .shared) -> AppReadinessReport {
        let diagnostics = collectDiagnostics(settings: settings)
        var issues: [AppReadinessIssue] = []

        if diagnostics.microphoneStatus == .denied || diagnostics.microphoneStatus == .restricted {
            issues.append(.microphone)
        }

        if !diagnostics.engineBinaryExists {
            issues.append(.engine)
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

        return AppDiagnostics(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            availableInputDeviceNames: availableInputDeviceNames,
            engineBinaryExists: FileManager.default.isExecutableFile(atPath: settings.parakeetBinaryPath),
            runtimeDirectory: runtimeDirectory,
            runtimeDirectoryWritable: validateRuntimeDirectory(runtimeDirectory),
            configuredInputDeviceFound: configuredInputDeviceFound
        )
    }

    static func runtimeFilesDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("com.superkeet.app/Runtime", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func validateRuntimeDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        let probeURL = directory.appendingPathComponent(".write-test-\(UUID().uuidString)")
        do {
            try "ok".data(using: .utf8)?.write(to: probeURL)
            try fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }
}
