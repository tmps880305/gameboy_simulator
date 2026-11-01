import AVFoundation

enum AudioCategoryOption: String, CaseIterable, Identifiable {
    /// Mixes with other audio and respects the silent switch.
    case ambient
    /// Interrupts other audio and ignores the silent switch.
    case playback

    var id: String { rawValue }

    var sessionCategory: AVAudioSession.Category {
        switch self {
        case .ambient: .ambient
        case .playback: .playback
        }
    }
}

/// Plays samples pulled from an `AudioRingBuffer` through `AVAudioSourceNode`.
final class AudioOutput {
    let ring: AudioRingBuffer
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var sourceNode: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []

    init(ring: AudioRingBuffer, sampleRate: Int) {
        self.ring = ring
        format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        engine.stop()
    }

    func start(category: AudioCategoryOption) {
        configureSession(category: category)
        if sourceNode == nil {
            installSourceNode()
            observeSystemEvents()
        }
        startEngine()
    }

    func stop() {
        engine.pause()
    }

    func setCategory(_ category: AudioCategoryOption) {
        configureSession(category: category)
        startEngine()
    }

    private func configureSession(category: AudioCategoryOption) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(category.sessionCategory, mode: .default)
            try session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)
        } catch {
            print("AudioOutput: failed to configure session: \(error)")
        }
    }

    private func installSourceNode() {
        let ring = ring
        // Real-time render block: no allocation, locks or blocking calls.
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let leftData = buffers[0].mData else { return noErr }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1
                ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left
                : left
            ring.read(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        sourceNode = node
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("AudioOutput: failed to start engine: \(error)")
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.startEngine()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.startEngine()
        })
    }
}
