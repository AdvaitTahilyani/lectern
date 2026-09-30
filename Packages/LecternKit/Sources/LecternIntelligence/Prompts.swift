import Foundation
import LecternCore

/// Every prompt the brain sends, in one place.
///
/// **Layout (for prompt/KV-cache reuse).** Each role has one system message that is byte-stable
/// for the whole session: the role's instructions, the lecture's name and the deck digest. Nothing
/// that changes (times, counters, the current topic) goes there. Per-call material follows in the
/// user message, ordered from most to least stable: the rolling-takeaways transcript block is
/// append-only while a topic lasts, and the task-specific instruction comes last. The summaries
/// role's system message is shared by rolling updates, "Expand" and recaps; the quizzes role's by
/// question writing, grading and follow-ups. Course-wide Ask has no deck digest (several decks);
/// its stable prefix is the instructions plus a one-line-per-lecture index.
///
/// **Style.** Instructions are short, explicit and imperative, because small local models follow
/// those best. One compact example reply is included where it measurably reduced malformed or
/// vague JSON from small models (rolling takeaways). The example deliberately comes from a
/// different CS area than typical lecture content, so it can't leak into a lecture's notes.
enum Prompts {
    /// Stable facts about the lecture that go into every system prompt.
    struct Lecture: Sendable, Hashable {
        var title: String
        var course: String?

        var line: String {
            let t = Text.collapse(title)
            if let course, !course.isEmpty { return "Lecture: \"\(t)\" (course: \(Text.collapse(course)))" }
            return "Lecture: \"\(t)\""
        }
    }

    // MARK: - Shared

    static func system(_ instructions: String, lecture: Lecture, digest: String) -> LLMMessage {
        .system(instructions + "\n\n" + lecture.line + "\n\n" + digest)
    }

    static func repair(shape: String, problem: String) -> String {
        """
        Your last reply could not be used: \(problem)
        Reply again with only one valid JSON object, shaped like:
        \(shape)
        """
    }

    // MARK: - Summaries role (rolling takeaways + expand)

    static let summariesInstructions = """
    You keep live notes for a student attending a university computer science lecture. The lecture \
    transcript arrives in pieces. You split it into topics and give each topic a short title and a \
    one- or two-sentence summary.

    The transcript comes from speech recognition: expect filler words, restarts and misheard terms \
    (for example "phenote" for "phi node"). Correct technical terms using the slides.

    On each update, first write new_lines_about: 2-6 words naming what the NEW lines mainly \
    explain. Then new_lines_kind: "same_concept" (still the current topic), "new_concept" (a \
    different concept or the next step), or "admin_or_chat" (logistics, quizzes, exams, deadlines, \
    greetings, the class ending, off-topic chat). Technical content is never "admin_or_chat", even \
    a correction of an earlier slide or a recap of last lecture. Then decide:
    - "continue": the new lines still develop the current topic (more detail, an example, a student \
    question, a tangent, admin talk). Rewrite title and summary so they cover the whole topic so far.
    - "new_topic": the lecturer clearly moved on to a different concept, usually with a transition \
    such as "okay, next..." or "now let's look at...". Then also give:
      boundary_quote: the first 6-10 words of the new topic, copied exactly from the transcript.
      closed_summary: the final summary of the topic that just ended.
      title and summary: for the new topic.
    For "continue", leave boundary_quote and closed_summary empty.

    Rules:
    - A topic is one concept, one step of an algorithm, or one slide section (slides sharing a \
    title), typically about 5 minutes of lecture (usually 3-8). Related ideas are still separate \
    topics: in a parsing lecture, "LL(1) parsing", "FIRST sets", "FOLLOW sets" and "Building the \
    parse table" are four topics. When the lecturer starts explaining a new named concept, the \
    next step of an algorithm, or moves to a slide with a new title, start a new topic.
    - Do not split for an example of the current concept, a student question or a short aside.
    - If the new lines only return to or restate one of the EARLIER TOPICS, reply "continue".
    - If the current topic has run much longer than 5 minutes, look hard for where a new \
    concept, step or slide section started.
    - Admin and chit-chat (homework, exams, quizzes, logistics, "can everyone hear me", the class \
    ending, students chatting) never become a topic and never appear in a summary: for those lines \
    reply "continue". A correction or recap of earlier material is lecture content, not admin.
    - title: 2-6 words naming the concept, like "Page replacement" or "Left recursion elimination".
    - summary: 1-2 sentences, at most 220 characters. State the technical content itself: \
    definitions, rules, how the algorithm works, why it matters. Use the exact terms from the slides.
    - Never start with "The professor", "The instructor" or "The lecturer", and never write "this \
    section covers" or "the lecture explains". Write the fact itself.
      Bad: "The professor explained how page faults are handled."
      Good: "On a page fault the OS picks a victim frame, writes it back if dirty, loads the missing page and restarts the instruction."
    - Lines starting with "Student:" are from the audience. Never state a student's guess as fact. \
    A good student question and the lecturer's answer to it may be part of the summary.
    - slides: the numbers of the slides this topic covers, from the SLIDES list; [] if unsure.
    - Plain text only: no LaTeX, no Markdown, no "$". Write symbols directly: α, ε, →, ∈.
    - Reply with one JSON object only.

    Example reply:
    {"new_lines_about":"choosing a page to evict","new_lines_kind":"new_concept","action":"new_topic","boundary_quote":"okay so what happens when memory is full","closed_summary":"Virtual addresses are split into page number and offset; the page table maps each page to a physical frame, with a valid bit for pages in memory.","title":"Page replacement","summary":"When no frame is free, the OS evicts a victim page; LRU evicts the least recently used page and approximates the optimal (Belady) policy.","slides":[14,15]}
    """

