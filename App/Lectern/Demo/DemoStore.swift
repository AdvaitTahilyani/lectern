import Foundation
import LecternCore

/// In-memory `SessionStoring` seeded with a small library of finished lectures (with rendered
/// slide decks) so Library, Review and search are fully explorable.
actor DemoStore: SessionStoring {
    private var courses: [Course] = []
    private var sessions: [UUID: LectureSession] = [:]
    private var seeded = false
    private let root: URL

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Lectern-Demo", isDirectory: true)
    }

    // MARK: SessionStoring

    func loadCourses() async throws -> [Course] {
        try seedIfNeeded()
        return courses
    }

    func saveCourses(_ courses: [Course]) async throws {
        try seedIfNeeded()
        self.courses = courses
    }

    func loadSessions() async throws -> [LectureSession] {
        try seedIfNeeded()
        return sessions.values.sorted { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) }
    }

    func loadSession(id: UUID) async throws -> LectureSession {
        try seedIfNeeded()
        guard let s = sessions[id] else { throw CocoaError(.fileNoSuchFile) }
        return s
    }

    func save(_ session: LectureSession) async throws {
        try seedIfNeeded()
        sessions[session.id] = session
    }

    func delete(sessionID: UUID) async throws {
        sessions[sessionID] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(sessionID.uuidString))
    }

    func folder(for sessionID: UUID) async throws -> URL {
        let url = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func importSlides(from url: URL, into sessionID: UUID) async throws -> String {
        let folder = try await folder(for: sessionID)
        let dest = folder.appendingPathComponent("slides.pdf")
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        return "slides.pdf"
    }

    private var courseChats: [UUID: [CourseAnswer]] = [:]

    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] { courseChats[courseID] ?? [] }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws { courseChats[courseID] = answers }

    // MARK: Demo extras

    /// A rendered copy of the scripted lecture's deck, for "Use sample deck" in Setup.
    func sampleDeckURL() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sample-deck.pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try DemoDeckRenderer.render(slides: DemoScript.compilers.slides, deckTitle: DemoScript.compilers.title, theme: .indigo, to: url)
        }
        return url
    }

    /// Substring search over titles, transcript segments and takeaways.
    func search(_ query: String, scope: LibrarySearchScope) -> [LibrarySearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var hits: [LibrarySearchHit] = []
        for s in sessions.values {
            if scope == .all || scope == .titles, let r = s.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                hits.append(LibrarySearchHit(sessionID: s.id, field: .title, snippet: s.title, matchRange: r, time: nil, slide: nil))
            }
            if scope == .all || scope == .takeaways {
                for t in s.takeaways {
                    let text = t.title + " — " + t.summary
                    if let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                        hits.append(LibrarySearchHit(sessionID: s.id, field: .takeaway, snippet: text, matchRange: r, time: t.start, slide: t.slidePages.first))
                    }
                }
            }
            if scope == .all || scope == .transcripts {
                for seg in s.transcript {
                    if let r = seg.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                        hits.append(LibrarySearchHit(sessionID: s.id, field: .transcript, snippet: seg.text, matchRange: r, time: seg.start, slide: nil))
                        if hits.count > 200 { return hits }
                    }
                }
            }
        }
        return hits
    }

    // MARK: - Seed

    private func seedIfNeeded() throws {
        guard !seeded else { return }
        seeded = true
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cs421 = Course(code: "CS 421", name: "Programming Languages & Compilers", colorHex: "#5B5FEF")
        let cs374 = Course(code: "CS 374", name: "Algorithms & Models of Computation", colorHex: "#1A8C8C")
        let math415 = Course(code: "MATH 415", name: "Applied Linear Algebra", colorHex: "#E5731A")
        courses = [cs421, cs374, math415]

        let now = Date.now
        func daysAgo(_ d: Double, hour: Int = 10) -> Date {
            let day = Calendar.current.date(byAdding: .day, value: -Int(d), to: now) ?? now
            return Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }

        try add(DemoLibrarySeed.scripted(script: .compilers, course: cs421, startedAt: daysAgo(6, hour: 11)), theme: .indigo, slides: DemoScript.compilers.slides)
        for seed in DemoLibrarySeed.catalog {
            let course: Course
            let theme: DemoDeckRenderer.Theme
            switch seed.courseCode {
            case "CS 421": course = cs421; theme = .indigo
            case "CS 374": course = cs374; theme = .teal
            default: course = math415; theme = .orange
            }
            let session = DemoLibrarySeed.session(from: seed, course: course, startedAt: daysAgo(seed.daysAgo, hour: seed.hour))
            try add(session, theme: theme, slides: seed.slides)
        }
    }

    private func add(_ session: LectureSession, theme: DemoDeckRenderer.Theme, slides: [DemoScript.Slide]) throws {
        var s = session
        let folder = root.appendingPathComponent(s.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("slides.pdf")
        let deck = try DemoDeckRenderer.render(slides: slides, deckTitle: s.title, theme: theme, to: pdf)
        s.deck = SlideDeck(fileName: "slides.pdf", originalFileName: session.deck?.originalFileName ?? "\(s.title.lowercased().replacingOccurrences(of: " ", with: "-")).pdf", title: deck.title, pages: deck.pages)
        sessions[s.id] = s
    }
}

