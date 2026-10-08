import Foundation

/// A JSON reply the model is asked for. Decoding is tolerant (see `LenientDecoding`); each call site
/// validates the semantics it needs and, on failure, the repair turn shows the model `shape`.
protocol ModelReply: Decodable, Sendable {
    /// JSON Schema passed through `ResponseFormat.json(schema:)` (enforced natively by providers that
    /// support structured output, otherwise used as instructions).
    static var schema: String { get }
    /// A one-line example of the expected object, shown in the repair turn.
    static var shape: String { get }
}

// MARK: - Rolling takeaways

struct SegmentationReply: ModelReply, Equatable {
    enum Action: Equatable { case continueTopic, newTopic }
    enum LinesKind: Equatable { case sameConcept, newConcept, admin }

    /// What the new lines are mainly about. A reasoning scaffold: naming it before choosing the
    /// action measurably helps small models notice topic changes. Not shown to the user.
    var newLinesAbout: String
    /// The model's classification of the new lines. `.admin` replies never open or split a topic,
    /// whatever `action` says.
    var newLinesKind: LinesKind
    var action: Action
    var boundaryQuote: String
    var closedSummary: String
    var title: String
    var summary: String
    var slides: [Int]

    init(action: Action, newLinesAbout: String = "", newLinesKind: LinesKind? = nil, boundaryQuote: String = "", closedSummary: String = "", title: String, summary: String, slides: [Int] = []) {
        self.newLinesAbout = newLinesAbout
        self.newLinesKind = newLinesKind ?? (action == .newTopic ? .newConcept : .sameConcept)
        self.action = action
        self.boundaryQuote = boundaryQuote
        self.closedSummary = closedSummary
        self.title = title
        self.summary = summary
        self.slides = slides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        newLinesAbout = c.string("newlinesabout")
        let raw = NormalizedKey.normalize(c.string("action"))
        action = raw.contains("new") || raw.contains("switch") || raw.contains("split") ? .newTopic : .continueTopic
        let kind = NormalizedKey.normalize(c.string("newlineskind"))
        newLinesKind = kind.contains("admin") || kind.contains("chat") || kind.contains("logistic") ? .admin
            : kind.contains("new") ? .newConcept
            : kind.contains("same") ? .sameConcept
            : (action == .newTopic ? .newConcept : .sameConcept)
        boundaryQuote = c.string("boundaryquote")
        closedSummary = c.string("closedsummary")
        title = c.string("title")
        summary = c.string("summary")
        slides = c.ints("slides")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "new_lines_about":{"type":"string"},\
    "new_lines_kind":{"type":"string","enum":["same_concept","new_concept","admin_or_chat"]},\
    "action":{"type":"string","enum":["continue","new_topic"]},\
    "boundary_quote":{"type":"string"},\
    "closed_summary":{"type":"string"},\
    "title":{"type":"string"},\
    "summary":{"type":"string"},\
    "slides":{"type":"array","items":{"type":"integer"}}},\
    "required":["new_lines_about","new_lines_kind","action","boundary_quote","closed_summary","title","summary","slides"]}
    """

    static let shape = #"{"new_lines_about":"…","new_lines_kind":"same_concept"|"new_concept"|"admin_or_chat","action":"continue"|"new_topic","boundary_quote":"…","closed_summary":"…","title":"…","summary":"…","slides":[1,2]}"#
}

// MARK: - Quiz option check

/// Which options of a multiple-choice question the model judges correct.
struct OptionCheckReply: ModelReply {
    var correctOptions: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        correctOptions = c.ints("correctoptions")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "correct_options":{"type":"array","items":{"type":"integer"}}},\
    "required":["correct_options"]}
    """

    static let shape = #"{"correct_options":[2]}"#
}

// MARK: - Opening recap card

/// Title and summary for a card written after the fact (the lecture's opening recap).
struct CardReply: ModelReply {
    var title: String
    var summary: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        title = c.string("title")
        summary = c.string("summary")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "title":{"type":"string"},\
    "summary":{"type":"string"}},\
    "required":["title","summary"]}
    """

    static let shape = #"{"title":"Recap: …","summary":"…"}"#
}

// MARK: - Expanded takeaway

struct DetailReply: ModelReply {
    var bullets: [String]
    var keyTerms: [LenientKeyTerm]
    var example: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        bullets = c.strings("bullets")
        keyTerms = Self.decodeTerms(c)
        let ex = c.string("example")
        example = ex.isEmpty || ["none", "n/a", "null"].contains(ex.lowercased()) ? nil : ex
    }

    static func decodeTerms(_ c: KeyedDecodingContainer<NormalizedKey>, key name: String = "keyterms") -> [LenientKeyTerm] {
        let key = NormalizedKey(stringValue: name)
        if let list = try? c.decode([LenientKeyTerm].self, forKey: key) { return list.filter(\.isUsable) }
        if let map = try? c.decode([String: String].self, forKey: key) {
            return map.sorted { $0.key < $1.key }.map { LenientKeyTerm(term: $0.key, definition: $0.value) }
        }
        return []
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "bullets":{"type":"array","items":{"type":"string"}},\
    "key_terms":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "term":{"type":"string"},"definition":{"type":"string"}},"required":["term","definition"]}},\
    "example":{"type":"string"}},\
    "required":["bullets","key_terms","example"]}
    """

    static let shape = #"{"bullets":["…","…","…","…"],"key_terms":[{"term":"…","definition":"…"}],"example":"…"}"#
}

