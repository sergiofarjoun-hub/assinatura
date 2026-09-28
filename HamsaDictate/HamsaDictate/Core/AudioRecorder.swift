import AudioToolbox
import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "Nenhum dispositivo de entrada de áudio disponível."
        case .converterUnavailable:
            return "Não foi possível converter o áudio para 16 kHz mono."
        }
    }
}

/// Grava do input escolhido (ou padrão do sistema) via AVAudioEngine e
/// acumula amostras já convertidas para 16 kHz mono Float32 — o formato
/// nativo do Whisper.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private let bufferQueue = DispatchQueue(label: "com.hamsa.dictate.audio")
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var maxDurationNotified = false

    private(set) var isRecording = false

    var maxDuration: TimeInterval = 120
    /// UID CoreAudio do dispositivo preferido; nil/vazio = padrão do sistema.
    /// Aplicado no próximo `start()`.
    var preferredDeviceUID: String?
    /// Chamado (na main queue, uma única vez por gravação) ao atingir o limite.
    var onMaxDurationReached: (() -> Void)?
    /// Chamado (na main queue) quando o device de entrada muda no meio da gravação.
    var onConfigurationChange: (() -> Void)?
    /// Nível RMS (0…1) de cada buffer convertido, na main queue — alimenta o waveform.
    var onLevel: ((Float) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.onConfigurationChange?()
        }
    }

    func start() throws {
        guard !isRecording else { return }

        applyPreferredDeviceIfNeeded()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }

        bufferQueue.sync {
            self.samples.removeAll(keepingCapacity: true)
            self.converter = converter
            self.maxDurationNotified = false
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.bufferQueue.async {
                self?.append(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Para a gravação e retorna as amostras acumuladas (16 kHz mono).
    func stop() -> [Float] {
        guard isRecording else { return [] }
        tearDownEngine()
        return bufferQueue.sync {
            let result = samples
            samples.removeAll()
            return result
        }
    }

    /// Para a gravação descartando o áudio (ex.: device mudou no meio).
    func cancel() {
        guard isRecording else { return }
        tearDownEngine()
        bufferQueue.sync { samples.removeAll() }
    }

    private func tearDownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    /// Redireciona o inputNode para o device escolhido nas Settings.
    /// Falha silenciosa = permanece no padrão do sistema (ex.: device desconectado).
    private func applyPreferredDeviceIfNeeded() {
        guard let uid = preferredDeviceUID, !uid.isEmpty,
              let resolvedID = AudioDeviceManager.deviceID(forUID: uid),
              let audioUnit = engine.inputNode.audioUnit
        else { return }

        var deviceID = resolvedID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, let channel = output.floatChannelData?[0] else { return }
        let frameCount = Int(output.frameLength)
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))

        if let onLevel, frameCount > 0 {
            var sumOfSquares: Float = 0
            for index in 0..<frameCount {
                let sample = channel[index]
                sumOfSquares += sample * sample
            }
            let rms = (sumOfSquares / Float(frameCount)).squareRoot()
            DispatchQueue.main.async { onLevel(rms) }
        }

        if !maxDurationNotified,
           Double(samples.count) / Self.targetSampleRate >= maxDuration {
            maxDurationNotified = true
            DispatchQueue.main.async { [weak self] in
                self?.onMaxDurationReached?()
            }
        }
    }

    /// Detecção simples de silêncio por RMS — evita "transcrições fantasma"
    /// quando o usuário toca o hotkey sem falar nada.
    static func isSilence(_ samples: [Float], threshold: Float = 0.0025) -> Bool {
        guard !samples.isEmpty else { return true }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        return rms < threshold
    }
}
