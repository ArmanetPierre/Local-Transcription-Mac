import Foundation

struct SpeakerNameHistory {
    private static let key = "speaker_name_history"

    /// Tous les noms de speakers deja utilises, tries alphabetiquement
    static var allNames: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Ajoute de nouveaux noms a l'historique (ignore les doublons et les noms vides)
    static func addNames(_ names: [String]) {
        var existing = allNames
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !existing.contains(trimmed) {
                existing.append(trimmed)
            }
        }
        existing.sort()
        UserDefaults.standard.set(existing, forKey: key)
    }

    /// Retourne les noms correspondant a la requete (ou tous si requete vide)
    static func suggestions(for query: String) -> [String] {
        guard !query.isEmpty else { return allNames }
        return allNames.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}
