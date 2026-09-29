import Testing

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test func normalizesCaseAndPunctuation() {
        #expect(WordErrorRate.words("It's LL(1), isn't it?") == ["its", "ll", "1", "isnt", "it"])
    }

    @Test func countsSubstitutionsDeletionsInsertions() {
        let result = WordErrorRate.compare(
            reference: ["the", "first", "set", "of", "a"], hypothesis: ["the", "1st", "set", "of", "a", "grammar"]
        )
        #expect(result.errors == 2)
        #expect(result.substitutions == 1 && result.insertions == 1 && result.deletions == 0)
        #expect(result.rate == 0.4)
    }

    @Test func emptySides() {
        #expect(WordErrorRate.compare(reference: [], hypothesis: ["a"]).errors == 1)
        #expect(WordErrorRate.compare(reference: ["a", "b"], hypothesis: []).rate == 1)
    }
}
