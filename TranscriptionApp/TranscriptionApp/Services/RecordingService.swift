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
    case diskFull

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let detail):
            String(localized: "Permission denied: \(detail)")
        case .noDisplayAvailable:
            String(localized: "No display available for system audio capture")
        case .audioEngineSetupFailed(let detail):
            String(localized: "Audio configuration error: \(detail)")
        case .fileCreationFailed(let detail):
            String(localized: "Unable to create recording file: \(detail)")
        case .mergeFailed(let detail):
            String(localized: "Audio merge error: \(detail)")
        case .diskFull:
            String(localized: "Not enough free disk space to record (at least 2 GB required).")
        }
    }
}

/// Enregistrement termine : fichier final verifie, dans le dossier de sa session.
/// Le dossier ne doit etre supprime (`RecordingService.discard`) qu'une fois le fichier importe.
struct FinishedRecording {
    let url: URL
    let sessionDirectory: URL
}

// MARK: - RecordingService

/// Enregistre l'audio systeme (ScreenCaptureKit) et le micro (AVAudioEngine).
///
/// Robustesse (un enregistrement de reunion ne se refait pas) :
/// - deux pistes PCM en CAF, lisibles meme apres un plantage, dans un dossier de session
///   persistant (Application Support/Voxa/Recordings/<date>/), recupere au lancement suivant ;
/// - pistes alignees sur l'horloge hote : un trou (source redemarree) devient du silence ;
/// - capture systeme et micro redemarrees automatiquement si macOS les interrompt
///   (veille, changement de peripherique audio) ou si elles se taisent ;
/// - a l'arret, mixage en .m4a (WAV en secours) verifie avant de supprimer quoi que ce soit.
///
/// Le micro passe par l'annulation d'echo d'Apple : sans elle, il reenregistre les
/// participants sortant des haut-parleurs, en double de la piste systeme.
@Observable
final class RecordingService: NSObject {
    // MARK: - Observable state

    var isRecording = false
    var elapsedTime: TimeInterval = 0
    var systemAudioPermission: RecordingPermissionStatus = .notDetermined
    var microphonePermission: RecordingPermissionStatus = .notDetermined
    var errorMessage: String?
    /// Vrai pendant le mixage final, apres l'arret
    var isFinishing = false

    /// Appele quand l'enregistrement s'arrete hors de l'app (disque presque plein,
    /// "Ne plus partager" dans l'indicateur de macOS) : le fichier doit etre importe
    @ObservationIgnored var onAutoStop: ((FinishedRecording?) -> Void)?

    // MARK: - Private

    @ObservationIgnored private var session: Session?
    /// Demarrage en cours (avant le premier await) : empeche deux sessions simultanees
    @ObservationIgnored private var isStarting = false
    /// Dossiers de session en cours d'utilisation (enregistrement, finalisation) :
    /// la recuperation au lancement ne doit jamais les toucher
    @ObservationIgnored private var busyDirectories = Set<URL>()
    /// Finalisations en cours (attendues avant de quitter l'app)
    @ObservationIgnored private var finishingTasks = 0
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var watchdogTimer: Timer?

    static let minimumFreeSpaceToStart: Int64 = 2_000_000_000
    static let minimumFreeSpaceWhileRecording: Int64 = 500_000_000
    /// Une source sans tampon depuis ce delai est redemarree
    static let silenceRestartDelay: TimeInterval = 8
    /// ScreenCaptureKit peut se taire quand rien ne joue : on ne relance la capture
    /// systeme qu'apres un long silence (ses vraies pannes passent par le delegue)
    static let systemSilenceRestartDelay: TimeInterval = 60

    /// Annulation d'echo sur le micro. Desactivable pour comparer :
    /// defaults write <bundle id> recording_echo_cancellation -bool NO
    private static var echoCancellationEnabled: Bool {
        UserDefaults.standard.object(forKey: "recording_echo_cancellation") as? Bool ?? true
    }

    /// Une session d'enregistrement : ses pistes et ses sources
    private final class Session {
        let directory: URL
        let name: String
        let startDate = Date()
        let hostStart: TimeInterval
        let system: AlignedTrackWriter
        let mic: AlignedTrackWriter
        var stream: SCStream?
        var filter: SCContentFilter?
        var engine: AVAudioEngine?
        var engineObserver: NSObjectProtocol?
        var lastSystemRestart: TimeInterval = 0
        var lastMicRestart: TimeInterval = 0
        var systemRestartInFlight = false
        var micRecoveryWork: DispatchWorkItem?
        var lastMicRebuild: TimeInterval = 0

