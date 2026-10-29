import AVFoundation
import AppKit
import ApplicationServices
import CoreAudio

setvbuf(stdout, nil, _IOLBF, 0)

let hudBundle = "com.superkeet.app"
let pollSeconds = 0.02
let hudSeconds = 0.05
let axTimeout: Float = 0.1

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var options: [String: [String]] = [:]
let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { fail("usage: observer play|press|check [--option value]...") }
var cursor = 1
while cursor < argv.count {
    guard argv[cursor].hasPrefix("--"), cursor + 1 < argv.count else { fail("bad argument \(argv[cursor])") }
    options[String(argv[cursor].dropFirst(2)), default: []].append(argv[cursor + 1])
    cursor += 2
}
func option(_ name: String) -> String? { options[name]?.last }
func intOption(_ name: String, _ fallback: Int) -> Int { option(name).flatMap { Int($0) } ?? fallback }

var audioStart: Date?
let emitLock = NSLock()
func emit(_ event: String, _ extra: [String: Any] = [:]) {
    let now = Date()
    var row: [String: Any] = ["event": event, "t": Int64(now.timeIntervalSince1970 * 1000)]
    for (key, value) in extra { row[key] = value }
    emitLock.lock()
    defer { emitLock.unlock() }
    if let start = audioStart { row["ms"] = Int(now.timeIntervalSince(start) * 1000) }
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
}

func pressHotkey() {
    let source = CGEventSource(stateID: .hidSystemState)
    let code = CGKeyCode(intOption("hotkey-code", 49))
    let flags = CGEventFlags(rawValue: UInt64(intOption("hotkey-flags", 0)))
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func outputDeviceIDs() -> [(AudioDeviceID, String)] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let value = name?.takeRetainedValue() as String? else { return nil }
        return (id, value)
    }
}

if command == "press" {
    pressHotkey()
    exit(0)
}
if command == "check" {
    let names = outputDeviceIDs().map { $0.1 }
    let wanted = option("out-device") ?? ""
    emit("check", ["ax_trusted": AXIsProcessTrusted(), "device_found": names.contains(wanted), "devices": names])
    exit(AXIsProcessTrusted() && names.contains(wanted) ? 0 : 1)
}
guard command == "play" else { fail("unknown command \(command)") }
guard AXIsProcessTrusted() else { fail("this process lacks Accessibility; grant it to the terminal in System Settings") }
guard let wavPath = option("wav") else { fail("--wav is required") }

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func axApp(pid: pid_t) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, axTimeout)
    return app
}

func collectStaticText(_ element: AXUIElement, depth: Int, into out: inout [String]) {
    let role = attr(element, kAXRoleAttribute) as? String
    if role == "AXStaticText" || role == "AXTextField" {
        if let text = attr(element, kAXValueAttribute) as? String, !text.isEmpty { out.append(text) }
        else if let text = attr(element, kAXDescriptionAttribute) as? String, !text.isEmpty { out.append(text) }
    }
    guard depth > 0, let kids = attr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for kid in kids { collectStaticText(kid, depth: depth - 1, into: &out) }
}

func collectTextAreas(_ element: AXUIElement, depth: Int, into out: inout [String]) {
    if (attr(element, kAXRoleAttribute) as? String) == "AXTextArea" {
        out.append((attr(element, kAXValueAttribute) as? String) ?? "")
        return
    }
    guard depth > 0, let kids = attr(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for kid in kids { collectTextAreas(kid, depth: depth - 1, into: &out) }
}

let wav = URL(fileURLWithPath: wavPath)
let outName = option("out-device") ?? ""
let leadSeconds = Double(intOption("lead-ms", 1500)) / 1000
let tailSeconds = Double(intOption("tail-ms", 5000)) / 1000
let targets = options["target"] ?? []

let engine = AVAudioEngine()
let node = AVAudioPlayerNode()
guard let file = try? AVAudioFile(forReading: wav) else { fail("cannot read \(wavPath)") }
engine.attach(node)
engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
if !outName.isEmpty {
    guard var device = outputDeviceIDs().first(where: { $0.1 == outName })?.0,
          let unit = engine.outputNode.audioUnit else { fail("no output device named \(outName)") }
    let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { fail("cannot select \(outName), status \(status)") }
}
node.scheduleFile(file, at: nil)
do { try engine.start() } catch { fail("audio engine failed: \(error)") }
let audioSeconds = Double(file.length) / file.processingFormat.sampleRate

_ = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in }
func pump(until date: Date) { RunLoop.current.run(mode: .default, before: date) }

