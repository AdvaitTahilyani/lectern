import Foundation

/// Everyday English words, used by `TranscriptCorrector` to decide whether a phrase reads as
/// ordinary English (and so must be left alone).
///
/// Hand-curated from high-frequency spoken English plus the plain words lecturers use all the
/// time ("register", "table", "node"). Deliberately excludes the clipped jargon a recognizer
/// produces when it mishears an identifier ("gen", "reg", "expr", "idx", "cfg"), which the
/// system dictionary (`/usr/share/dict/web2`) would wrongly accept.
enum CommonWords {
    /// True for common words and their regular inflections ("loads", "loading", "tables").
    static func contains(_ word: String) -> Bool {
        let w = word.lowercased()
        if set.contains(w) { return true }
        for (suffix, replacements) in inflections where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            let stem = String(w.dropLast(suffix.count))
            for r in replacements where set.contains(stem + r) { return true }
        }
        return false
    }

    /// Suffix → what may replace it to reach the base form.
    private static let inflections: [(String, [String])] = [
        ("'s", [""]), ("ies", ["y"]), ("es", ["", "e"]), ("s", [""]),
        ("ied", ["y"]), ("ed", ["", "e"]), ("ing", ["", "e"]), ("ly", [""]), ("er", ["", "e"]), ("est", ["", "e"]),
    ]

    static let set: Set<String> = Set(list.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let list = """
    a i an the this that these those there here where when what which who whom whose why how
    and or but nor so yet if then else than because since while until unless although though whether
    as at by for from in into of off on onto out over to up upon with within without about above
    across after against along among around before behind below beneath beside between beyond down
    during except inside near outside past through throughout toward towards under underneath via
    am is are was were be been being have has had having do does did doing done
    can could will would shall should may might must ought need dare
    it its it's i'm you're we're they're he's she's that's there's what's let's don't doesn't didn't
    isn't aren't wasn't weren't can't cannot couldn't won't wouldn't shouldn't haven't hasn't hadn't
    i'll you'll we'll they'll i've you've we've they've i'd you'd we'd they'd
    me my mine myself you your yours yourself yourselves he him his himself she her hers herself
    we us our ours ourselves they them their theirs themselves one ones someone anyone everyone
    no not none nothing something anything everything nobody somebody anybody everybody
    all any each every both either neither few many much more most less least lot lots some such
    own same other another else enough several whole half
    yes yeah yep okay ok oh uh um hmm ah well right sure alright hey hi hello bye thanks please sorry
    just only also even still already again almost always never ever often sometimes usually
    really very quite rather pretty too maybe perhaps actually basically essentially probably
    exactly simply mostly nearly certainly definitely obviously clearly generally typically
    now today tomorrow yesterday soon later early late once twice ago away back forward together
    apart instead otherwise anyway however therefore thus hence meanwhile also like unlike
    zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen
    sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety
    hundred thousand million billion first second third fourth fifth sixth seventh eighth ninth tenth
    last next previous final initial single double triple
    go goes went gone going get got gotten give gave given take took taken make made come came
    see saw seen look looked watch know knew known think thought say said tell told ask asked
    answer use used using want wanted try tried call called work worked seem seemed feel felt
    leave left put keep kept let begin began begun start started stop stopped show showed shown
    hear heard play run ran move moved live lived believe bring brought happen happened write
    wrote written read provide sit sat stand stood lose lost pay paid meet met include included
    continue continued set learn learned change changed lead led understand understood follow
    followed create created speak spoke spoken allow allowed add added spend spent grow grew
    open opened walk walked win won offer offered remember remembered love consider considered
    appear appeared buy bought wait waited serve die send sent expect expected build built stay
    fall fell cut reach reached kill remain remained suggest suggested raise raised pass passed
    sell sold require required report decide decided pull pulled break broke broken fix fixed
    find found mean meant need needed turn turned help helped carry carried hold held
    close closed choose chose chosen compare compared compute computed check checked return
    returned store stored load loaded save saved print printed define defined declare declared
    assign assigned replace replaced remove removed insert inserted delete deleted evaluate
    evaluated generate generated translate translated convert converted represent represented
    implement implemented execute executed emit emitted produce produced apply applied push
    pushed pop popped jump jumped branch branched lock locked unlock hide pick picked drop
    dropped fill filled match matched point pointed count counted handle handled access
    accessed allocate allocated optimize optimized simplify simplified reduce reduced solve
    solved prove proved proven assume assumed guess guessed care cared mind wonder wondered
    agree agreed explain explained discuss discussed mention mentioned finish finished post
    posted grade graded submit submitted release released cover covered skip skipped miss
    missed test tested debug debugged trace traced parse parsed scan scanned sort sorted
    search searched merge merged split join joined link linked walk traverse traversed visit
    visited mark marked label labeled labelled name named type typed
    good better best bad worse worst great big bigger biggest small smaller smallest large larger
    largest little long longer longest short shorter high higher low lower old new young
    easy easier hard harder simple complex complicated important different similar special
    general specific particular certain possible impossible true false real correct wrong
    free full empty whole open closed clear fast slow quick early late sure able available
    local global public private static dynamic basic main common normal regular natural
    left right top bottom front middle inner outer upper lower early nice fine cool interesting
    useful useless efficient valid invalid explicit implicit unique extra entire
    time times year years day days week weeks month months hour hours minute minutes moment
    way ways thing things people person man men woman women child children kid kids student
    students professor teacher class classes course courses lecture lectures lab labs
    homework assignment assignments exam exams midterm quiz quizzes question questions problem
    problems example examples case cases point points part parts place places group groups
    number numbers world life hand hands eye eyes head face fact facts idea ideas word words
    line lines page pages slide slides book books paper papers note notes list lists side sides
    end ends start kind kinds sort sorts form forms level levels order orders rule rules step
    steps piece pieces bit bits byte bytes set sets map maps key keys pair pairs area room
    house home school office game games job money door water food car city country state
    system systems program programs programming language languages code codes data file files
    computer machine machines memory memories disk process processes thread threads
    function functions method methods variable variables value values type types object objects
    class structure structures struct structs array arrays pointer pointers string strings
    integer integers float floats double boolean booleans character characters bit
    expression expressions statement statements operator operators operand operands operation
    operations instruction instructions register registers address addresses stack stacks
    heap queue queues tree trees graph graphs node nodes edge edges root leaf leaves path paths
    table tables symbol symbols entry entries index indexes indices offset offsets base bases
    block blocks loop loops condition conditions conditional branch branches label labels
    body bodies argument arguments parameter parameters result results input inputs output
    outputs source target compiler compilers parser parsers grammar grammars token tokens
    scope scopes frame frames call calls definition definitions declaration declarations
    assignment reference references copy copies version versions field fields record records
    element elements item items member members child parent parents sibling left right
    constant constants literal literals immediate intermediate representation representations
    model models layout design pattern patterns strategy strategies approach method algorithm
    algorithms analysis semantic semantics syntax logic logical physical virtual abstract
    concrete level machine hardware software architecture target native runtime compile
    error errors bug bugs warning warnings mistake mistakes answer answers reason reasons
    sense meaning purpose goal goals issue issues detail details information content contents
    difference differences option options choice choices chance rest top bottom
    handle handles lock locks load loads fee fees see sea why you be bee tea tee pea pee
    queue cue gee jay kay ex oh owe are our hour eye aye sigh dee ef el em en es tee vee
    add sub div mod min max sum plus minus times divide divided multiply multiplied
    and or not xor shift id ids
    """
}

/// The system word list (`/usr/share/dict/words`), loaded on first use. Too permissive to tell
/// everyday words from jargon (it has "gen" and "reg"), but a good test of "is this a real
/// English word at all" before a near-miss is replaced. A missing list counts every word as real.
enum EnglishDictionary {
    static func contains(_ word: String) -> Bool {
        guard let words else { return true }
        return words.contains(word.lowercased())
    }

    private static let words: Set<String>? = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return nil }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
}