    struct SegmentationInput: Sendable {
        var lecture: Lecture
        var digest: String
        /// The current topic's transcript window, ending with the new lines.
        var transcript: String
        /// Start time of the first new line, nil for a final pass without new text.
        var newLinesFrom: TimeInterval?
        var liveTitle: String?
        var liveSummary: String?
        /// How long the live topic has run, in seconds.
        var liveDuration: TimeInterval?
        var earlierTitles: [String]
        /// "[S9] Title; [S10] Title" — slides shown during the current topic / the new lines.
        var slidesInTopic: String?
        var slidesInNewLines: String?
        var slides: String?
        var isFinal: Bool
    }

    static func segmentation(_ input: SegmentationInput) -> [LLMMessage] {
        var tail: [String] = []
        if !input.earlierTitles.isEmpty {
            tail.append("EARLIER TOPICS: " + input.earlierTitles.map { "\"\($0)\"" }.joined(separator: "; "))
        }
        if let title = input.liveTitle {
            let minutes = input.liveDuration.map { " (running \(max(1, Int(($0 / 60).rounded()))) min)" } ?? ""
            tail.append("CURRENT TOPIC\(minutes): \"\(title)\" — \(input.liveSummary ?? "")")
        } else {
            tail.append("CURRENT TOPIC: none yet")
        }
        if let from = input.newLinesFrom {
            tail.append("NEW LINES: everything from [\(TimeFormat.clock(from))] to the end of the transcript.")
        }
        if let shown = input.slidesInTopic { tail.append("SLIDES SHOWN DURING CURRENT TOPIC: " + shown) }
        if let shown = input.slidesInNewLines {
            tail.append("SLIDES SHOWN DURING NEW LINES: " + shown + " (a slide with a new concept often starts a new topic)")
        }
        if let slides = input.slides { tail.append("RELEVANT SLIDES:\n" + slides) }

        let task: String
        switch (input.liveTitle, input.newLinesFrom, input.isFinal) {
        case (let title?, nil, _):
            task = """
            The lecture has ended. Reply "continue" with the final title and summary for "\(title)".
            """
        case (let title?, _, let isFinal):
            task = """
            Do the new lines start explaining a different concept or step than "\(title)"? If so, \
            reply "new_topic" with boundary_quote (where the new concept starts), closed_summary for \
            "\(title)", and title and summary for the new topic. If they still explain "\(title)", \
            reply "continue" with a title and summary for the whole topic.
            """ + splitPressure(title: title, duration: input.liveDuration ?? 0)
                + (isFinal ? " The lecture ends after these lines." : "")
        case (nil, _, _):
            task = """
            No topic has started yet. If the new lines contain real lecture content, reply \
            "new_topic" with boundary_quote (the first words of that content), title and summary; \
            leave closed_summary empty. If they are only greetings, admin or logistics, reply \
            "continue" with empty title and summary.
            """
        }
        tail.append("TASK: " + task + " Reply with JSON only.")

        let user = "TRANSCRIPT:\n" + input.transcript + "\n\n=====\n" + tail.joined(separator: "\n\n")
        return [system(summariesInstructions, lecture: input.lecture, digest: input.digest), .user(user)]
    }

