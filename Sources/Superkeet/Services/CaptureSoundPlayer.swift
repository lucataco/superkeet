import AppKit

enum CaptureSoundPlayer {

    enum Event {
        case start
        case stop
    }

    private static let cachedSounds: [Event: NSSound] = {
        var map: [Event: NSSound] = [:]
        for event in [Event.start, .stop] {
            if let sound = NSSound(named: NSSound.Name(soundName(for: event))) {
                map[event] = sound
            }
        }
        return map
    }()

    static func play(_ event: Event) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AppSettings.shared.captureSoundStyleResolved != .none else { return }
        guard let sound = cachedSounds[event] else { return }
        sound.stop()
        sound.play()
    }

    static func soundName(for event: Event) -> String {
        switch event {
        case .start: return "Tink"
        case .stop: return "Pop"
        }
    }
}
