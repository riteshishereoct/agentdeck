import Foundation

public struct QuestionSpec: Equatable {
    public var question: String
    public var header: String?
    public var options: [String]
    public var multiSelect: Bool
    public var descriptions: [String?]      // parallel to `options`; the agent's per-option explanation, if any
    public init(question: String, header: String?, options: [String], multiSelect: Bool, descriptions: [String?] = []) {
        self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
        self.descriptions = descriptions.isEmpty ? options.map { _ in nil } : descriptions
    }
}

public struct QuestionSelection: Equatable {
    public var chosen: [String: Set<Int>]
    public var other: [String: String]
    public init(chosen: [String: Set<Int>] = [:], other: [String: String] = [:]) {
        self.chosen = chosen; self.other = other
    }

    /// Picking an option discards that question's Other text, so what is submitted is what is visibly selected.
    public mutating func toggle(_ index: Int, in spec: QuestionSpec) {
        var set = chosen[spec.question] ?? []
        if spec.multiSelect { if !set.insert(index).inserted { set.remove(index) } } else { set = [index] }
        chosen[spec.question] = set.isEmpty ? nil : set
        other[spec.question] = nil
    }

    /// Typing a non-blank Other answer replaces any chosen options for that question.
    public mutating func setOther(_ text: String, for spec: QuestionSpec) {
        other[spec.question] = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chosen[spec.question] = nil }
    }
}

public enum QuestionForm {
    public static func parse(_ input: JSONValue) -> [QuestionSpec] {
        guard case .array(let questions)? = input["questions"], !questions.isEmpty else { return [] }
        var specs: [QuestionSpec] = []
        for item in questions {
            guard let question = item["question"]?.stringValue,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !specs.contains(where: { $0.question == question }),
                  case .array(let values)? = item["options"], values.count >= 2 else { return [] }   // upstream requires 2–4 options
            var labels: [String] = [], descriptions: [String?] = []
            for value in values {
                guard let label = value["label"]?.stringValue,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !labels.contains(label) else { return [] }
                labels.append(label)
                descriptions.append(value["description"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })
            }
            if let multi = item["multiSelect"], case .bool = multi {} else if item["multiSelect"] != nil { return [] }
            specs.append(QuestionSpec(question: question, header: item["header"]?.stringValue,
                                      options: labels, multiSelect: item["multiSelect"] == .bool(true), descriptions: descriptions))
        }
        return specs
    }

    public static func answers(_ specs: [QuestionSpec], _ sel: QuestionSelection) -> [String: String]? {
        guard !specs.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for spec in specs {
            let other = (sel.other[spec.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = sel.chosen[spec.question] ?? []
            if !other.isEmpty {
                guard selected.isEmpty else { return nil }   // both visible: ambiguous, never guess which one wins
                answers[spec.question] = other; continue
            }
            guard !selected.isEmpty, selected.allSatisfy(spec.options.indices.contains),
                  spec.multiSelect || selected.count == 1 else { return nil }
            // shortcut: multi-select separator ", " is assumed (single and Other verified live; multi not); confirm against live Cursor.
            answers[spec.question] = selected.sorted().map { spec.options[$0] }.joined(separator: ", ")
        }
        return answers
    }

    /// Plain text of every question for read-only cards: header, full question, how many to pick, every option and its description.
    /// "" when the input does not parse (the caller then shows the raw input).
    public static func readable(_ input: JSONValue) -> String {
        parse(input).map { s -> String in
            var lines: [String] = s.header.flatMap { $0.isEmpty ? nil : [$0] } ?? []
            lines += [s.question, s.multiSelect ? "(Choose any)" : "(Choose one)"]
            for (label, d) in zip(s.options, s.descriptions) { lines.append("• \(label)" + (d.map { " — \($0)" } ?? "")) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
