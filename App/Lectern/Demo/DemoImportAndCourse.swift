import Foundation
import LecternCore
import LecternImport
import SwiftUI

// MARK: - Recording import

/// Fakes an import: walks the stages over ~10 s and returns the scripted lecture as a finished
/// session (with speaker labels and quiz history), so the staged progress row and the
/// import → review hand-off are exercisable.
nonisolated struct DemoRecordingImporter: RecordingImporting {
    var speed: Double = 1

    func importRecording(_ source: RecordingSource, into session: LectureSession, progress: @escaping @Sendable (ImportStage) -> Void) async throws -> LectureSession {
        func sleep(_ s: Double) async throws { try await Task.sleep(for: .seconds(s / max(0.1, speed))) }
        let downloads: Bool
        var usedCaptions = false
        switch source {
        case .file: downloads = false
        case .mediaSpace(_, let preferCaptions): downloads = true; usedCaptions = preferCaptions
        }
        if downloads {
            for i in 1...10 { try await sleep(0.25); progress(.downloading(fraction: Double(i) / 10)) }
        }
        progress(.extractingAudio)
        try await sleep(0.8)
        let transcribeSteps = usedCaptions ? 4 : 12
        for i in 1...transcribeSteps { try await sleep(0.3); progress(.transcribing(fraction: Double(i) / Double(transcribeSteps))) }
        for i in 1...8 { try await sleep(0.3); progress(.summarizing(fraction: Double(i) / 8)) }
        progress(.finished)
        // Build the result from the scripted lecture but keep the caller's identity/course/title.
        let course = Course(id: session.courseID ?? UUID(), code: "", name: "")
        var result = DemoLibrarySeed.scripted(script: .compilers, course: course, startedAt: session.createdAt)
        result.id = session.id
        result.courseID = session.courseID
        result.title = session.title
        result.createdAt = session.createdAt
        result.startedAt = session.createdAt
        result.endedAt = .now
        result.status = .finished
        result.deck = session.deck ?? result.deck
        result.source = session.source
        if case .mediaSpace(let entry, let page, _) = session.source { result.source = .mediaSpace(entryID: entry, pageURL: page, usedCaptions: usedCaptions) }
        // Like a real import, the summary is written when the lecture is first reviewed.
        result.summary = nil
        return result
    }
}

/// Provides the embedded MediaSpace browser. The real implementation (LecternImport's
/// `MediaSpaceBrowserView`) drives `state`, which the hosting sheet reads for its navigation
/// buttons; the demo stand-in leaves it untouched.
@MainActor
protocol MediaSpaceBrowserProviding: Sendable {
    func makeBrowser(state: MediaSpaceBrowserState, onFound: @escaping (MediaSpaceSource) -> Void) -> AnyView
}

/// Stand-in for the embedded browser: a mock MediaSpace page with a "lecture found" button.
nonisolated struct DemoMediaSpaceBrowser: MediaSpaceBrowserProviding {
    @MainActor
    func makeBrowser(state: MediaSpaceBrowserState, onFound: @escaping (MediaSpaceSource) -> Void) -> AnyView {
        AnyView(DemoMediaSpacePage(onFound: onFound))
    }
}

private struct DemoMediaSpacePage: View {
    var onFound: (MediaSpaceSource) -> Void
    @State private var signedIn = false

