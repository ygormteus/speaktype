import Foundation

/// Word error rate on normalized text, used by the PT-BR benchmark.
///
/// WER = (substitutions + deletions + insertions) / reference word count,
/// computed with a word-level Levenshtein distance.
enum WordErrorRate {
    struct Result: Equatable {
        let errors: Int
        let referenceWords: Int

        var rate: Double {
            guard referenceWords > 0 else { return errors == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceWords)
        }
    }

    /// Lowercases, replaces punctuation/symbols with spaces and collapses
    /// whitespace. Accents are kept unless `foldingDiacritics` is true.
    /// Apostrophes/hyphens inside words ("d'água", "guarda-chuva") are split
    /// like any other punctuation so both sides tokenize identically.
    static func normalize(_ text: String, foldingDiacritics: Bool = false) -> String {
        var value = text.lowercased(with: Locale(identifier: "pt_BR"))
        if foldingDiacritics {
            value = value.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        }
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    static func words(_ text: String, foldingDiacritics: Bool = false) -> [String] {
        normalize(text, foldingDiacritics: foldingDiacritics)
            .split(separator: " ")
            .map(String.init)
    }

    /// Word-level Levenshtein distance between two token sequences.
    static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,  // deletion
                    current[j - 1] + 1,  // insertion
                    previous[j - 1] + cost  // substitution / match
                )
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }

    static func compute(
        reference: String, hypothesis: String, foldingDiacritics: Bool = false
    ) -> Result {
        let ref = words(reference, foldingDiacritics: foldingDiacritics)
        let hyp = words(hypothesis, foldingDiacritics: foldingDiacritics)
        return Result(errors: editDistance(ref, hyp), referenceWords: ref.count)
    }
}
