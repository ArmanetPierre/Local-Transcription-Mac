import Foundation

// Post-traitement de la transcription, identique a transcribe_bridge.py :
// attribution des intervenants mot par mot (lissee) et suppression des
// boucles d'hallucination de Whisper.

/// Un mot horodate
public struct Word: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Un tour de parole issu de la diarisation
public struct SpeakerTurn: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Un segment de transcription (avant ou apres attribution)
public struct TranscriptSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
    public var speaker: String?

    public init(start: Double, end: Double, text: String, words: [Word] = [], speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.speaker = speaker
    }
}

public enum PostProcessing {
    static let unknownSpeaker = "Inconnu"

    // MARK: - Boucles d'hallucination ("la la la...", "voila voila voila...")

    public static let maxRepeats = 3

    static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    /// Au-dela de maxRepeats occurrences consecutives d'un mot ou groupe de
    /// mots (jusqu'a 4), on n'en garde qu'une.
    public static func collapseRepetitions(_ words: [Word], maxNgram: Int = 4, maxRepeats: Int = maxRepeats) -> [Word] {
        var out = words
        for n in 1...maxNgram {
            var result: [Word] = []
            var i = 0
            while i < out.count {
                let gram = out[i..<min(i + n, out.count)].map { normalize($0.text) }
                var count = 1
                while i + (count + 1) * n <= out.count,
                      out[(i + count * n)..<(i + (count + 1) * n)].map({ normalize($0.text) }) == gram {
                    count += 1
                }
                if gram.count == n, gram.contains(where: { !$0.isEmpty }), count > maxRepeats {
                    result.append(contentsOf: out[i..<(i + n)])
                    i += count * n
                } else {
                    result.append(out[i])
                    i += 1
                }
            }
            out = result
        }
        return out
    }