        init(directory: URL, name: String, hostStart: TimeInterval) throws {
            self.directory = directory
            self.name = name
            self.hostStart = hostStart
            system = try AlignedTrackWriter(
                url: directory.appendingPathComponent("system.caf"), channels: 2, sessionStart: hostStart
            )
            mic = try AlignedTrackWriter(
                url: directory.appendingPathComponent("mic.caf"), channels: 1, sessionStart: hostStart
            )
        }
    }

    static var hostNow: TimeInterval {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }

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

    @MainActor
    func startRecording() async throws {
        guard !isRecording, !isStarting, session == nil else { return }
        isStarting = true
        defer { isStarting = false }

        if let free = Self.freeDiskSpace(), free < Self.minimumFreeSpaceToStart {
            throw RecordingError.diskFull
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecordingError.noDisplayAvailable
        }

        let name = "Recording_\(Self.timestamp())"
        // Suffixe unique : deux sessions ne partagent jamais un dossier
        let directory = AppPaths.recordingsDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .standardizedFileURL
        busyDirectories.insert(directory)
        let session: Session
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            session = try Session(directory: directory, name: name, hostStart: Self.hostNow)
        } catch {
            busyDirectories.remove(directory)
            throw RecordingError.fileCreationFailed(error.localizedDescription)
        }
        session.filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        do {
            try startMicrophone(session)
            try await startSystemCapture(session)
        } catch {
            stopSources(session)
            await Task.yield()
            if let stream = session.stream { try? await stream.stopCapture() }
            session.system.close()
            session.mic.close()
            try? FileManager.default.removeItem(at: directory)
            busyDirectories.remove(directory)
            throw error
        }

