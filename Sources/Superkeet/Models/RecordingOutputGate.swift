struct RecordingOutputGate: Equatable {
    private(set) var isOpen = false

    mutating func open() {
        isOpen = true
    }

    mutating func close() {
        isOpen = false
    }
}
