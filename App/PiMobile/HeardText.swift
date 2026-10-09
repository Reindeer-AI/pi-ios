/// The words of one dictation across iOS's recognition requests and transcriptions (`Dictation`): those done, and the
/// current one's, which iOS revises as it goes. An empty result never replaces them.
struct HeardText {
    /// What was typed before the dictation, ending in a space or a new line.
    let prefix: String
    private(set) var done = ""
    private(set) var current = ""

    init(after typed: String) {
        prefix = typed.isEmpty || typed.hasSuffix(" ") || typed.hasSuffix("\n") ? typed : typed + " "
    }

    var text: String { prefix + done + current }

    /// A result of the current request: the text to show, or nil when it changes nothing.
    mutating func received(_ words: String?) -> String? {
        guard let words, !words.isEmpty else { return nil }
        // After a pause iOS may start over: a shorter text that doesn't begin like the last one is a new transcription.
        if !current.isEmpty, words.count < current.count, Self.firstWord(words) != Self.firstWord(current) { keepCurrent() }
        current = words
        return text
    }

    /// The current request ended (its words stay); whether it had any.
    @discardableResult
    mutating func ended() -> Bool {
        let hadWords = !current.isEmpty
        keepCurrent()
        return hadWords
    }

    private mutating func keepCurrent() {
        guard !current.isEmpty else { return }
        done += current + " "
        current = ""
    }

    private static func firstWord(_ text: String) -> Substring {
        text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first ?? ""
    }
}
