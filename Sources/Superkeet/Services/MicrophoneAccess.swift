import AVFoundation

/// Checks microphone permission before a recording starts. Without this, a denied permission makes
/// CoreAudio hand the engine silence and the user only ever sees "No speech detected".
enum MicrophoneAccess {
    enum Decision: Equatable {
        case allowed
        case needsPrompt
        case denied
    }

    static let deniedMessage = "Superkeet doesn't have microphone access. Turn it on in System Settings → Privacy & Security → Microphone."

    static func decision(for status: AVAuthorizationStatus) -> Decision {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .needsPrompt
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Returns whether recording may proceed, prompting once if the user hasn't decided yet.
    static func ensureAccess(
        status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        requestAccess: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) async -> Bool {
        switch decision(for: status()) {
        case .allowed: return true
        case .denied: return false
        case .needsPrompt: return await requestAccess()
        }
    }
}