    /// Escalating nudge as the live topic ages past the ~5-minute target.
    static func splitPressure(title: String, duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        switch duration {
        case ..<(4 * 60):
            return ""
        case ..<(7 * 60):
            return " \"\(title)\" has run \(minutes) min; topics in this lecture typically last about 5."
        default:
            return " \"\(title)\" has run \(minutes) min, longer than a typical topic (about 5). Unless the new lines are clearly still the same single idea, reply \"new_topic\" at the first point where a new concept, step or slide section begins."
        }
    }

    struct DetailInput: Sendable {
        var lecture: Lecture
        var digest: String
        var title: String
        var summary: String
        var start: TimeInterval
        var end: TimeInterval
        var slides: String?
        var transcript: String
    }

    static func detail(_ input: DetailInput) -> [LLMMessage] {
        let user = """
        TOPIC: "\(input.title)" [\(TimeFormat.clock(input.start))–\(TimeFormat.clock(input.end))]
        SUMMARY: \(input.summary)
        \(input.slides.map { "SLIDES FOR THIS TOPIC:\n\($0)\n" } ?? "")
        TRANSCRIPT OF THIS TOPIC:
        \(input.transcript)

        =====
        TASK: Write detailed study notes for this one topic, using only the transcript and slides above.
        Reply with one JSON object:
        - bullets: 4-7 bullets. Each is one or two plain sentences (no markdown), specific and \
        technical: definitions, the steps of the algorithm, conditions and edge cases, pitfalls the \
        lecturer stressed. Skip admin and chit-chat.
        - key_terms: 2-5 terms used in this topic, each with a one-line definition (at most 20 words).
        - example: a small worked example or intuition from the lecture in 2-4 sentences, or "" if \
        the lecture gave none.
        If a student asked a good question that the lecturer answered, one bullet may be \
        "Q: <question> A: <answer>".
        Reply with JSON only.
        """
        return [system(summariesInstructions, lecture: input.lecture, digest: input.digest), .user(user)]
    }

    struct RecapInput: Sendable {
        var lecture: Lecture
        var digest: String
        var from: TimeInterval
        var to: TimeInterval
        var transcript: String
        var topics: String?
        var announcements: String?
    }

    /// "While you were away": summaries-role prefix, then the missed stretch, then the task.
    static func recap(_ input: RecapInput) -> [LLMMessage] {
        let span = "[\(TimeFormat.clock(input.from))–\(TimeFormat.clock(input.to))]"
        var parts = ["TRANSCRIPT \(span):\n" + input.transcript]
        if let topics = input.topics { parts.append("TOPICS IN THIS STRETCH:\n" + topics) }
        if let announcements = input.announcements { parts.append("POSSIBLE ANNOUNCEMENTS:\n" + announcements) }
        let task = """
        =====
        TASK: The student looked away from \(span). Catch them up in a few seconds of reading.
        Reply with one JSON object:
        - headline: one sentence on what happened, e.g. "Finished FIRST sets and started building the LL(1) parse table."
        - bullets: 2-4 short bullets of what was covered, most important first. Specific and technical.
        - flagged: things the lecturer flagged in this stretch: exam hints ("this will be on the exam"), \
        deadlines, announcements, "this is important". Only what was actually said; [] if none.
        - slides: numbers of the slides covered; [] if unsure.
        Reply with JSON only.
        """
        return [system(summariesInstructions, lecture: input.lecture, digest: input.digest),
                .user(parts.joined(separator: "\n\n") + "\n\n" + task)]
    }

    // MARK: - Quizzes role

    static let quizInstructions = """
    You help a student check their understanding during a university computer science lecture. You \
    write short quiz questions about what was just taught and give feedback on the student's answers.

    Questions:
    - Test one important idea from the lecture material you are given: a definition, a rule, a step \
    of an algorithm, a consequence. Never test trivia, names, dates or admin.
    - The question must be answerable from that material alone, and must stand on its own: do not \
    say "according to the slides" or "in the lecture".
    - One or two sentences. Plain text only, no LaTeX or "$": write notation directly, for example \
    FIRST(A), A → B c, ε.
    - Difficulty "gentle": recall a key definition or fact. "standard": understand or apply the idea \
    (why, what happens, which one). "challenging": apply it to a small new case or an edge case.

    Feedback:
    - Be brief, specific and kind. Never say "Great job!" or use exclamation marks.
    - When the answer is wrong, explain the correct idea in at most 3 sentences and cite where it was \
    taught: [S12] for slide 12, [T14:32] for the transcript at 14:32. Only cite slides and times that \
    appear in the material.

    The transcript comes from speech recognition and may contain misheard terms; prefer the slides' \
    spelling. Lines starting with "Student:" are from the audience: never base a question or an \
    answer key on a student's guess.
    """