// MARK: - Library seed data

nonisolated enum DemoLibrarySeed {
    struct Spec: Sendable {
        var courseCode: String
        var title: String
        var daysAgo: Double
        var hour: Int
        var slides: [DemoScript.Slide]
        var quiz: [(prompt: String, options: [String], correct: Int, outcome: QuizOutcome)]
    }

    /// The finished version of the scripted lecture, with the full transcript and quiz history.
    static func scripted(script: DemoScript, course: Course, startedAt: Date) -> LectureSession {
        var transcript: [TranscriptSegment] = []
        var takeaways: [Takeaway] = []
        var clock: TimeInterval = 4
        for beat in script.beats {
            let beatStart = clock
            for line in beat.sentences {
                let isAudience = line.hasPrefix(DemoScript.audienceMarker)
                let sentence = isAudience ? String(line.dropFirst(DemoScript.audienceMarker.count)) : line
                let words = Double(sentence.split(separator: " ").count)
                let dur = words / 2.6 + 0.7
                transcript.append(TranscriptSegment(text: sentence, start: clock, end: clock + dur, isFinal: true, speaker: isAudience ? .audience(index: 1) : .lecturer))
                clock += dur
            }
            clock += 90 // lecture beats are longer in reality than in the demo script
            takeaways.append(Takeaway(title: beat.title, summary: beat.summary, detail: beat.detail, start: beatStart, end: clock, slidePages: beat.slidePages, isLive: false))
        }
        var quiz: [QuizRecord] = []
        for (i, beat) in script.beats.enumerated() {
            guard let q = beat.quiz else { continue }
            let askedAt = takeaways[i].end + 5
            // The script's ranges follow the live demo's clock; this timeline is the seeded one.
            var question = q.question
            question.sourceStart = takeaways[i].start
            question.sourceEnd = takeaways[i].end
            let outcome: QuizOutcome = quiz.count == 1 ? .incorrect : (quiz.count == 3 ? .skipped : .correct)
            var answer: String?
            var grade: QuizGrade?
            switch (q.question.kind, outcome) {
            case (.multipleChoice(let options, let correct), .correct):
                answer = "\(correct)"
                grade = QuizGrade(isCorrect: true, feedback: "Nice — \(options[correct].prefix(1).lowercased() + options[correct].dropFirst()) is exactly it.", citations: q.question.sourceSlides.map(Citation.slide))
            case (.multipleChoice(let options, let correct), .incorrect):
                answer = "\((correct + 1) % options.count)"
                grade = QuizGrade(isCorrect: false, feedback: "Not quite. \(beat.summary)", citations: q.question.sourceSlides.map(Citation.slide) + [.time(askedAt - 60)])
            default: break
            }
            quiz.append(QuizRecord(question: question, answer: answer, grade: grade, outcome: outcome, askedAt: askedAt, answeredAt: outcome == .skipped ? nil : startedAt.addingTimeInterval(askedAt + 20)))
        }
        let chat = [
            ChatMessage(role: .user, text: "What's the difference between FIRST and FOLLOW?"),
            ChatMessage(role: .assistant, text: script.answer(for: "follow", sessionTime: 1500, currentSlide: 9), citations: CitationParser.citations(in: script.answer(for: "follow", sessionTime: 1500, currentSlide: 9))),
        ]
        return LectureSession(
            courseID: course.id, title: script.title, createdAt: startedAt, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(clock),
            duration: clock, status: .finished,
            deck: SlideDeck(fileName: "slides.pdf", originalFileName: "lecture08-parsing2.pdf", title: script.title, pages: []),
            transcript: transcript, takeaways: takeaways, quiz: quiz, chat: chat, currentSlide: 18,
            summary: script.lectureSummary(quiz: quiz)
        )
    }

    /// Builds a plausible finished session from a slide outline.
    static func session(from spec: Spec, course: Course, startedAt: Date) -> LectureSession {
        var transcript: [TranscriptSegment] = []
        var takeaways: [Takeaway] = []
        var clock: TimeInterval = 12
        let openers = ["So let's talk about", "Okay, next up is", "Now, the important idea here is", "Alright, moving on to", "So this brings us to"]
        for (i, slide) in spec.slides.enumerated().dropFirst() {
            let start = clock
            let intro = "\(openers[i % openers.count]) \(slide.title.lowercased()). \(slide.bullets.first ?? "")"
            transcript.append(TranscriptSegment(text: intro, start: clock, end: clock + 14, isFinal: true)); clock += 16
            for b in slide.bullets.dropFirst() {
                let sentence = "\(b). Is this clear? Okay, so, uh, let's keep going."
                transcript.append(TranscriptSegment(text: sentence, start: clock, end: clock + 11, isFinal: true)); clock += 13
            }
            clock += 150
            takeaways.append(Takeaway(
                title: slide.title,
                summary: slide.bullets.joined(separator: "; ") + ".",
                detail: TakeawayDetail(bullets: slide.bullets, keyTerms: []),
                start: start, end: clock, slidePages: [i + 1], isLive: false
            ))
        }
        var quiz: [QuizRecord] = []
        for (i, q) in spec.quiz.enumerated() {
            let askedAt = min(clock - 60, Double(i + 1) * clock / Double(spec.quiz.count + 1))
            let question = QuizQuestion(prompt: q.prompt, kind: .multipleChoice(options: q.options, correctIndex: q.correct), concept: spec.slides[min(i + 1, spec.slides.count - 1)].title, sourceSlides: [min(i + 2, spec.slides.count)], sourceStart: askedAt - 90, sourceEnd: askedAt)
            var grade: QuizGrade?
            var answer: String?
            switch q.outcome {
            case .correct: answer = "\(q.correct)"; grade = QuizGrade(isCorrect: true, feedback: "Correct — that's the key point.", citations: [.slide(min(i + 2, spec.slides.count))])
            case .incorrect: answer = "\((q.correct + 1) % q.options.count)"; grade = QuizGrade(isCorrect: false, feedback: "Not quite. The answer is “\(q.options[q.correct])”. \(spec.slides[min(i + 1, spec.slides.count - 1)].bullets.first ?? "")", citations: [.slide(min(i + 2, spec.slides.count)), .time(askedAt - 60)])
            case .skipped: break
            }
            quiz.append(QuizRecord(question: question, answer: answer, grade: grade, outcome: q.outcome, askedAt: askedAt, answeredAt: q.outcome == .skipped ? nil : startedAt.addingTimeInterval(askedAt + 15)))
        }
        let topics = Array(spec.slides.dropFirst())
        let overview = topics.prefix(4).map { "\($0.title): \($0.bullets.first ?? "")." }.joined(separator: " ")
        let missed = quiz.filter { $0.outcome == .incorrect }.map { r in
            "\(r.question.concept) — the answer to “\(r.question.prompt)” is “\(correctOption(r.question))”."
        }
        let summary = LectureSummary(
            overview: overview,
            keyConcepts: topics.prefix(4).map { KeyTerm(term: $0.title, definition: $0.bullets.first ?? "") },
            reviewThese: missed,
            slides: Array(2...min(4, max(2, spec.slides.count)))
        )
        return LectureSession(
            courseID: course.id, title: spec.title, createdAt: startedAt, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(clock),
            duration: clock, status: .finished,
            deck: SlideDeck(fileName: "slides.pdf", originalFileName: spec.title.lowercased().replacingOccurrences(of: " ", with: "-") + ".pdf", title: spec.title, pages: []),
            transcript: transcript, takeaways: takeaways, quiz: quiz, chat: [], currentSlide: spec.slides.count,
            summary: summary
        )
    }

    private static func correctOption(_ question: QuizQuestion) -> String {
        switch question.kind {
        case .multipleChoice(let options, let correct): options.indices.contains(correct) ? options[correct] : ""
        case .shortAnswer(let reference): reference
        }
    }

    static let catalog: [Spec] = [
        Spec(courseCode: "CS 421", title: "Type Inference", daysAgo: 1, hour: 11, slides: [
            .init(title: "Type Inference", bullets: ["CS 421 · Lecture 12", "Hindley–Milner, unification, let-polymorphism"]),
            .init(title: "Hindley–Milner overview", bullets: ["Types are inferred by generating constraints and unifying them", "No annotations needed", "Principal types exist"]),
            .init(title: "Unification algorithm", bullets: ["Walks both types, binds variables, fails on mismatched constructors", "Substitutions compose", "Most general unifier"]),
            .init(title: "Occurs check", bullets: ["Prevents infinite types by refusing to bind α to a type containing α", "α ~ List α fails", "Cheap to implement, easy to forget"]),
            .init(title: "Let-polymorphism & generalization", bullets: ["Let-bound variables get generalized types", "Lambda-bound ones stay monomorphic", "Value restriction for references"]),
        ], quiz: [
            ("What does the occurs check prevent?", ["Binding a variable to a type that contains it", "Applying a substitution twice", "Unifying two constructors with different arity", "Generalizing a lambda-bound variable"], 0, .correct),
            ("Which variables get generalized in HM?", ["Let-bound", "Lambda-bound", "All variables", "None"], 0, .incorrect),
            ("What does unification return on success?", ["The most general unifier", "A type scheme", "A proof tree", "A constraint set"], 0, .correct),
        ]),
        Spec(courseCode: "CS 421", title: "Lexical Analysis & Regular Languages", daysAgo: 8, hour: 11, slides: [
            .init(title: "Lexical Analysis", bullets: ["CS 421 · Lecture 7", "Tokens, regular expressions, DFAs"]),
            .init(title: "Tokens and lexemes", bullets: ["A token is a category; a lexeme is the matched text", "Keywords, identifiers, literals, operators", "Whitespace and comments are skipped"]),
            .init(title: "Regular expressions to NFAs", bullets: ["Thompson's construction builds an NFA compositionally", "One NFA per token rule, joined by alternation", "ε-transitions glue the pieces"]),
            .init(title: "NFA to DFA", bullets: ["Subset construction: DFA states are sets of NFA states", "Worst case exponential, rare in practice", "Minimize with Hopcroft's algorithm"]),
            .init(title: "Maximal munch", bullets: ["Always take the longest match", "Ties broken by rule order", "Why == is one token, not two"]),
        ], quiz: [
            ("Which construction turns a regex into an NFA?", ["Thompson's", "Subset", "Hopcroft's", "Kleene's"], 0, .correct),
            ("Maximal munch means…", ["Take the longest match", "Take the first rule", "Take the shortest match", "Skip whitespace"], 0, .correct),
        ]),
        Spec(courseCode: "CS 421", title: "Lambda Calculus", daysAgo: 13, hour: 11, slides: [
            .init(title: "Lambda Calculus", bullets: ["CS 421 · Lecture 5", "Syntax, reduction, Church encodings"]),
            .init(title: "Syntax", bullets: ["Terms: variables, abstraction λx.e, application e1 e2", "Application is left-associative", "Bodies extend as far right as possible"]),
            .init(title: "β-reduction", bullets: ["(λx.e) v → e[v/x]", "Capture-avoiding substitution", "Normal form when no redex remains"]),
            .init(title: "Evaluation order", bullets: ["Call-by-value reduces arguments first", "Call-by-name substitutes unevaluated", "Church–Rosser: normal forms are unique"]),
            .init(title: "Church encodings", bullets: ["Booleans: true = λt.λf.t", "Numerals: n = λf.λx.fⁿ x", "Pairs and lists follow the same trick"]),
        ], quiz: [
            ("What does β-reduction do?", ["Substitutes the argument into the body", "Renames bound variables", "Adds a type annotation", "Evaluates arguments lazily"], 0, .correct),
            ("Church–Rosser tells us…", ["Normal forms are unique", "Every term terminates", "Substitution is capture-free", "Application is associative"], 0, .skipped),
        ]),
        Spec(courseCode: "CS 374", title: "Dynamic Programming I", daysAgo: 0, hour: 9, slides: [
            .init(title: "Dynamic Programming I", bullets: ["CS 374 · Lecture 14", "Memoization, edit distance, LIS"]),
            .init(title: "Recursion with memoization", bullets: ["Identify overlapping subproblems", "Store answers in a table keyed by the subproblem", "Order the table so dependencies come first"]),
            .init(title: "Edit distance", bullets: ["E(i, j) = min of insert, delete, substitute", "O(nm) time and space", "Reconstruct the alignment by walking back"]),
            .init(title: "Longest increasing subsequence", bullets: ["L(i) = 1 + max L(j) for j < i with a[j] < a[i]", "O(n²) directly, O(n log n) with patience sorting", "Subsequence, not substring"]),
            .init(title: "Design recipe", bullets: ["Write the recursion first", "Then memoize", "Then figure out the evaluation order"]),
        ], quiz: [
            ("Edit distance runs in…", ["O(nm)", "O(n + m)", "O(n log m)", "O(2ⁿ)"], 0, .correct),
            ("The first step of the DP recipe is…", ["Write the recursion", "Allocate the table", "Pick the evaluation order", "Prove optimality"], 0, .correct),
            ("LIS in O(n log n) uses…", ["Patience sorting", "Binary heaps", "Union–find", "Suffix arrays"], 0, .incorrect),
        ]),
        Spec(courseCode: "CS 374", title: "Graph Search: BFS & DFS", daysAgo: 7, hour: 9, slides: [
            .init(title: "Graph Search", bullets: ["CS 374 · Lecture 11", "BFS, DFS, and what they find"]),
            .init(title: "Breadth-first search", bullets: ["Explores by layers using a queue", "Finds shortest paths in unweighted graphs", "O(V + E)"]),
            .init(title: "Depth-first search", bullets: ["Explores as deep as possible using a stack or recursion", "Pre/post numbers classify edges", "Back edge ⇔ cycle"]),
            .init(title: "Topological sort", bullets: ["Reverse postorder of DFS on a DAG", "Fails iff a back edge exists", "Used for dependency ordering"]),
            .init(title: "Strongly connected components", bullets: ["Kosaraju: DFS on G, then on Gᵀ in decreasing post order", "Linear time", "Component DAG"]),
        ], quiz: [
            ("BFS finds shortest paths when…", ["Edges are unweighted", "Edges are positive", "The graph is a DAG", "The graph is a tree"], 0, .correct),
            ("A back edge in DFS means…", ["There is a cycle", "The graph is bipartite", "The graph is a DAG", "There is a bridge"], 0, .correct),
        ]),
        Spec(courseCode: "MATH 415", title: "Eigenvalues & Eigenvectors", daysAgo: 12, hour: 14, slides: [
            .init(title: "Eigenvalues & Eigenvectors", bullets: ["MATH 415 · Lecture 19", "Av = λv"]),
            .init(title: "Definition", bullets: ["Av = λv with v ≠ 0", "λ is an eigenvalue, v an eigenvector", "Eigenvectors are directions the matrix only stretches"]),
            .init(title: "Characteristic polynomial", bullets: ["det(A − λI) = 0", "Degree n, so at most n eigenvalues", "Complex roots come in conjugate pairs for real A"]),
            .init(title: "Diagonalization", bullets: ["A = PDP⁻¹ when there are n independent eigenvectors", "Powers become easy: Aᵏ = PDᵏP⁻¹", "Symmetric matrices always diagonalize"]),
            .init(title: "Applications", bullets: ["Markov chains: steady state is the λ = 1 eigenvector", "Google PageRank", "Differential equations"]),
        ], quiz: [
            ("Eigenvalues are roots of…", ["det(A − λI)", "trace(A)", "A⁻¹", "det(A)"], 0, .correct),
            ("A is diagonalizable when…", ["It has n independent eigenvectors", "It is invertible", "It is square", "det(A) ≠ 0"], 0, .incorrect),
        ]),
        Spec(courseCode: "MATH 415", title: "Orthogonality & Least Squares", daysAgo: 5, hour: 14, slides: [
            .init(title: "Orthogonality & Least Squares", bullets: ["MATH 415 · Lecture 21", "Projections, Gram–Schmidt, normal equations"]),
            .init(title: "Orthogonal projection", bullets: ["proj_W(b) is the closest point in W to b", "b − proj_W(b) is orthogonal to W", "Projection matrix P = A(AᵀA)⁻¹Aᵀ"]),
            .init(title: "Gram–Schmidt", bullets: ["Turns any basis into an orthonormal one", "Subtract projections onto earlier vectors", "Numerically prefer modified Gram–Schmidt"]),
            .init(title: "Least squares", bullets: ["Minimize ‖Ax − b‖", "Solve the normal equations AᵀAx = Aᵀb", "Or use QR: Rx = Qᵀb"]),
            .init(title: "Fitting a line", bullets: ["Columns are 1 and x", "Solution gives intercept and slope", "Residuals are orthogonal to the column space"]),
        ], quiz: [
            ("The normal equations are…", ["AᵀAx = Aᵀb", "Ax = b", "AAᵀx = b", "xᵀA = bᵀ"], 0, .correct),
            ("Gram–Schmidt produces…", ["An orthonormal basis", "Eigenvectors", "A diagonal matrix", "The null space"], 0, .correct),
            ("Residuals of a least-squares fit are…", ["Orthogonal to the column space", "Zero", "Parallel to b", "Eigenvectors of A"], 0, .skipped),
        ]),
    ]
}
