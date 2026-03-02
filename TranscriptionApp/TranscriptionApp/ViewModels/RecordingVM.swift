import Foundation
import SwiftData

@Observable
final class RecordingVM {
    let recordingService = RecordingService()

    /// Set by TranscriptionApp on appear (MenuBarExtra .menu style doesn't support @Environment)
    var modelContainer: ModelContainer?

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
            stopAndTranscribe(listVM: listVM)
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
                permissionAlertMessage = "L'acces au microphone est requis.\n\nAllez dans Reglages Systeme > Confidentialite et securite > Microphone et activez Voxa."
                return
            }

            if recordingService.systemAudioPermission == .denied {
                showPermissionAlert = true
                permissionAlertMessage = "La capture audio systeme est requise pour enregistrer les participants.\n\nAllez dans Reglages Systeme > Confidentialite et securite > Enregistrement de l'ecran et de l'audio systeme et activez Voxa."
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

    func stopAndTranscribe(listVM: TranscriptionListVM) {
        guard recordingService.isRecording else { return }
        guard let container = modelContainer else {
            print("[RecordingVM] ERREUR: ModelContainer non configure")
            return
        }

        Task { @MainActor in
            // Await merge completion — the file is guaranteed to exist after this
            guard let outputURL = await recordingService.stopRecording() else {
                print("[RecordingVM] Pas d'URL de sortie apres arret")
                return
            }

            let context = container.mainContext
            listVM.importFiles([outputURL], modelContext: context)
            print("[RecordingVM] Fichier envoye au pipeline de transcription: \(outputURL.lastPathComponent)")
        }
    }
}
