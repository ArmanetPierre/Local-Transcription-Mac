import SwiftData

extension ModelContext {
    /// Sauvegarde explicite : l'autosave de SwiftData ne se declenche pas de facon
    /// fiable (ni la liste @Query ni la base n'etaient mises a jour apres une
    /// suppression ou un nouvel enregistrement).
    func saveLogged(_ reason: String) {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            print("[SwiftData] ERREUR sauvegarde (\(reason)): \(error)")
        }
    }
}
