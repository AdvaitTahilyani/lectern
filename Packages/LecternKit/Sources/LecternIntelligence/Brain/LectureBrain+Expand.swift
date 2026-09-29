import Foundation
import LecternCore

// MARK: - Expand

extension LectureBrain {
    static let maxBullets = 7
    static let maxKeyTerms = 6

    public func expand(takeawayID: UUID) async throws -> TakeawayDetail {
        guard let takeaway = timeline.takeaways.first(where: { $0.id == takeawayID }) else { throw BrainError.unknownTakeaway }
        let fingerprint = CachedDetail.Fingerprint(takeaway)
        if let cached = detailCache[takeawayID], cached.fingerprint == fingerprint { return cached.detail }

        let input = Prompts.DetailInput(
            lecture: lecture,
            digest: digest,
            title: takeaway.title,
            summary: takeaway.summary,
            start: takeaway.start,
            end: takeaway.end,
            slides: excerpts.render(pages: takeaway.slidePages, query: takeaway.title + " " + takeaway.summary,
                                    hits: takeaway.slidePages.isEmpty ? 2 : 0, budgetTokens: TokenBudget.detailSlides),
            transcript: TranscriptText.renderFitting(
                TranscriptText.segments(in: segments, from: takeaway.start, to: takeaway.end),
                maxTokens: TokenBudget.detailTranscript)
        )
        let detail = try await withRole(.summaries, .expanding(takeawayID: takeawayID)) {
            try await StructuredGeneration.generate(
                DetailReply.self, provider: providers.summaries,
                messages: Prompts.detail(input), profile: .detail,
                validate: Self.makeDetail
            )
        }
        detailCache[takeawayID] = CachedDetail(fingerprint: fingerprint, detail: detail)
        // Attach it only if the takeaway hasn't been refined while we were writing.
        if let current = timeline.takeaways.first(where: { $0.id == takeawayID }), CachedDetail.Fingerprint(current) == fingerprint {
            timeline.setDetail(detail, for: takeawayID)
            emit(.takeaways(timeline.takeaways))
        }
        return detail
    }

    static func makeDetail(_ reply: DetailReply) throws -> TakeawayDetail {
        let bullets = reply.bullets.map { PlainMath.clean(Text.collapse($0)).trimmingCharacters(in: CharacterSet(charactersIn: "-•*· ")) }.filter { !$0.isEmpty }
        guard bullets.count >= 2 else { throw ReplyRejected(reason: "\"bullets\" needs 4-7 specific bullet points.") }
        let terms = reply.keyTerms.filter(\.isUsable).prefix(maxKeyTerms).map {
            KeyTerm(term: PlainMath.clean($0.term), definition: PlainMath.clean($0.definition))
        }
        return TakeawayDetail(bullets: Array(bullets.prefix(maxBullets)), keyTerms: terms, example: reply.example.map { PlainMath.clean($0) })
    }
}
