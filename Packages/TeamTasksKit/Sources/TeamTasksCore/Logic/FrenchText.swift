import Foundation

/// French wording helpers of the v2 texts: guillemets, the elision of « de », first names, feminine ordinals and
/// counts. Every text follows the French typography of the app: the apostrophe ’ (U+2019) and a no-break space
/// (U+00A0) inside « » and before « ? ! : ; ». Pure.
public enum FrenchText {
    /// `«\u{00A0}text\u{00A0}»`: guillemets with a no-break space inside each of them.
    public static func quoted(_ text: String) -> String {
        "«\u{00A0}\(text)\u{00A0}»"
    }

    /// Lowercase vowels, accented or not, that make a preceding « de » elide.
    private static let vowels: Set<Character> = [
        "a", "à", "â", "ä", "e", "é", "è", "ê", "ë", "i", "î", "ï", "o", "ô", "ö", "u", "ù", "û", "ü", "œ", "æ",
    ]

    /// True when `word` starts with a vowel, accented or not, in any case (« Inès », « Élodie », « un ancien
    /// membre »). `h` and `y` are left out (« de Hugo », « de Yanis »): the app cannot tell a silent `h` from an
    /// aspirated one.
    public static func startsWithVowel(_ word: String) -> Bool {
        guard let first = word.first, let lowered = String(first).lowercased().first else { return false }
        return vowels.contains(lowered)
    }

    /// The form of « de » before `word`: « d’ » before a vowel (« d’Inès »), « de » and a space otherwise
    /// (« de Lucas »).
    public static func dePrefix(before word: String) -> String {
        startsWithVowel(word) ? "d’" : "de "
    }

    /// « de Lucas », « d’Inès », « d’un ancien membre ».
    public static func de(_ word: String) -> String {
        dePrefix(before: word) + word
    }

    /// The first name of a display name: its first word (« Camille Martin » → « Camille », « Jean-Pierre Durand » →
    /// « Jean-Pierre »), or the trimmed name when it has a single word.
    public static func firstName(of displayName: String) -> String {
        let trimmed = InputValidation.trimmed(displayName)
        return trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
    }

    /// Feminine ordinal of a place or a week: « 1re », « 2e », « 3e ».
    public static func ordinal(_ number: Int) -> String {
        number == 1 ? "1re" : "\(number)e"
    }

    /// A count and its noun: « 1 tâche », « 3 tâches ». As in French, 0 and 1 take the singular (« 0 tâche »).
    public static func count(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(isSingular(count) ? singular : plural)"
    }

    /// True when a count takes the singular in French (0 and 1).
    public static func isSingular(_ count: Int) -> Bool {
        count <= 1
    }
}

/// Initials of a name, as the avatars show them: the first letter or digit of the first two words (« Camille
/// Martin » → « CM », « Coloc’ rue des Lilas » → « CR », « Jean-Pierre » → « JP »), uppercased; « ? » when there is
/// none. Same rule as the app's `GroupsInitials`. Pure.
public enum Initials {
    /// Shown when a name has no letter nor digit, and for people the app does not know.
    public static let unknown = "?"

    public static func of(_ name: String, maxLetters: Int = 2) -> String {
        var letters: [Character] = []
        for word in name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }) {
            if let first = word.first(where: { $0.isLetter || $0.isNumber }) {
                letters.append(first)
            }
            if letters.count >= maxLetters { break }
        }
        let initials = String(letters).uppercased()
        return initials.isEmpty ? unknown : initials
    }
}

/// The short name of a group, for the small chips outside the group (« Mes tâches »): the whole name up to
/// `maxLength` characters; otherwise its first significant word (leading articles skipped: « Les copains du foot »
/// → « Copains »), with an uppercase first letter, shortened with « … » when it is still too long. « Coloc’ rue des
/// Lilas » → « Coloc’ ». Pure.
public enum GroupShortName {
    public static let maxLength = 14

    /// Words skipped at the start of a long name.
    static let leadingArticles: Set<String> = [
        "le", "la", "les", "un", "une", "des", "du", "de", "mon", "ma", "mes", "ton", "ta", "tes", "notre", "nos",
        "votre", "vos", "the", "a", "an",
    ]

    public static func of(_ name: String) -> String {
        let trimmed = InputValidation.trimmed(name)
        guard trimmed.count > maxLength else { return trimmed }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let word = words.first { !leadingArticles.contains($0.lowercased()) } ?? words.first ?? trimmed
        let short = FrenchDateFormatter.capitalizingFirstLetter(word)
        guard short.count > maxLength else { return short }
        return String(short.prefix(maxLength - 1)) + "…"
    }
}
