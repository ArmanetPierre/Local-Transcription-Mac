import Foundation
import SwiftData

@Observable
final class RecordingVM {
    let recordingService = RecordingService()

    /// Set by TranscriptionApp on appear (MenuBarExtra .menu style doesn't support @Environment)
    var modelContainer: ModelContainer?

    /// Arrets + imports en cours (attendus avant de quitter l'app)
    private var stopsInFlight = 0

    /// Alert state for permission issues
    var showPermissionAlert = false
    var permissionAlertMessage = ""

    // MARK: - Computed

    var formattedElapsedTime: String {
        let total = Int(recordingService.elapsedTime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    func toggleRecording(listVM: TranscriptionListVM) {
        if recordingService.isRecording {
            stopAndTranscribe(listVM: listVM, reason: "bascule")
        } else {
            startRecording()
        }
    }

    func startRecording() {
        Task { @MainActor in
            // Check permissions first
            await recordingService.checkPermissions()

            if recordingService.microphonePermission == .denied {
                showPermissionAlert = true
                permissionAlertMessage = String(localized: "Microphone access is required.\n\nGo to System Settings > Privacy & Security > Microphone and enable Voxa.")
                return
            }

            if recordingService.systemAudioPermission == .denied {
                showPermissionAlert = true
                permissionAlertMessage = String(localized: "System audio capture is required to record participants.\n\nGo to System Settings > Privacy & Security > Screen & System Audio Recording and enable Voxa.")
                return
            }

            do {
                try await recordingService.startRecording()
            } catch {
                recordingService.errorMessage = error.localizedDescription
                print("[RecordingVM] Erreur demarrage: \(error)")
            }
        }
    }

    /// - Parameter reason: origine de l'arret, ecrite dans le journal
    func stopAndTranscribe(listVM: TranscriptionListVM, reason: String) {
        guard recordingService.isRecording else { return }
        Task { @MainActor in await stopAndImport(listVM: listVM, reason: reason) }
    }

    @MainActor
    func stopAndImport(listVM: TranscriptionListVM, reason: String) async {
        stopsInFlight += 1
        defer { stopsInFlight -= 1 }
        let finished = await recordingService.stopRecording(reason: reason)
        await importFinished(finished, listVM: listVM)
    }

    /// Attend que tout enregistrement arrete soit finalise et importe.
    @MainActor
    func waitUntilIdle() async {
        while stopsInFlight > 0 || recordingService.isFinishing {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Branche l'arret automatique (disque plein) sur l'import.
    func configure(listVM: TranscriptionListVM) {
        recordingService.onAutoStop = { [weak self] finished in
            Task { @MainActor in await self?.importFinished(finished, listVM: listVM) }
        }
    }

    /// Recupere les enregistrements interrompus (plantage, app quittee pendant un enregistrement).
    @MainActor
    func recoverInterrupted(listVM: TranscriptionListVM) async {
        let recovered = await recordingService.recoverInterruptedSessions()
        for finished in recovered {
            await importFinished(finished, listVM: listVM)
        }
        if !recovered.isEmpty {
            recordingService.errorMessage = String(localized: "An interrupted recording was recovered and added to your transcriptions.")
        }
    }

    /// Importe le fichier final, puis seulement supprime le dossier de session.
    @MainActor
    private func importFinished(_ finished: FinishedRecording?, listVM: TranscriptionListVM) async {
        guard let finished else { return }
        guard let container = modelContainer else {
            print("[RecordingVM] ERREUR: ModelContainer non configure, session conservee")
            recordingService.release(finished)
            return
        }
        do {
            try await listVM.enqueue(finished.url, language: nil, modelContext: container.mainContext)
            recordingService.discard(finished)
            print("[RecordingVM] Enregistrement importe: \(finished.url.lastPathComponent)")
        } catch {
            // La session reste sur le disque : nouvelle tentative au prochain lancement
            print("[RecordingVM] ERREUR import \(finished.url.lastPathComponent): \(error)")
            recordingService.release(finished)
            recordingService.errorMessage = error.localizedDescription
        }
    }
}