/// `{"term": "…", "definition": "…"}`, or a single `"Term: definition"` string.
struct LenientKeyTerm: Decodable, Equatable {
    var term: String
    var definition: String

    var isUsable: Bool { !term.isEmpty && !definition.isEmpty }

    init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: NormalizedKey.self) {
            let t = c.string("term")
            term = t.isEmpty ? c.string("name") : t
            let d = c.string("definition")
            definition = d.isEmpty ? c.string("meaning") : d
            return
        }
        let line = try decoder.singleValueContainer().decode(String.self)
        for separator in [":", " — ", " – ", " - "] {
            if let r = line.range(of: separator) {
                term = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                definition = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return
            }
        }
        term = line
        definition = ""
    }
}

// MARK: - Recap

struct RecapReply: ModelReply {
    var headline: String
    var bullets: [String]
    var flagged: [String]
    var slides: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        headline = c.string("headline")
        bullets = c.strings("bullets")
        flagged = c.strings("flagged")
        slides = c.ints("slides")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "headline":{"type":"string"},\
    "bullets":{"type":"array","items":{"type":"string"}},\
    "flagged":{"type":"array","items":{"type":"string"}},\
    "slides":{"type":"array","items":{"type":"integer"}}},\
    "required":["headline","bullets","flagged","slides"]}
    """

    static let shape = #"{"headline":"…","bullets":["…","…"],"flagged":[],"slides":[3]}"#
}

// MARK: - Lecture summary

struct LectureSummaryReply: ModelReply {
    var overview: String
    var keyConcepts: [LenientKeyTerm]
    var reviewThese: [String]
    var flagged: [String]
    var slides: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        let o = c.string("overview")
        overview = o.isEmpty ? c.string("summary") : o
        let concepts = DetailReply.decodeTerms(c, key: "keyconcepts")
        keyConcepts = concepts.isEmpty ? DetailReply.decodeTerms(c) : concepts
        let review = c.strings("reviewthese")
        reviewThese = review.isEmpty ? c.strings("review") : review
        flagged = c.strings("flagged")
        slides = c.ints("slides")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "overview":{"type":"string"},\
    "key_concepts":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{\
    "term":{"type":"string"},"definition":{"type":"string"}},"required":["term","definition"]}},\
    "review_these":{"type":"array","items":{"type":"string"}},\
    "flagged":{"type":"array","items":{"type":"string"}},\
    "slides":{"type":"array","items":{"type":"integer"}}},\
    "required":["overview","key_concepts","review_these","flagged","slides"]}
    """

    static let shape = #"{"overview":"…","key_concepts":[{"term":"…","definition":"…"}],"review_these":["Concept — why"],"flagged":[],"slides":[3,7]}"#
}

// MARK: - Quiz

struct MultipleChoiceReply: ModelReply {
    var concept: String
    var question: String
    var answer: String
    var distractors: [String]
    var explanation: String
    var slides: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        concept = c.string("concept")
        question = c.string("question")
        let a = c.string("correctanswer")
        answer = a.isEmpty ? c.string("answer") : a
        let d = c.strings("distractors")
        distractors = d.isEmpty ? c.strings("wronganswers") : d
        explanation = c.string("explanation")
        slides = c.ints("slides")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "concept":{"type":"string"},\
    "question":{"type":"string"},\
    "correct_answer":{"type":"string"},\
    "distractors":{"type":"array","items":{"type":"string"}},\
    "explanation":{"type":"string"},\
    "slides":{"type":"array","items":{"type":"integer"}}},\
    "required":["concept","question","correct_answer","distractors","explanation","slides"]}
    """

    static let shape = #"{"concept":"…","question":"…","correct_answer":"…","distractors":["…","…","…"],"explanation":"…","slides":[3]}"#
}

struct ShortAnswerReply: ModelReply {
    var concept: String
    var question: String
    var referenceAnswer: String
    var slides: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        concept = c.string("concept")
        question = c.string("question")
        let r = c.string("referenceanswer")
        referenceAnswer = r.isEmpty ? c.string("answer") : r
        slides = c.ints("slides")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "concept":{"type":"string"},\
    "question":{"type":"string"},\
    "reference_answer":{"type":"string"},\
    "slides":{"type":"array","items":{"type":"integer"}}},\
    "required":["concept","question","reference_answer","slides"]}
    """

    static let shape = #"{"concept":"…","question":"…","reference_answer":"…","slides":[3]}"#
}

struct GradeReply: ModelReply {
    var correct: Bool?
    var feedback: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NormalizedKey.self)
        correct = c.bool("correct") ?? c.bool("iscorrect")
        feedback = c.string("feedback")
    }

    static let schema = """
    {"type":"object","additionalProperties":false,"properties":{\
    "correct":{"type":"boolean"},\
    "feedback":{"type":"string"}},\
    "required":["correct","feedback"]}
    """

    static let shape = #"{"correct":true,"feedback":"…"}"#
}

// MARK: - Warm-up

extension LectureBrain {
    /// Every JSON schema the brain sends, so an on-device host can compile their grammars ahead of
    /// the first real call (a schema's first use otherwise pays a one-time setup cost).
    public static let jsonSchemas: [String] = [
        SegmentationReply.schema, DetailReply.schema, RecapReply.schema, LectureSummaryReply.schema,
        MultipleChoiceReply.schema, ShortAnswerReply.schema, GradeReply.schema, CardReply.schema, OptionCheckReply.schema,
    ]
}
