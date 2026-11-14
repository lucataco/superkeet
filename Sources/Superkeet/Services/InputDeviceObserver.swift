import CoreAudio
import Foundation

/// Tells the engine when the Mac's default input or its list of audio devices changes.
@MainActor
final class InputDeviceObserver {
    static let shared = InputDeviceObserver()

    private var started = false
    private var pending: DispatchWorkItem?

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }
    }

    /// Connecting a headset fires several notifications in a row; act once they settle.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { ParakeetService.shared.inputDevicesChanged() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
