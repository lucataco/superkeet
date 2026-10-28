import AVFoundation

@MainActor
enum SetupRefresh {
    @discardableResult
    static func run() -> AppReadinessReport {
        let settings = AppSettings.shared
        let parakeetService = ParakeetService.shared

        ModelProvisioning.shared.refreshInstalledState()
        let refreshed = AppReadiness.current()
        syncAccessibilityState(isGranted: !refreshed.issues.contains(.accessibility))
        if settings.isDaemonRunning,
           refreshed.isReadyForSelectedConfiguration(autoPasteEnabled: settings.autoPasteEnabled) {
            settings.hasVerifiedSetup = true
        }
        parakeetService.lastDiagnosticsSummary = parakeetService.lastDiagnosticsSummary ?? diagnosticsSummary(for: refreshed)
        return refreshed
    }

    static func microphoneDetail(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Access granted."
        case .denied:
            return "Denied. Re-enable it in System Settings."
        case .restricted:
            return "Restricted by the system."
        case .notDetermined:
            return "Not requested yet."
        @unknown default:
            return "Status unknown."
        }
    }

    private static func syncAccessibilityState(isGranted: Bool) {
        let hotkeyManager = HotkeyManager.shared
        hotkeyManager.accessibilityGranted = isGranted
        if isGranted {
            if !hotkeyManager.isListening {
                hotkeyManager.startListening()
            }
        } else if !hotkeyManager.isListening {
            hotkeyManager.startRetryTimer()
        }
    }

    private static func diagnosticsSummary(for readiness: AppReadinessReport) -> String {
        let devices = readiness.diagnostics.availableInputDeviceNames.isEmpty
            ? "none"
            : readiness.diagnostics.availableInputDeviceNames.joined(separator: ", ")
        return """
        Diagnostics:
        - Microphone: \(microphoneDetail(for: readiness.diagnostics.microphoneStatus))
        - Input devices: \(devices)
        - Engine path: \(AppSettings.shared.parakeetBinaryPath)
        - Runtime directory: \(readiness.diagnostics.runtimeDirectory.path)
        """
    }
}