    var body: some View {
        VStack(spacing: DS.Space.l) {
            HStack {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("mediaspace.illinois.edu").font(DS.Typo.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            Spacer()
            if signedIn {
                VStack(spacing: DS.Space.s) {
                    Text("My Media").font(DS.Typo.title2)
                    ForEach(["CS 421 · Lecture 8 — Parsing II", "CS 421 · Lecture 9 — Bottom-up parsing", "CS 374 · Lecture 14 — Dynamic Programming"], id: \.self) { title in
                        Button {
                            onFound(MediaSpaceSource(partnerID: "1329972", entryID: "1_\(abs(title.hashValue) % 100000)", ks: "demo-ks", title: title, pageURL: URL(string: "https://mediaspace.illinois.edu/media/\(title.hashValue)")))
                        } label: {
                            HStack {
                                Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary)
                                Text(title)
                                Spacer()
                                Text("1:12:40").font(DS.Typo.mono).foregroundStyle(.secondary)
                            }
                            .padding(DS.Space.m)
                            .frame(maxWidth: 420)
                            .surfaceCard(radius: DS.Radius.card)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: DS.Space.m) {
                    Image(systemName: "person.badge.key").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Sign in to Illinois MediaSpace").font(DS.Typo.title3)
                    Text("This is the demo stand-in for the embedded browser. The real one shows the MediaSpace site and detects a lecture when you open one.")
                        .font(DS.Typo.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button("Sign in (demo)") { withAnimation(DS.Motion.settle) { signedIn = true } }.buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.canvas)
    }
}

// MARK: - Presentation conversion

/// Demo converter for .pptx/.key: takes a moment, then hands back the sample deck with notes.
nonisolated struct DemoPresentationConverter: PresentationConverting {
    var samplePDF: @Sendable () async throws -> URL?
    let supportedExtensions: Set<String> = ["pptx", "key"]

    func convertToPDF(_ url: URL) async throws -> (pdf: URL, notes: [Int: String]) {
        try await Task.sleep(for: .seconds(2))
        guard let pdf = try await samplePDF() else { throw PresentationConversionError.automationDenied }
        return (pdf, [2: "Remind them the lexer is done.", 12: "Emphasize: this is the definition they'll be asked to reproduce."])
    }
}

nonisolated enum PresentationConversionError: LocalizedError {
    case automationDenied
    var errorDescription: String? {
        switch self {
        case .automationDenied: "Lectern needs permission to control Keynote. Allow it in System Settings › Privacy & Security › Automation, then try again."
        }
    }
}

// MARK: - Course-wide Ask

/// Canned course assistant: answers with `[L# S#]` / `[L# T#]` markers across the lectures it
/// was given, streamed word by word.
nonisolated struct DemoCourseAssistant: CourseAssisting {
    var lectures: [CourseLecture]
    var speed: Double = 1

    func ask(_ question: String, history: [CourseAnswer]) -> AsyncThrowingStream<CourseAskEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<CourseAskEvent, Error>.makeStream()
        let text = answerText(for: question)
        let sessions = Dictionary(uniqueKeysWithValues: lectures.map { ($0.ordinal, $0.session.id) })
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(0.9 / max(0.1, speed)))
                var emitted = ""
                var token = ""
                for ch in text {
                    token.append(ch)
                    if ch == " " || ch == "\n" {
                        emitted += token
                        continuation.yield(.delta(token))
                        token = ""
                        try await Task.sleep(for: .milliseconds(Int(Double.random(in: 18...50) / max(0.1, speed))))
                    }
                }
                emitted += token
                if !token.isEmpty { continuation.yield(.delta(token)) }
                continuation.yield(.done(CourseAnswer(question: question, text: emitted, citations: CitationParser.courseCitations(in: emitted, sessions: sessions))))
                continuation.finish()
            } catch {
                continuation.finish(throwing: LLMError.cancelled)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func answerText(for question: String) -> String {
        let q = question.lowercased()
        let sorted = lectures.sorted { $0.ordinal < $1.ordinal }
        func lecture(matching words: [String]) -> CourseLecture? {
            sorted.first { l in words.contains { l.session.title.lowercased().contains($0) } }
        }
        if let parsing = lecture(matching: ["parsing", "ll(1)"]), q.contains("first") || q.contains("follow") || q.contains("ll(1)") || q.contains("parse") {
            let n = parsing.ordinal
            return "In **Lecture \(n)** the professor introduced FIRST and FOLLOW sets. FIRST(α) is what a string derived from α can start with [L\(n) S7], and FOLLOW(A) is what can appear right after A [L\(n) S9] [L\(n) T\(TimeFormat.clock(parsing.session.takeaways.dropFirst().dropFirst(4).first?.start ?? 900))]. Together they fill the LL(1) table; the grammar is LL(1) iff no cell has two productions [L\(n) S12]. He flagged that definition as something that will be on the midterm."
        }
        if let lex = lecture(matching: ["lexical"]), q.contains("lex") || q.contains("token") || q.contains("regular") || q.contains("dfa") {
            let n = lex.ordinal
            return "Lexical analysis was **Lecture \(n)**: tokens are categories and lexemes are the matched text [L\(n) S2]. Regular expressions become NFAs through Thompson's construction [L\(n) S3], NFAs become DFAs by subset construction [L\(n) S4], and the lexer always takes the longest match (maximal munch) [L\(n) S5]."
        }
        if let ti = lecture(matching: ["type"]), q.contains("type") || q.contains("unif") || q.contains("occurs") {
            let n = ti.ordinal
            return "Type inference was covered in **Lecture \(n)**. Hindley–Milner generates constraints and unifies them [L\(n) S2]; the occurs check refuses to bind α to a type containing α, which would create an infinite type [L\(n) S4]. Let-bound variables get generalized, lambda-bound ones stay monomorphic [L\(n) S5]."
        }
        if q.contains("exam") || q.contains("midterm") || q.contains("important") {
            let refs = sorted.prefix(3).map { "**\($0.session.title)** [L\($0.ordinal) S2]" }.joined(separator: ", ")
            return "Across the course so far the flagged items are: the LL(1) condition (\"this will be on the midterm\") [L\(sorted.last?.ordinal ?? 1) S12], the occurs check, and the difference between tokens and lexemes. The lectures that matter most for the midterm are \(refs)."
        }
        if q.contains("last week") || q.contains("recent") || q.contains("catch") {
            let recent = sorted.suffix(2)
            return "Recently: " + recent.map { "**\($0.session.title)** — \($0.session.takeaways.first?.summary ?? "") [L\($0.ordinal) S2]" }.joined(separator: "\n\n")
        }
        let l = sorted.last ?? sorted.first
        let n = l?.ordinal ?? 1
        return "The closest match in this course is **\(l?.session.title ?? "the latest lecture")** [L\(n) S1]: \(l?.session.takeaways.first?.summary ?? "see the summary card"). Ask about a specific topic — parsing, lexing, type inference — for a grounded answer with slide and timestamp citations."
    }
}
