import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Types

enum RecordingPermissionStatus {
    case notDetermined
    case granted
    case denied
}

enum RecordingError: LocalizedError {
    case permissionDenied(String)
    case noDisplayAvailable
    case audioEngineSetupFailed(String)
    case fileCreationFailed(String)
    case mergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let detail):
            "Permission refusee: \(detail)"
        case .noDisplayAvailable:
            "Aucun ecran disponible pour la capture audio systeme"
        case .audioEngineSetupFailed(let detail):
            "Erreur de configuration audio: \(detail)"
        case .fileCreationFailed(let detail):
            "Impossible de creer le fichier d'enregistrement: \(detail)"
        case .mergeFailed(let detail):
            "Erreur lors de la fusion audio: \(detail)"
        }
    }
}

// MARK: - RecordingService

/// Enregistre l'audio systeme (ScreenCaptureKit) et le micro (AVAudioEngine)
/// dans deux fichiers separes, puis les fusionne a l'arret.
///
/// Architecture sans echo :
/// - SCStream → CMSampleBuffer → AVAssetWriter (temp_system.m4a)
/// - AVAudioEngine.inputNode → tap → AVAudioFile (temp_mic.wav)
/// - stopRecording() → AVMutableComposition merge → Recording_xxx.m4a
///
/// L'audio systeme n'est PAS rejoue dans l'engine (pas de PlayerNode),
/// donc pas de doublement du son dans les haut-parleurs.
@Observable
final class RecordingService: NSObject {
    // MARK: - Observable state

    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var systemAudioPermission: RecordingPermissionStatus = .notDetermined
    var microphonePermission: RecordingPermissionStatus = .notDetermined
    var errorMessage: String?

    // MARK: - Private

    // System audio capture (ScreenCaptureKit)
    private var scStream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var systemAudioTempURL: URL?

    // Microphone capture (AVAudioEngine)
    private var audioEngine: AVAudioEngine?
    private var micTempURL: URL?
    private var micFile: AVAudioFile?

    // Output
    private var outputURL: URL?
    private var elapsedTimer: Timer?
    private var recordingStartTime: Date?

    // Thread safety
    private let writeLock = NSLock()
    private var isWriterStarted = false

    // MARK: - Permission Checking

