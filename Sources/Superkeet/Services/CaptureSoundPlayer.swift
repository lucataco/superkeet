import AppKit

/// Plays brief cue sounds for recording lifecycle events. Uses macOS built-in
/// sounds (resolved by name) so no bundled audio assets are required.
enum CaptureSoundPlayer {

    enum Event {
        case start
        case stop
    }

    /// Cached sound instances — resolving `NSSound(named:)` per recording
    /// start allocates an audio object each time.
    private static let cachedSounds: [Event: NSSound] = {
        var map: [Event: NSSound] = [:]
        for event in [Event.start, .stop] {
            if let sound = NSSound(named: NSSound.Name(soundName(for: event))) {
                map[event] = sound
            }
        }
        return map
    }()

    /// Play the cue for an event when the user's style is not `.none`.
    static func play(_ event: Event) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AppSettings.shared.captureSoundStyleResolved != .none else { return }
        guard let sound = cachedSounds[event] else { return }
        // Cut off a still-playing previous cue before retriggering.
        sound.stop()
        sound.play()
    }

    /// Pure mapping for tests: the system sound name used for each event.
    static func soundName(for event: Event) -> String {
        switch event {
        case .start: return "Tink"
        case .stop: return "Pop"
        }
    }
}
