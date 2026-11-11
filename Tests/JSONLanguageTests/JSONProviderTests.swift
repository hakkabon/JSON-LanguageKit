import Foundation
import IncrementalParsing
import JSONLanguage
import Testing

@Suite("JSON language provider")
struct JSONProviderTests {
    @Test func validatesRecoversAndReusesLexing() async throws {
        let session = JSONProvider().makeToolingSession()
        let first = SourceSnapshot(text: #"{"name": [1, true]}"#, revision: .init(1))
        let clean = try await session.analyze(first)
        #expect(clean.diagnostics.isEmpty)
        #expect(clean.tokens.contains { $0.classification == "string" })

        let location = (first.text as NSString).range(of: ",").location
        let change = try SourceEdit(
            baseRevision: first.revision,
            range: .init(location: location, length: 1), replacement: "")
            .applying(to: first)
        let recovered = try await session.analyze(change.after, change: change)
        #expect(recovered.evidence(for: "lexing")?.strategy == .incremental)
        #expect(recovered.diagnostics.contains { $0.expected == [","] })
        #expect(!recovered.recoveryEdits.isEmpty)
        #expect(recovered.recoveryEdits.contains {
            if case .insert(let terminal, let offset) = $0.action {
                return terminal == "," && offset > 0
            }
            return false
        })
        #expect(recovered.recoveryEdits.allSatisfy { $0.diagnosticID != nil })
    }

    @Test func formatsAndPublishesSemanticTokens() async throws {
        let session = JSONProvider().makeToolingSession()
        let snapshot = SourceSnapshot(text: #"{"b":2,"a":1}"#, revision: .init(1))
        _ = try await session.analyze(snapshot)
        #expect(try await session.format(snapshot).contains("\n  \"a\" : 1"))
        #expect(!(try await session.semanticTokens()).data.isEmpty)
    }

    @Test func rejectsTrailingCommasAndInvalidEscapes() async throws {
        let session = JSONProvider().makeToolingSession()
        let result = try await session.analyze(.init(
            text: #"{"bad":"\q",}"#, revision: .init(1)))
        #expect(result.diagnostics.contains {
            $0.message.contains("Invalid JSON string escape")
        })
        #expect(result.diagnostics.contains { $0.message.contains("Trailing comma") })
    }
}