    func checkPermissions() async {
        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphonePermission = granted ? .granted : .denied
            }
        case .denied, .restricted:
            microphonePermission = .denied
        @unknown default:
            microphonePermission = .notDetermined
        }

        // System audio (ScreenCaptureKit)
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                systemAudioPermission = .granted
            }
        } catch {
            await MainActor.run {
                systemAudioPermission = .denied
            }
        }
    }

    // MARK: - Start Recording

    func startRecording() async throws {
        guard !isRecording else { return }

        // 1. Get display for system audio capture
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }

        // 2. Prepare temp file paths
        let tempDir = FileManager.default.temporaryDirectory
        let sessionID = UUID().uuidString.prefix(8)
        let systemTempURL = tempDir.appendingPathComponent("rec_system_\(sessionID).m4a")
        let micTempURL = tempDir.appendingPathComponent("rec_mic_\(sessionID).wav")
        self.systemAudioTempURL = systemTempURL
        self.micTempURL = micTempURL

        // Clean up any existing temp files
        try? FileManager.default.removeItem(at: systemTempURL)
        try? FileManager.default.removeItem(at: micTempURL)

        // 3. Configure AVAssetWriter for system audio
        let writer = try AVAssetWriter(outputURL: systemTempURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        writerInput.expectsMediaDataInRealTime = true
        writer.add(writerInput)
        self.assetWriter = writer
        self.assetWriterInput = writerInput
        self.isWriterStarted = false

        // 4. Configure SCStream (audio-only, minimal video)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let audioQueue = DispatchQueue(label: "com.pierre.Voxa.systemaudio", qos: .userInteractive)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        self.scStream = stream

        // 5. Configure AVAudioEngine for microphone only (NO playerNode = no echo)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create mic output file (WAV for lossless temp storage)
        let micOutputFile = try AVAudioFile(
            forWriting: micTempURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: inputFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        self.micFile = micOutputFile

        // Install tap on inputNode to capture microphone directly
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.writeLock.lock()
            defer { self.writeLock.unlock() }
            do {
                try self.micFile?.write(from: buffer)
            } catch {
                print("[RecordingService] Erreur ecriture micro: \(error)")
            }
        }

        self.audioEngine = engine

        // 6. Start everything
        do {
            try engine.start()
        } catch {
            throw RecordingError.audioEngineSetupFailed(error.localizedDescription)
        }

        try await stream.startCapture()

        // Prepare the final output URL
        let finalURL = try createFinalOutputURL()
        self.outputURL = finalURL

        // 7. Update state
        await MainActor.run {
            self.isRecording = true
            self.errorMessage = nil
            self.recordingStartTime = Date()
            self.elapsedTime = 0
            self.startElapsedTimer()
        }

        print("[RecordingService] Enregistrement demarre (2 pistes separees)")
    }

    // MARK: - Stop Recording

    /// Arrete l'enregistrement, fusionne les deux pistes, retourne l'URL du fichier final.
    /// L'arret des sources est immediat, puis la methode attend la fin de la fusion
    /// avant de retourner l'URL (le fichier est garanti d'exister au retour).
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        print("[RecordingService] Arret de l'enregistrement...")

        // 1. Stop SCStream
        let stream = scStream
        scStream = nil

        // 2. Finish system audio writer
        assetWriterInput?.markAsFinished()
        let writer = assetWriter
        assetWriter = nil
        assetWriterInput = nil

        // 3. Stop microphone
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        writeLock.lock()
        micFile = nil // Close mic file
        writeLock.unlock()

        // 4. Update state immediately (UI reacts right away)
        await MainActor.run {
            isRecording = false
            stopElapsedTimer()
        }

        let finalURL = outputURL
        outputURL = nil

        let systemURL = systemAudioTempURL
        let micURL = micTempURL
        systemAudioTempURL = nil
        micTempURL = nil

        // 5. Async: stop stream capture
        try? await stream?.stopCapture()

        // 6. Async: wait for writer to finish
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }

        // 7. Async: merge the two tracks (file exists only after this completes)
        guard let finalURL, let systemURL, let micURL else { return finalURL }
        do {
            try await Self.mergeTracks(systemURL: systemURL, micURL: micURL, outputURL: finalURL)
            print("[RecordingService] Fusion terminee: \(finalURL.lastPathComponent)")

            // Clean up temp files
            try? FileManager.default.removeItem(at: systemURL)
            try? FileManager.default.removeItem(at: micURL)
        } catch {
            print("[RecordingService] Erreur fusion: \(error)")
            // Fallback: use system audio file directly
            try? FileManager.default.moveItem(at: systemURL, to: finalURL)
            try? FileManager.default.removeItem(at: micURL)
        }

        return finalURL
    }

    // MARK: - Audio Merging

    /// Fusionne deux fichiers audio en un seul avec AVMutableComposition.
    /// Les deux pistes sont superposees (pas concatenees).
    private static func mergeTracks(systemURL: URL, micURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()

        // Add system audio track
        let systemAsset = AVURLAsset(url: systemURL)
        let systemDuration = try await systemAsset.load(.duration)
        if let systemAudioTrack = try await systemAsset.loadTracks(withMediaType: .audio).first {
            let compositionSystemTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try compositionSystemTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: systemDuration),
                of: systemAudioTrack,
                at: .zero
            )
        }

        // Add microphone track
        let micAsset = AVURLAsset(url: micURL)
        let micDuration = try await micAsset.load(.duration)
        if let micAudioTrack = try await micAsset.loadTracks(withMediaType: .audio).first {
            let compositionMicTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            )
            try compositionMicTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: micDuration),
                of: micAudioTrack,
                at: .zero
            )
        }

        // Export merged composition
        guard let exportSession = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecordingError.mergeFailed("Impossible de creer l'export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        if let error = exportSession.error {
            throw RecordingError.mergeFailed(error.localizedDescription)
        }

        guard exportSession.status == .completed else {
            throw RecordingError.mergeFailed("Export status: \(exportSession.status.rawValue)")
        }
    }

    // MARK: - Helpers

    private static var audioStorageDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let audioDir = appSupport
            .appendingPathComponent("Voxa", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        return audioDir
    }

    private func createFinalOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let fileName = "Recording_\(timestamp).m4a"
        return Self.audioStorageDirectory.appendingPathComponent(fileName)
    }

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartTime = nil
    }
}

// MARK: - SCStreamOutput (System Audio → AVAssetWriter)

extension RecordingService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard let writer = assetWriter, let input = assetWriterInput else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // Start writer on first sample
        if !isWriterStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
            isWriterStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}
