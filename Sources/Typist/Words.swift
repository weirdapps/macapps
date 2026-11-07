import Foundation

// The embedded practice material: common English words and public-domain quotes.

enum Words {
    /// Two hundred of the most common English words, the usual material for a typing test.
    static let common: [String] = """
    the be of and a to in he have it that for they with as not on she at by this we you do but from or which one \
    would all will there say who make when can more if no man out other so what time up go about than into could \
    state only new year some take come these know see use get like then first any work now may such give over think \
    most even find day also after way many must look before great back through long where much should well people \
    down own just because good each those feel seem how high too place little world very still nation hand old life \
    tell write become here show house both between need mean call develop under last right move thing general school \
    never same another begin while number part turn real leave might want point form off child few small since against \
    ask late home interest large person end open public follow during present without again hold govern around \
    possible head consider word program problem however lead system set order eye plan run keep face fact group play \
    stand increase early course change help line city put close case force meet once water upon war build hear light \
    unite live every country bring center let side try provide continue name certain power pay result question study \
    woman member until far night always service away report something company week church toward start social room \
    figure nature though young less enough almost read include president nothing yet better big boy cost business
    """.split(separator: " ").map(String.init)

    struct Quote: Equatable {
        let text: String
        let author: String
    }

    /// Short passages by authors whose work is in the public domain.
    static let quotes: [Quote] = [
        Quote(text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.", author: "Jane Austen"),
        Quote(text: "There is no charm equal to tenderness of heart.", author: "Jane Austen"),
        Quote(text: "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness.", author: "Charles Dickens"),
        Quote(text: "We are all in the gutter, but some of us are looking at the stars.", author: "Oscar Wilde"),
        Quote(text: "To live is the rarest thing in the world. Most people exist, that is all.", author: "Oscar Wilde"),
        Quote(text: "There is nothing either good or bad, but thinking makes it so.", author: "William Shakespeare"),
        Quote(text: "All the world's a stage, and all the men and women merely players; they have their exits and their entrances.", author: "William Shakespeare"),
        Quote(text: "All happy families are alike; each unhappy family is unhappy in its own way.", author: "Leo Tolstoy"),
        Quote(text: "If one advances confidently in the direction of his dreams, and endeavors to live the life which he has imagined, he will meet with a success unexpected in common hours.", author: "Henry David Thoreau"),
        Quote(text: "I went to the woods because I wished to live deliberately, to front only the essential facts of life.", author: "Henry David Thoreau"),
        Quote(text: "It is not the critic who counts; not the man who points out how the strong man stumbles, or where the doer of deeds could have done them better.", author: "Theodore Roosevelt"),
        Quote(text: "Call me Ishmael. Some years ago, never mind how long precisely, having little or no money in my purse, I thought I would sail about a little and see the watery part of the world.", author: "Herman Melville"),
        Quote(text: "Hope is the thing with feathers that perches in the soul, and sings the tune without the words, and never stops at all.", author: "Emily Dickinson"),
        Quote(text: "Two roads diverged in a wood, and I, I took the one less traveled by, and that has made all the difference.", author: "Robert Frost"),
        Quote(text: "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.", author: "Lewis Carroll"),
        Quote(text: "I am no bird; and no net ensnares me: I am a free human being with an independent will.", author: "Charlotte Bronte"),
        Quote(text: "Deep into that darkness peering, long I stood there wondering, fearing, doubting, dreaming dreams no mortal ever dared to dream before.", author: "Edgar Allan Poe"),
        Quote(text: "You see, but you do not observe. The distinction is clear.", author: "Arthur Conan Doyle"),
        Quote(text: "No one would have believed in the last years of the nineteenth century that this world was being watched keenly and closely by intelligences greater than man's.", author: "H. G. Wells"),
        Quote(text: "I celebrate myself, and sing myself, and what I assume you shall assume.", author: "Walt Whitman"),
        Quote(text: "So we beat on, boats against the current, borne back ceaselessly into the past.", author: "F. Scott Fitzgerald"),
        Quote(text: "The fault, dear Brutus, is not in our stars, but in ourselves, that we are underlings.", author: "William Shakespeare"),
        Quote(text: "Fifteen men on the dead man's chest, yo ho ho, and a bottle of rum!", author: "Robert Louis Stevenson"),
        Quote(text: "Genius is one per cent inspiration and ninety-nine per cent perspiration.", author: "Thomas Edison"),
        Quote(text: "A journey of a thousand miles begins with a single step.", author: "Lao Tzu"),
        Quote(text: "Nothing great was ever achieved without enthusiasm.", author: "Ralph Waldo Emerson"),
        Quote(text: "Well done is better than well said.", author: "Benjamin Franklin"),
        Quote(text: "Whenever you find yourself on the side of the majority, it is time to pause and reflect.", author: "Mark Twain"),
    ]
}

/// A small seedable generator, so tests and the website snapshot get the same text every time.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum TextGenerator {
    /// `count` practice words, optionally with numbers mixed in and sentence punctuation.
    static func words<R: RandomNumberGenerator>(_ count: Int, punctuation: Bool, numbers: Bool, using rng: inout R) -> [String] {
        var out: [String] = []
        var capitalise = punctuation
        var previous = ""
        for i in 0..<max(0, count) {
            var word: String
            if numbers, Int.random(in: 0..<100, using: &rng) < 12 {
                word = String(Int.random(in: 1...(Int.random(in: 0..<3, using: &rng) == 0 ? 9999 : 99), using: &rng))
            } else {
                repeat { word = Words.common.randomElement(using: &rng)! } while word == previous
            }
            previous = word
            if punctuation {
                if capitalise { word = word.prefix(1).uppercased() + word.dropFirst(); capitalise = false }
                let isLast = i == count - 1
                switch Int.random(in: 0..<100, using: &rng) {
                case _ where isLast: word += "."
                case 0..<8: word += "."; capitalise = true
                case 8..<16: word += ","
                case 16..<18: word += "?"; capitalise = true
                case 18..<19: word += "!"; capitalise = true
                case 19..<21: word += ";"
                case 21..<22: word += ":"
                case 22..<25: word = "\"" + word + "\""
                case 25..<27: word = "(" + word + ")"
                case 27..<28: if word.count > 2 { word += "'s" }
                default: break
                }
            }
            out.append(word)
        }
        return out
    }
}