    struct QuizMaterial: Sendable {
        var lecture: Lecture
        var digest: String
        var topic: String
        var summary: String
        var slides: String?
        var transcript: String

        var block: String {
            """
            TOPIC: \(topic)\(summary.isEmpty ? "" : " — \(summary)")
            \(slides.map { "SLIDES:\n\($0)\n" } ?? "")
            TRANSCRIPT:
            \(transcript)
            """
        }
    }

    static func quizQuestion(
        _ material: QuizMaterial,
        format: QuizPlanner.Format,
        difficulty: QuizSettings.Difficulty,
        avoid: [String],
        followUp: (question: QuizQuestion, answer: String?)?
    ) -> [LLMMessage] {
        var task: [String] = []
        if let followUp {
            var lines = [
                "The student got this question wrong:",
                "QUESTION: \(followUp.question.prompt)",
            ]
            if case let .multipleChoice(options, correct) = followUp.question.kind {
                lines.append("CORRECT ANSWER: \(options[correct])")
                if let answer = followUp.answer, let i = QuizPlanner.choiceIndex(answer, options: options) {
                    lines.append("STUDENT CHOSE: \(options[i])")
                }
            } else if case let .shortAnswer(reference) = followUp.question.kind {
                lines.append("REFERENCE ANSWER: \(reference)")
                if let answer = followUp.answer { lines.append("STUDENT WROTE: \(answer)") }
            }
            lines.append("Write a NEW question on the same concept (\"\(followUp.question.concept)\") from a different angle, for example an example instead of a definition. It must not be answerable by remembering the answer above.")
            task.append(lines.joined(separator: "\n"))
        } else {
            task.append("Write one \(difficulty.rawValue) question about the most important idea of this topic.")
        }
        if !avoid.isEmpty {
            task.append("Do not repeat or rephrase these earlier questions:\n" + avoid.map { "- \($0)" }.joined(separator: "\n"))
        }
        switch format {
        case .multipleChoice:
            task.append("""
            Format: multiple choice. Reply with one JSON object:
            - concept: the idea tested, 2-5 words.
            - question: the question.
            - correct_answer: the correct option.
            - distractors: exactly 3 wrong options that a student who half-understood might pick. \
            Similar length and style to the correct answer, each clearly wrong. No "all of the above" \
            or "none of the above".
            - explanation: 1-2 sentences on why the correct answer is right.
            - slides: numbers of the slides where the answer is taught; [] if none.
            """)
        case .shortAnswer:
            task.append("""
            Format: short answer, answerable in one sentence. Reply with one JSON object:
            - concept: the idea tested, 2-5 words.
            - question: the question.
            - reference_answer: a complete model answer in 1-2 sentences with the key point a grader needs.
            - slides: numbers of the slides where the answer is taught; [] if none.
            """)
        }
        task.append("Reply with JSON only.")
        let user = material.block + "\n\n=====\nTASK: " + task.joined(separator: "\n\n")
        return [system(quizInstructions, lecture: material.lecture, digest: material.digest), .user(user)]
    }

    static func multipleChoiceFeedback(
        _ material: QuizMaterial,
        question: QuizQuestion,
        options: [String],
        correct: Int,
        chosen: Int,
        explanation: String?
    ) -> [LLMMessage] {
        let letters = ["A", "B", "C", "D", "E", "F"]
        let listed = options.enumerated().map { "\(letters[min($0.offset, 5)])) \($0.element)" }.joined(separator: "\n")
        let isCorrect = correct == chosen
        let instruction = isCorrect
            ? "The student is correct. Reply with one short sentence that confirms why the answer is right. Plain text only."
            : "The student is wrong. In at most 3 sentences, explain why the correct answer is right and why their choice is not, citing [S#] or [T#:##] from the material. Refer to options by their content, never by letter. Plain text only, no preamble."
        let user = """
        \(material.block)

        =====
        QUESTION: \(question.prompt)
        OPTIONS:
        \(listed)
        CORRECT: \(letters[min(correct, 5)])) \(options[correct])
        STUDENT CHOSE: \(letters[min(chosen, 5)])) \(options[chosen])
        \(explanation.map { "WHY (from the question writer): \($0)\n" } ?? "")
        TASK: \(instruction)
        """
        return [system(quizInstructions, lecture: material.lecture, digest: material.digest), .user(user)]
    }