    public static func removeHallucinationLoops(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            guard !segment.words.isEmpty else { return segment }
            let kept = collapseRepetitions(segment.words)
            guard kept.count < segment.words.count else { return segment }
            var copy = segment
            copy.words = kept
            copy.text = kept.map(\.text).joined()
            copy.end = kept.last?.end ?? segment.end
            return copy
        }
    }

    // MARK: - Intervenants parasites

    /// En dessous de ces deux seuils (temps de parole total), un "intervenant" est
    /// en general un fragment mal regroupe (bruit, rire, chevauchement).
    static let spuriousMaxSeconds = 8.0
    static let spuriousMaxShare = 0.03

    /// Un "intervenant" un peu plus long mais dont l'empreinte ne ressemble a aucun
    /// autre est un artefact : dans un meme enregistrement, de vraies voix differentes
    /// gardent une similarite de 0,2 a 0,35 (meme micro, meme piece).
    static let artifactMaxSeconds = 20.0
    static let artifactMaxSimilarity = 0.1

    /// Intervenants a retirer : tres peu de temps de parole, ou court et sans aucune
    /// ressemblance avec les autres voix. Les voix reconnues (keep) sont gardees.
    public static func spuriousSpeakers(
        _ turns: [SpeakerTurn],
        audioDuration: Double,
        embeddings: [String: [Double]] = [:],
        keep: Set<String> = []
    ) -> Set<String> {
        var speaking: [String: Double] = [:]
        for turn in turns { speaking[turn.speaker, default: 0] += turn.end - turn.start }
        guard speaking.count > 1 else { return [] }
        let total = speaking.values.reduce(0, +)
        let limit = min(spuriousMaxSeconds, max(total, audioDuration) * spuriousMaxShare)
        var spurious = Set(speaking.filter { $0.value < limit }.map(\.key))
        for (label, seconds) in speaking where seconds < artifactMaxSeconds {
            guard let embedding = embeddings[label] else { continue }
            let others = embeddings.filter { $0.key != label && speaking[$0.key] != nil }
            guard !others.isEmpty else { continue }
            let closest = others.values.map { VoiceMatcher.cosine(embedding, $0) }.max() ?? 1
            if closest < artifactMaxSimilarity { spurious.insert(label) }
        }
        spurious.subtract(keep)
        // Ne jamais tout retirer
        return spurious.count < speaking.count ? spurious : []
    }

    // MARK: - Attribution mot par mot

    static let minTurnWords = 3
    static let minTurnSeconds = 1.0
    static let snapWords = 2
    static let sentenceEnd: Set<Character> = [".", "?", "!", "…", ",", ";", ":"]

    /// Intervenant qui couvre le plus [start, end] ; sinon le tour le plus proche (a moins de maxGap s).
    static func speaker(at start: Double, _ end: Double, turns: [SpeakerTurn], maxGap: Double = 1.0) -> String? {
        var best: String?
        var bestOverlap = 0.0
        var nearest: String?
        var nearestGap = Double.infinity
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > bestOverlap {
                best = turn.speaker
                bestOverlap = overlap
            }
            let gap = max(turn.start - end, start - turn.end, 0)
            if gap < nearestGap {
                nearest = turn.speaker
                nearestGap = gap
            }
        }
        if let best { return best }
        return nearestGap <= maxGap ? nearest : nil
    }

    static func endsSentence(_ word: Word) -> Bool {
        guard let last = word.text.trimmingCharacters(in: .whitespaces).last else { return false }
        return sentenceEnd.contains(last)
    }

    /// Mots consecutifs du meme intervenant
    static func runs(_ labels: [String]) -> [(speaker: String, range: Range<Int>)] {
        var result: [(speaker: String, range: Range<Int>)] = []
        for (i, label) in labels.enumerated() {
            if let last = result.last, last.speaker == label {
                result[result.count - 1].range = last.range.lowerBound..<(i + 1)
            } else {
                result.append((label, i..<(i + 1)))
            }
        }
        return result
    }

    /// Supprime les micro-tours et recale les coupures sur la ponctuation.
    static func smooth(_ words: [Word], _ initial: [String]) -> [String] {
        var labels = initial
        // 1. Les tours trop courts rejoignent un voisin
        var changed = true
        while changed {
            changed = false
            let current = runs(labels)
            guard current.count > 1 else { break }
            for (i, run) in current.enumerated() {
                let duration = words[run.range.upperBound - 1].end - words[run.range.lowerBound].start
                guard run.range.count < minTurnWords || duration < minTurnSeconds else { continue }
                let prev = i > 0 ? current[i - 1] : nil
                let next = i + 1 < current.count ? current[i + 1] : nil
                let target: String
                if let prev, let next, prev.speaker == next.speaker {
                    target = prev.speaker
                } else if let prev, endsSentence(words[prev.range.upperBound - 1]) {
                    target = next?.speaker ?? prev.speaker   // phrase precedente finie : debut de la suivante
                } else if let prev {
                    target = prev.speaker                    // fin de la phrase de l'intervenant precedent
                } else {
                    target = next!.speaker
                }
                for j in run.range { labels[j] = target }
                changed = true
                break
            }
        }
        // 2. Recaler chaque coupure sur la ponctuation la plus proche
        var i = 1
        while i < labels.count {
            defer { i += 1 }
            guard labels[i] != labels[i - 1], !endsSentence(words[i - 1]) else { continue }
            for k in 1...snapWords {
                if i + k - 1 < words.count, endsSentence(words[i + k - 1]),
                   (i..<(i + k)).allSatisfy({ labels[$0] == labels[i] }) {
                    for j in i..<(i + k) { labels[j] = labels[i - 1] }
                    break
                }
                if i - k - 1 >= 0, endsSentence(words[i - k - 1]),
                   ((i - k)..<i).allSatisfy({ labels[$0] == labels[i - 1] }) {
                    for j in (i - k)..<i { labels[j] = labels[i] }
                    break
                }
            }
        }
        return labels
    }

    /// Attribue un intervenant a chaque mot, lisse, puis coupe les segments
    /// aux changements d'intervenant.
    public static func splitBySpeaker(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for segment in segments {
            let words = segment.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let fallback = speaker(at: segment.start, segment.end, turns: turns, maxGap: 5) ?? unknownSpeaker
            guard !words.isEmpty else {
                var copy = segment
                copy.speaker = fallback
                output.append(copy)
                continue
            }
            var labels: [String] = []
            for word in words {
                let found = speaker(at: word.start, word.end, turns: turns)
                labels.append(found ?? labels.last ?? fallback)
            }
            labels = smooth(words, labels)
            for run in runs(labels) {
                let runWords = Array(words[run.range])
                output.append(TranscriptSegment(
                    start: runWords.first!.start,
                    end: runWords.last!.end,
                    text: runWords.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                    words: runWords,
                    speaker: run.speaker
                ))
            }
        }
        return output.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
