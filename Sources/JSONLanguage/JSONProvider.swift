import Foundation
import Grammar
import IncrementalParsing
import LanguageTooling
import Lexer

public struct JSONProvider: LanguageToolingProvider {
    public let descriptor = LanguageProviderDescriptor(
        id: "json", displayName: "JSON", fileExtensions: ["json"],
        distribution: .bundledPermanent,
        capabilities: [
            .syntaxHighlighting, .incrementalAnalysis, .diagnostics,
            .recovery, .formatting,
        ])

    public init() {}
    public func makeToolingSession() -> any LanguageToolingSession {
        JSONProviderSession()
    }
}

public actor JSONProviderSession: LanguageToolingSession {
    private var tokenizer: GrammarIncrementalTokenizer
    private var text: String?
    private var revision: SourceRevision?
    private var elements: [GrammarLexicalElement] = []

    public init() {
        do {
            tokenizer = RestartAndConvergeTokenizer(
                scanner: try GrammarDrivenLexer(specification: Self.specification))
        } catch {
            preconditionFailure("Invalid JSON lexical specification: \(error)")
        }
    }

    public func analyze(_ snapshot: SourceSnapshot, change: SourceChange?) async throws
        -> LanguageProviderAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let result = tokenizer.tokenize(snapshot: snapshot, change: change)
        text = snapshot.text
        revision = snapshot.revision
        elements = result.output.elements

        var parser = JSONStructureParser(tokens: result.output.tokens)
        parser.parse()
        let lexicalDiagnostics = result.output.diagnostics.map {
            LanguageProviderDiagnostic(
                severity: .error, message: $0.message,
                range: SourceRange($0.range.lowerBound, $0.range.upperBound))
        } + Self.invalidStringDiagnostics(in: result.output.tokens)
        let metrics = result.metrics
        return LanguageProviderAnalysis(
            languageID: "json", revision: snapshot.revision,
            tokens: Self.providerTokens(result.output.elements),
            diagnostics: lexicalDiagnostics + parser.diagnostics,
            recoveryEdits: parser.recoveryEdits,
            operations: [
                .init(operation: "lexing", evidence: .init(
                    strategy: metrics.incremental ? .incremental : .full,
                    measurements: [.init(
                        dimension: .tokens,
                        reused: metrics.reusedPrefixTokenCount
                            + metrics.reusedSuffixTokenCount,
                        rebuilt: metrics.generatedTokenCount,
                        strategy: metrics.incremental
                            ? "restart-and-converge" : "full-tokenization")])),
                .init(operation: "parsing", evidence: .init(
                    strategy: .full,
                    measurements: [.init(
                        dimension: .init(rawValue: "jsonValues"),
                        reused: 0, rebuilt: parser.valueCount,
                        strategy: "recursive-structure-validation")]))
            ])
    }

    public func format(_ snapshot: SourceSnapshot) async throws -> String {
        let data = Data(snapshot.text.utf8)
        let value = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed])
        let formatted = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: formatted, as: UTF8.self) + "\n"
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let text, let revision else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(text)
        let tokens = Self.providerTokens(elements).compactMap { token -> ToolingSemanticToken? in
            guard let type = Self.semanticType(token.classification) else { return nil }
            return ToolingSemanticToken(range: map.toolingRange(token.range), type: type)
        }
        return SemanticTokenEncoder.encode(tokens, resultID: "json:\(revision.rawValue)")
    }

    private static let specification = LexicalSpecification(rules: [
        .init(name: "WHITESPACE", matcher: .regularExpression(#"\s+"#), channel: .trivia),
        .init(name: "STRING", matcher: .regularExpression(#"\"(?:\\.|[^\"\\])*\""#)),
        .init(name: "NUMBER", matcher: .regularExpression(
            #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#)),
        .init(name: "TRUE", matcher: .literal("true")),
        .init(name: "FALSE", matcher: .literal("false")),
        .init(name: "NULL", matcher: .literal("null")),
        .init(name: "LBRACE", matcher: .literal("{")),
        .init(name: "RBRACE", matcher: .literal("}")),
        .init(name: "LBRACKET", matcher: .literal("[")),
        .init(name: "RBRACKET", matcher: .literal("]")),
        .init(name: "COLON", matcher: .literal(":")),
        .init(name: "COMMA", matcher: .literal(",")),
    ])

    private static func providerTokens(
        _ elements: [GrammarLexicalElement]
    ) -> [LanguageProviderToken] {
        elements.compactMap { element in
            let classification: String
            switch element.kind {
            case .trivia: return nil
            case .invalid: classification = "invalid"
            case .token(let kind):
                switch kind {
                case "STRING": classification = "string"
                case "NUMBER": classification = "number"
                case "TRUE", "FALSE", "NULL": classification = "keyword"
                default: classification = "operator"
                }
            }
            return .init(
                range: SourceRange(element.range.lowerBound, element.range.upperBound),
                classification: classification)
        }
    }

    private static func invalidStringDiagnostics(
        in tokens: [GrammarLexicalToken]
    ) -> [LanguageProviderDiagnostic] {
        tokens.compactMap { token in
            guard token.kind == "STRING" else { return nil }
            do {
                _ = try JSONSerialization.jsonObject(
                    with: Data(token.lexeme.utf8), options: [.fragmentsAllowed])
                return nil
            } catch {
                return .init(
                    severity: .error, message: "Invalid JSON string escape",
                    range: SourceRange(token.range.lowerBound, token.range.upperBound))
            }
        }
    }

    private static func semanticType(
        _ classification: String
    ) -> ToolingSemanticTokenType? {
        switch classification {
        case "string": .string
        case "number": .number
        case "keyword": .keyword
        case "operator": .operatorToken
        default: nil
        }
    }
}

private struct JSONStructureParser {
    let tokens: [GrammarLexicalToken]
    var index = 0
    var diagnostics: [LanguageProviderDiagnostic] = []
    var recoveryEdits: [LanguageProviderRecoveryEdit] = []
    var valueCount = 0

    mutating func parse() {
        parseValue()
        while current != "$EOF" {
            deleteCurrent("Unexpected token after the JSON value")
        }
    }

    private var current: String { tokens[index].kind }
    private var currentRange: SourceRange {
        let range = tokens[index].range
        return SourceRange(range.lowerBound, range.upperBound)
    }

    private mutating func parseValue() {
        valueCount += 1
        switch current {
        case "LBRACE": parseObject()
        case "LBRACKET": parseArray()
        case "STRING", "NUMBER", "TRUE", "FALSE", "NULL": advance()
        case "$EOF": insert("value", message: "Expected a JSON value")
        default: deleteCurrent("Expected a JSON value"); if current != "$EOF" { parseValue() }
        }
    }

    private mutating func parseObject() {
        advance()
        if consume("RBRACE") { return }
        while current != "$EOF" && current != "RBRACE" {
            if current == "STRING" { advance() }
            else { insert("string", message: "Expected an object member name") }
            expect("COLON", spelling: ":", message: "Expected ':' after member name")
            parseValue()
            if consume("COMMA") {
                if current == "RBRACE" { trailingComma(before: "}") }
                continue
            }
            if current != "RBRACE" {
                insert(",", message: "Expected ',' between object members")
            }
        }
        expect("RBRACE", spelling: "}", message: "Expected '}' to close object")
    }

    private mutating func parseArray() {
        advance()
        if consume("RBRACKET") { return }
        while current != "$EOF" && current != "RBRACKET" {
            parseValue()
            if consume("COMMA") {
                if current == "RBRACKET" { trailingComma(before: "]") }
                continue
            }
            if current != "RBRACKET" {
                insert(",", message: "Expected ',' between array elements")
            }
        }
        expect("RBRACKET", spelling: "]", message: "Expected ']' to close array")
    }

    private mutating func expect(_ kind: String, spelling: String, message: String) {
        if !consume(kind) { insert(spelling, message: message) }
    }

    private mutating func consume(_ kind: String) -> Bool {
        guard current == kind else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        if index + 1 < tokens.count { index += 1 }
    }

    private mutating func insert(_ terminal: String, message: String) {
        diagnostics.append(.init(
            severity: .error, message: message,
            range: SourceRange(location: currentRange.location, length: 0),
            expected: [terminal]))
        recoveryEdits.append(.insert(terminal: terminal, atToken: index))
    }

    private mutating func deleteCurrent(_ message: String) {
        diagnostics.append(.init(
            severity: .error, message: message, range: currentRange))
        recoveryEdits.append(.delete(terminal: current, atToken: index))
        advance()
    }

    private mutating func trailingComma(before closing: String) {
        let commaIndex = max(0, index - 1)
        let range = tokens[commaIndex].range
        diagnostics.append(.init(
            severity: .error,
            message: "Trailing comma is not allowed before '\(closing)'",
            range: SourceRange(range.lowerBound, range.upperBound)))
        recoveryEdits.append(.delete(terminal: ",", atToken: commaIndex))
    }
}
