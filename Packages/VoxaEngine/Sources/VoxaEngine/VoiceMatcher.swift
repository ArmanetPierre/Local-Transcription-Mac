import Foundation

/// Reconnaissance des voix connues (base speaker_embeddings.json, formats v1 et v2),
/// identique a transcribe_bridge.py.
public enum VoiceMatcher {
    public static let defaultThreshold = 0.65

    /// Charge la base : {nom: [empreinte, ...]}
    public static func loadGallery(at path: String?) -> [String: [[Double]]] {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return parseGallery(json)
    }

    public static func parseGallery(_ json: Any) -> [String: [[Double]]] {
        guard let dict = json as? [String: Any] else { return [:] }
        if (dict["version"] as? Int) == 2 {
            let speakers = dict["speakers"] as? [String: [[String: Any]]] ?? [:]
            return speakers.mapValues { samples in
                samples.compactMap { ($0["embedding"] as? [NSNumber])?.map(\.doubleValue) }
            }
        }
        var gallery: [String: [[Double]]] = [:]
        for (name, value) in dict {
            if let vector = value as? [NSNumber] {
                gallery[name] = [vector.map(\.doubleValue)]
            } else if let vectors = value as? [[NSNumber]] {
                gallery[name] = vectors.map { $0.map(\.doubleValue) }
            }
        }
        return gallery
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Meilleur score de chaque personne connue pour chaque intervenant : {label: {nom: score}}
    public static func scores(_ embeddings: [String: [Double]], gallery: [String: [[Double]]]) -> [String: [String: Double]] {
        embeddings.mapValues { embedding in
            var byName: [String: Double] = [:]
            for (name, samples) in gallery {
                let usable = samples.filter { $0.count == embedding.count }
                if let best = usable.map({ cosine(embedding, $0) }).max() {
                    byName[name] = best
                }
            }
            return byName
        }
    }

    /// Appariement glouton (meilleur score d'abord, un nom par intervenant)
    public static func match(
        _ embeddings: [String: [Double]],
        gallery: [String: [[Double]]],
        threshold: Double = defaultThreshold
    ) -> (matches: [String: String], scores: [String: Double]) {
        var candidates: [(score: Double, label: String, name: String)] = []
        for (label, byName) in scores(embeddings, gallery: gallery) {
            for (name, score) in byName where score >= threshold {
                candidates.append((score, label, name))
            }
        }
        candidates.sort { ($0.score, $1.label, $1.name) > ($1.score, $0.label, $0.name) }
        var matches: [String: String] = [:]
        var matchScores: [String: Double] = [:]
        var usedNames = Set<String>()
        for candidate in candidates where matches[candidate.label] == nil && !usedNames.contains(candidate.name) {
            matches[candidate.label] = candidate.name
            matchScores[candidate.label] = (candidate.score * 1000).rounded() / 1000
            usedNames.insert(candidate.name)
        }
        return (matches, matchScores)
    }
}