    static func shortAnswerGrading(_ material: QuizMaterial, question: QuizQuestion, reference: String, answer: String) -> [LLMMessage] {
        let user = """
        \(material.block)

        =====
        QUESTION: \(question.prompt)
        REFERENCE ANSWER: \(reference)
        STUDENT ANSWER: \(answer)

        TASK: Grade the student's answer against the reference answer. Be lenient: accept an answer \
        that captures the key idea in other words, even if it is informal, incomplete in minor \
        details, or has typos. Mark it wrong if the key idea is missing or incorrect.
        Reply with one JSON object:
        - correct: true or false.
        - feedback: if correct, one short sentence; if wrong, at most 3 sentences explaining the \
        correct idea, citing [S#] or [T#:##] from the material.
        Reply with JSON only.
        """
        return [system(quizInstructions, lecture: material.lecture, digest: material.digest), .user(user)]
    }

    // MARK: - Ask role

    static let askInstructions = """
    You are the study assistant in a lecture app. Answer the student's questions about the lecture \
    they are attending, using the lecture context sent with each question: topic summaries, slides \
    and transcript excerpts.

    - Answer first, in 1-4 sentences or a few short bullets. Add detail only when asked.
    - Cite your sources right after the claim they support: [S12] for slide 12, [T14:32] for the \
    transcript at 14:32. Only cite slide numbers and times that appear in the context.
    - If the lecture material doesn't cover the question, say "This wasn't covered in the lecture so \
    far." Then give a brief general answer and say it is general background, not from the lecture.
    - The transcript comes from speech recognition and may contain misheard words; prefer the \
    slides' spelling of terms. Lines starting with "Student:" are audience questions or comments, \
    not the lecturer.
    - Use plain Markdown sparingly (bold, bullets, `code`). No headings. No LaTeX or "$…$": write \
    symbols directly (α, ε, →, ∈).
    """

    struct AskContext: Sendable {
        var lecture: Lecture
        var digest: String
        var topics: String?
        var slides: String?
        var excerpts: String?
        var recent: String?
        var question: String
    }

    static func ask(_ context: AskContext, history: [LLMMessage]) -> [LLMMessage] {
        var parts: [String] = ["LECTURE CONTEXT FOR THIS QUESTION"]
        parts.append("TOPICS SO FAR:\n" + (context.topics ?? "(none yet)"))
        if let slides = context.slides { parts.append("SLIDES:\n" + slides) }
        if let excerpts = context.excerpts { parts.append("TRANSCRIPT EXCERPTS:\n" + excerpts) }
        if let recent = context.recent { parts.append("MOST RECENT TRANSCRIPT:\n" + recent) }
        if context.slides == nil, context.excerpts == nil, context.recent == nil {
            parts.append("(No slides or transcript matched this question.)")
        }
        parts.append("=====\nQUESTION: " + context.question)
        return [system(askInstructions, lecture: context.lecture, digest: context.digest)] + history + [.user(parts.joined(separator: "\n\n"))]
    }

    // MARK: - Course-wide Ask

    static let courseInstructions = """
    You are the study assistant for a university course. Answer the student's question using the \
    course material sent with it: excerpts from several lectures' slides, transcripts and topic \
    summaries.

    - Answer first, in 1-5 sentences or a few short bullets. Add detail only when asked.
    - Say which lecture something came from, for example "In lecture 8, ...".
    - Cite right after each claim: [L8 S12] for lecture 8, slide 12; [L9 T14:32] for lecture 9's \
    transcript at 14:32. Only cite lectures, slides and times that appear in the material.
    - If the course material doesn't cover the question, say "This hasn't come up in the lectures \
    so far." Then give a brief general answer and say it is general background.
    - Transcripts come from speech recognition and may contain misheard words; prefer the slides' \
    spelling. Lines marked "Student:" are audience questions or comments.
    - Use plain Markdown sparingly (bold, bullets, `code`). No headings. No LaTeX or "$…$": write \
    symbols directly (α, ε, →, ∈).
    """

    /// Stable prefix: instructions, the course name and the lecture index; then prior turns; then
    /// the retrieved material and the question.
    static func courseAsk(courseName: String?, lectureIndex: String, material: String?, question: String, history: [LLMMessage]) -> [LLMMessage] {
        let course = courseName.map { "Course: \(Text.collapse($0))\n\n" } ?? ""
        let system = LLMMessage.system(courseInstructions + "\n\n" + course + "LECTURES:\n" + lectureIndex)
        let body = "COURSE MATERIAL FOR THIS QUESTION\n\n" + (material ?? "(Nothing in the lectures matched this question.)")
            + "\n\n=====\nQUESTION: " + question
        return [system] + history + [.user(body)]
    }
}