        self.session = session
        isRecording = true
        errorMessage = nil
        elapsedTime = 0
        startTimers()
        print("[RecordingService] Enregistrement demarre: \(directory.path)")
    }

    // MARK: - Stop Recording

    /// Arrete l'enregistrement, mixe les pistes et retourne le fichier final verifie.
    /// En cas d'echec, les pistes restent dans le dossier de session (recuperation au
    /// prochain lancement) et `errorMessage` l'explique.
    @MainActor
    func stopRecording(reason: String) async -> FinishedRecording? {
        guard let session else { return nil }
        self.session = nil
        isRecording = false
        isFinishing = true
        finishingTasks += 1
        defer {
            finishingTasks -= 1
            isFinishing = finishingTasks > 0
        }
        stopTimers()

        print("[RecordingService] Arret de l'enregistrement [\(reason)] (\(String(format: "%.1f", session.system.duration)) s systeme, \(String(format: "%.1f", session.mic.duration)) s micro)")
        stopSources(session)
        if let stream = session.stream {
            try? await stream.stopCapture()
        }
        session.system.close()
        session.mic.close()

        guard let finished = await Self.finish(sessionDirectory: session.directory, name: session.name) else {
            busyDirectories.remove(session.directory)
            errorMessage = String(localized: "The recording could not be finalized. Its tracks were kept and will be recovered at the next launch.")
            return nil
        }
        return finished
    }

    /// Supprime le dossier de session, une fois le fichier final importe.
    /// Le dossier reste "occupe" jusque-la : la recuperation ne peut pas l'importer une 2e fois.
    @MainActor
    func discard(_ recording: FinishedRecording) {
        defer { busyDirectories.remove(recording.sessionDirectory.standardizedFileURL) }
        do {
            try FileManager.default.removeItem(at: recording.sessionDirectory)
        } catch {
            print("[RecordingService] Impossible de supprimer \(recording.sessionDirectory.lastPathComponent): \(error)")
        }
    }

    /// Import echoue : la session est gardee pour le prochain lancement.
    @MainActor
    func release(_ recording: FinishedRecording) {
        busyDirectories.remove(recording.sessionDirectory.standardizedFileURL)
    }

    // MARK: - Recovery

    /// Sessions laissees par un enregistrement interrompu (plantage, app quittee, panne).
    /// Pour chacune, produit le fichier final ; l'appelant l'importe puis appelle `discard`.
    @MainActor
    func recoverInterruptedSessions() async -> [FinishedRecording] {
        let fm = FileManager.default
        let directories = ((try? fm.contentsOfDirectory(
            at: AppPaths.recordingsDirectory, includingPropertiesForKeys: nil
        )) ?? []).map(\.standardizedFileURL).filter { $0.hasDirectoryPath && !busyDirectories.contains($0) }

        var recovered: [FinishedRecording] = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // Un enregistrement a pu demarrer pendant la recuperation precedente
            guard !busyDirectories.contains(directory) else { continue }
            print("[RecordingService] Session interrompue trouvee: \(directory.lastPathComponent)")
            busyDirectories.insert(directory)
            if let finished = await Self.finish(sessionDirectory: directory, name: Self.sessionName(directory)) {
                recovered.append(finished)
            } else {
                busyDirectories.remove(directory)
            }
        }
        return recovered
    }

    /// Nom du fichier final : "Recording_<date>" (sans le suffixe unique du dossier)
    private static func sessionName(_ directory: URL) -> String {
        let folder = directory.lastPathComponent
        let parts = folder.split(separator: "_")
        // Recording_yyyy-MM-dd_HH-mm-ss_XXXXXXXX
        if parts.count == 4, parts[0] == "Recording" { return parts.dropLast().joined(separator: "_") }
        return folder
    }

    /// Attend la fin des finalisations en cours (avant de quitter l'app).
    @MainActor
    func waitForFinishing() async {
        while finishingTasks > 0 {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Produit (ou retrouve) le fichier final d'une session.
    private static func finish(sessionDirectory: URL, name: String) async -> FinishedRecording? {
        let fm = FileManager.default
        let tracks = ["system.caf", "mic.caf"].map { sessionDirectory.appendingPathComponent($0) }
        // Deja mixe lors d'une session precedente (import interrompu) ? Seulement s'il
        // est complet par rapport aux pistes (le mixage ecrit sous un nom temporaire,
        // mais on ne fait confiance a rien avant de supprimer les pistes)
        let expected = RecordingMixer.expectedDuration(of: tracks)
        for ext in ["m4a", "wav"] {
            let existing = sessionDirectory.appendingPathComponent("\(name).\(ext)")
            guard fm.fileExists(atPath: existing.path) else { continue }
            if (try? RecordingMixer.verify(existing, expected: expected)) != nil {
                return FinishedRecording(url: existing, sessionDirectory: sessionDirectory)
            }
            try? fm.removeItem(at: existing)
        }
        let output = sessionDirectory.appendingPathComponent("\(name).m4a")
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try RecordingMixer.mix(tracks: tracks, to: output)
            }.value
            return FinishedRecording(url: url, sessionDirectory: sessionDirectory)
        } catch {
            print("[RecordingService] ERREUR finalisation \(sessionDirectory.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Sources

    /// Demarre la capture systeme. Si la session a ete arretee pendant le demarrage,
    /// le flux est aussitot arrete (sinon il tournerait sans fin, attache a rien).
    @MainActor
    private func startSystemCapture(_ session: Session) async throws {
        guard let filter = session.filter else { throw RecordingError.noDisplayAvailable }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AlignedTrackWriter.sampleRate)
        config.channelCount = 2
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SystemAudioOutput(track: session.system)
        let queue = DispatchQueue(label: "com.pierre.Voxa.systemaudio", qos: .userInteractive)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
        // L'objet de sortie doit vivre aussi longtemps que le flux
        objc_setAssociatedObject(stream, &SystemAudioOutput.key, output, .OBJC_ASSOCIATION_RETAIN)
        try await stream.startCapture()
        // Session arretee entre-temps (hors demarrage initial, ou session vaut encore nil)
        if isRestart(session), self.session !== session {
            try? await stream.stopCapture()
            return
        }
        session.stream = stream
        session.lastSystemRestart = Self.hostNow
    }

    /// Execute un appel AVAudioEngine en interceptant aussi ses exceptions Objective-C
    /// (unite audio introuvable, format incompatible...), qui feraient planter l'app.
    static func guarded(_ label: String, _ block: () throws -> Void) throws {
        var swiftError: Error?
        var objcError: NSError?
        let ok = VoxaCatchObjCException({
            do { try block() } catch { swiftError = error }
        }, &objcError)
        if !ok, let objcError {
            print("[RecordingService] Exception audio (\(label)): \(objcError.localizedDescription)")
            throw RecordingError.audioEngineSetupFailed(objcError.localizedDescription)
        }
        if let swiftError { throw swiftError }
    }

    /// Demarre le micro avec l'annulation d'echo ; si macOS la refuse, sans elle :
    /// un micro avec un peu d'echo vaut mieux que pas de micro du tout.
    @MainActor
    private func startMicrophone(_ session: Session) throws {
        if Self.echoCancellationEnabled {
            do {
                try startMicrophone(session, voiceProcessing: true)
                return
            } catch {
                print("[RecordingService] Micro avec annulation d'echo impossible (\(error)), sans annulation")
            }
        }
        try startMicrophone(session, voiceProcessing: false)
    }

    @MainActor
    private func startMicrophone(_ session: Session, voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        if voiceProcessing {
            try Self.guarded("voice processing") {
                try inputNode.setVoiceProcessingEnabled(true)
                // Ne pas baisser le son de la reunion pendant l'enregistrement
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
                // Niveau stable pour Whisper
                inputNode.isVoiceProcessingAGCEnabled = false
            }
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[RecordingService] Micro: \(inputFormat), voice processing: \(inputNode.isVoiceProcessingEnabled)")
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw RecordingError.audioEngineSetupFailed(String(localized: "No microphone available"))
        }

        try Self.guarded("installTap") {
            Self.installMicTap(on: inputNode, format: inputFormat, track: session.mic)
        }

        // Changement de peripherique ou de format : le moteur s'arrete. Les notifications
        // arrivent en rafale (et le voice processing en provoque lui-meme une a chaque
        // demarrage) : on les regroupe avant d'agir, sinon le micro redemarre en boucle.
        session.engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak session] _ in
            guard let self, let session else { return }
            MainActor.assumeIsolated { self.scheduleMicRecovery(session) }
        }

        do {
            try Self.guarded("start") { try engine.start() }
        } catch {
            if let observer = session.engineObserver {
                NotificationCenter.default.removeObserver(observer)
                session.engineObserver = nil
            }
            try? Self.guarded("removeTap") { inputNode.removeTap(onBus: 0) }
            throw RecordingError.audioEngineSetupFailed(error.localizedDescription)
        }
        session.engine = engine
        session.lastMicRestart = Self.hostNow
        session.lastMicRebuild = Self.hostNow
    }

    private static func installMicTap(on inputNode: AVAudioInputNode, format: AVAudioFormat, track: AlignedTrackWriter) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let now = Self.hostNow
            let time = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : now
            track.write(buffer, bufferTime: time, arrivalHostTime: now)
        }
    }

    @MainActor
    private func scheduleMicRecovery(_ session: Session, delay: TimeInterval = 0.5) {
        session.micRecoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            MainActor.assumeIsolated { self.recoverMicrophone(session) }
        }
        session.micRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Apres un changement de configuration : relancer le meme moteur (le voice processing
    /// reste actif, pas de nouvelle notification), reconstruire seulement en dernier recours.
    @MainActor
    private func recoverMicrophone(_ session: Session) {
        guard self.session === session, let engine = session.engine else { return }
        if engine.isRunning {
            print("[RecordingService] Configuration audio modifiee, micro toujours actif : rien a faire")
            return
        }
        print("[RecordingService] Configuration audio modifiee : relance du micro")
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        try? Self.guarded("removeTap") { inputNode.removeTap(onBus: 0) }
        if format.channelCount > 0, format.sampleRate > 0 {
            do {
                try Self.guarded("installTap") {
                    Self.installMicTap(on: inputNode, format: format, track: session.mic)
                }
                try Self.guarded("start") { try engine.start() }
                session.lastMicRestart = Self.hostNow
                print("[RecordingService] Micro relance (meme moteur): \(format)")
                return
            } catch {
                print("[RecordingService] Relance du micro impossible: \(error)")
            }
        }
        // Reconstruction complete, au plus une fois toutes les 5 s
        let wait = 5 - (Self.hostNow - session.lastMicRebuild)
        if wait > 0 {
            scheduleMicRecovery(session, delay: wait)
        } else {
            restartMicrophone(session)
        }
    }

    @MainActor
    private func restartMicrophone(_ session: Session) {
        guard self.session === session else { return }
        session.micRecoveryWork?.cancel()
        stopMicrophone(session)
        do {
            try startMicrophone(session)
            print("[RecordingService] Micro redemarre")
        } catch {
            session.lastMicRestart = Self.hostNow
            session.lastMicRebuild = Self.hostNow
            print("[RecordingService] ERREUR redemarrage micro: \(error)")
        }
    }

    /// Vrai si la session a deja demarre (donc un redemarrage, pas le demarrage initial)
    private func isRestart(_ session: Session) -> Bool {
        session.lastSystemRestart > 0
    }

    @MainActor
    private func restartSystemCapture(_ session: Session) {
        guard self.session === session, !session.systemRestartInFlight else { return }
        session.systemRestartInFlight = true
        session.lastSystemRestart = Self.hostNow
        let old = session.stream
        session.stream = nil
        Task { @MainActor in
            defer { session.systemRestartInFlight = false }
            try? await old?.stopCapture()
            guard self.session === session else { return }
            do {
                try await startSystemCapture(session)
                print("[RecordingService] Capture systeme redemarree")
            } catch {
                print("[RecordingService] ERREUR redemarrage capture systeme: \(error)")
            }
        }
    }

    private func stopMicrophone(_ session: Session) {
        session.micRecoveryWork?.cancel()
        session.micRecoveryWork = nil
        if let observer = session.engineObserver {
            NotificationCenter.default.removeObserver(observer)
            session.engineObserver = nil
        }
        if let engine = session.engine {
            try? Self.guarded("arret micro") {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        session.engine = nil
    }

    private func stopSources(_ session: Session) {
        stopMicrophone(session)
    }

    // MARK: - Timers

    @MainActor
    private func startTimers() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.elapsedTime = Date().timeIntervalSince(session.startDate)
            }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdog() }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Relance une source muette et arrete proprement si le disque se remplit.
    @MainActor
    private func watchdog() {
        guard let session else { return }
        let now = Self.hostNow

        let lastMic = max(session.mic.lastCallbackHostTime ?? session.hostStart, session.lastMicRestart)
        if now - lastMic > Self.silenceRestartDelay {
            print("[RecordingService] Micro muet depuis \(Int(now - lastMic)) s : redemarrage")
            restartMicrophone(session)
        }
        let lastSystem = max(session.system.lastCallbackHostTime ?? session.hostStart, session.lastSystemRestart)
        if now - lastSystem > Self.systemSilenceRestartDelay, !session.systemRestartInFlight {
            print("[RecordingService] Capture systeme muette depuis \(Int(now - lastSystem)) s : redemarrage")
            restartSystemCapture(session)
        }

        if let free = Self.freeDiskSpace(), free < Self.minimumFreeSpaceWhileRecording {
            print("[RecordingService] Disque presque plein (\(free / 1_000_000) Mo) : arret de l'enregistrement")
            Task { @MainActor in
                let finished = await stopRecording(reason: "disque presque plein")
                errorMessage = String(localized: "The recording was stopped because the disk is almost full.")
                onAutoStop?(finished)
            }
        }
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    static func freeDiskSpace() -> Int64? {
        let values = try? AppPaths.recordingsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - SCStreamDelegate

extension RecordingService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        // "Ne plus partager" dans l'indicateur de capture de macOS (barre des menus) :
        // c'est l'utilisateur qui arrete, on termine l'enregistrement au lieu de relancer
        let stoppedByUser = nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userStopped.rawValue
        print("[RecordingService] Capture systeme \(stoppedByUser ? "arretee par l'utilisateur (indicateur macOS)" : "interrompue par macOS"): \(error)")
        Task { @MainActor in
            guard let session = self.session, session.stream === stream else { return }
            if stoppedByUser {
                let finished = await self.stopRecording(reason: "Ne plus partager (indicateur macOS)")
                self.onAutoStop?(finished)
            } else {
                self.restartSystemCapture(session)
            }
        }
    }
}

// MARK: - System audio output

/// Recoit l'audio systeme de ScreenCaptureKit et l'ecrit dans la piste systeme.
private final class SystemAudioOutput: NSObject, SCStreamOutput {
    static var key: UInt8 = 0
    let track: AlignedTrackWriter

    init(track: AlignedTrackWriter) {
        self.track = track
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let buffer = AVAudioPCMBuffer.from(sampleBuffer) else { return }
        let now = RecordingService.hostNow
        let pts = sampleBuffer.presentationTimeStamp
        let time = pts.isValid ? pts.seconds : now
        track.write(buffer, bufferTime: time, arrivalHostTime: now)
    }
}