final class Loop {
    let name: String
    private let lock = NSLock()
    private var stopped = false
    private var polls = 0
    private var slow = 0
    private var maxMs = 0.0
    private let done = DispatchSemaphore(value: 0)

    init(_ name: String) { self.name = name }

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func record(_ started: Date) {
        let spent = Date().timeIntervalSince(started) * 1000
        lock.lock(); polls += 1; maxMs = max(maxMs, spent); if spent > 100 { slow += 1 }; lock.unlock()
    }
    var stats: [String: Any] { ["polls": polls, "slow_polls": slow, "max_poll_ms": Int(maxMs)] }

    func spawn(every seconds: Double, _ body: @escaping () -> Void) {
        Thread {
            while !self.isStopped {
                let started = Date()
                body()
                self.record(started)
                Thread.sleep(forTimeInterval: seconds)
            }
            self.done.signal()
        }.start()
    }
    func finish() { stop(); _ = done.wait(timeout: .now() + 2) }
}

var lastFront = ""
var lastRunning: [String: Bool] = [:]
func pollWorkspace() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    if front != lastFront {
        lastFront = front
        emit("frontmost", ["bundle": front])
    }
    for bundle in targets {
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
        if lastRunning[bundle] != isRunning {
            lastRunning[bundle] = isRunning
            emit("target_running", ["bundle": bundle, "running": isRunning])
        }
    }
}

var lastWindows: [String: String] = [:]
var lastTexts: [String: [String]] = [:]
func pollTargets() {
    for bundle in targets {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
        let element = axApp(pid: app.processIdentifier)
        let windows = (attr(element, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let titles = windows.map { (attr($0, kAXTitleAttribute) as? String) ?? "" }
        let subroles = windows.map { (attr($0, kAXSubroleAttribute) as? String) ?? "" }
        var focusedTitle = ""
        if let focused = attr(element, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            focusedTitle = (attr(unsafeBitCast(focused, to: AXUIElement.self), kAXTitleAttribute) as? String) ?? ""
        }
        let signature = "\(titles)|\(subroles)|\(focusedTitle)"
        if lastWindows[bundle] != signature {
            lastWindows[bundle] = signature
            emit("target_windows", ["bundle": bundle, "count": windows.count, "titles": titles, "subroles": subroles, "focused": focusedTitle])
        }
        var texts: [String] = []
        for window in windows { collectTextAreas(window, depth: 8, into: &texts) }
        if lastTexts[bundle] != texts {
            lastTexts[bundle] = texts
            emit("target_text", ["bundle": bundle, "texts": texts.map { String($0.prefix(400)) }])
        }
    }
}

var lastHUD = ""
func pollHUD() {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: hudBundle).first?.processIdentifier else { return }
    var texts: [String] = []
    let element = axApp(pid: pid)
    for window in (attr(element, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { collectStaticText(window, depth: 12, into: &texts) }
    let joined = texts.joined(separator: " | ")
    if joined != lastHUD {
        lastHUD = joined
        emit("hud", ["text": String(joined.prefix(600))])
    }
}

let workspaceLoop = Loop("workspace"), targetLoop = Loop("targets"), hudLoop = Loop("hud")
func run(until deadline: Date) {
    while Date() < deadline {
        let tick = Date()
        pollWorkspace()
        workspaceLoop.record(tick)
        pump(until: tick.addingTimeInterval(0.01))
    }
}

emit("harness_start", [
    "audio_s": audioSeconds, "targets": targets, "out_device": outName,
    "lead_ms": Int(leadSeconds * 1000), "tail_ms": Int(tailSeconds * 1000),
    "output_latency_ms": Int(engine.outputNode.presentationLatency * 1000),
])
targetLoop.spawn(every: pollSeconds, pollTargets)
hudLoop.spawn(every: hudSeconds, pollHUD)
pollWorkspace()
pressHotkey()
emit("hotkey_start")
run(until: Date().addingTimeInterval(leadSeconds))

node.play()
emitLock.lock()
audioStart = Date()
emitLock.unlock()
emit("audio_play")
run(until: Date().addingTimeInterval(audioSeconds + tailSeconds))

targetLoop.finish()
hudLoop.finish()
emit("tail_done")
_ = readLine()
pressHotkey()
emit("hotkey_stop")
emit("poll_stats", ["workspace": workspaceLoop.stats, "targets": targetLoop.stats, "hud": hudLoop.stats])
