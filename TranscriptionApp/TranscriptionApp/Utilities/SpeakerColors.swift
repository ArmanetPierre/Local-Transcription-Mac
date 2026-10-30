import SwiftUI

enum SpeakerColors {
    private static let palette: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .pink,
        .teal,
        .indigo,
        .mint,
        .brown,
        .cyan,
    ]

    /// Couleur stable pour un label de speaker : SPEAKER_00 → 1re couleur, SPEAKER_01 → 2e...
    /// Jusqu'a 10 intervenants, deux personnes n'ont jamais la meme couleur.
    /// (Avant : String.hashValue, tire au hasard a chaque lancement de l'app, d'ou des
    /// couleurs qui changeaient et des doublons frequents.)
    static func color(for speakerLabel: String) -> Color {
        palette[index(for: speakerLabel) % palette.count]
    }

    static func index(for speakerLabel: String) -> Int {
        if let number = speakerLabel.split(separator: "_").last.flatMap({ Int($0) }) {
            return number
        }
        // Autre libelle ("Inconnu"...) : empreinte FNV-1a, identique d'un lancement a l'autre
        var hash: UInt32 = 2_166_136_261
        for byte in speakerLabel.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(palette.count))
    }
}
