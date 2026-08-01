import Foundation

@testable import UnrambleKit

// ---------------------------------------------------------------------------
// Shared test data for polish scenario tests. The complete scenario corpus is
// private and loaded from the local-only archive when it is present.
//
// Each scenario has a category, raw dictation input, and one or more
// acceptable polished outputs. Optional style and preceding_text fields
// control the system prompt sent to the model.
// ---------------------------------------------------------------------------

/// A single polish scenario with category, raw input, and acceptable outputs.
struct PolishScenario {
    let category: String
    let input: String
    let accepted: [String]
    let style: String?
    let precedingText: String?
    let context: AppContext

    init(category: String, input: String, accepted: [String],
         style: String? = nil, precedingText: String? = nil,
         context: AppContext = .empty) {
        self.category = category
        self.input = input
        self.accepted = accepted
        self.style = style
        self.precedingText = precedingText
        self.context = context
    }

    func matches(_ output: String) -> Bool {
        let normalize = { (s: String) in
            s.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2018}", with: "'")
             .replacingOccurrences(of: "\u{201C}", with: "\"")
             .replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        let normalizedOutput = normalize(output)
        return accepted.contains { normalize($0) == normalizedOutput }
    }

    /// Build the system prompt for this scenario, including optional
    /// style and preceding text context.
    func systemPrompt() -> String {
        var prompt = PolishPipeline.systemPromptQwen
        if let style {
            prompt += "\nStyle: \(style)"
        }
        if let precedingText, !precedingText.isEmpty {
            prompt += "\nPreceding text: \(precedingText)"
        }
        return prompt
    }
}

/// All locally available private polish scenarios. Scenario-backed suites use
/// an explicit disabled trait when this array is empty, avoiding vacuous tests
/// on a clean public checkout.
let allScenarios: [PolishScenario] = loadScenarios(from: "polish-tests.json")

/// Load scenarios from a JSON file, applying environment-based filters.
///
/// - `UNRAMBLE_TEST_CATEGORIES=list,meeting` — run only these categories
/// - `UNRAMBLE_TEST_NO_CASUAL=1` — exclude casual scenarios
private func loadScenarios(from filename: String) -> [PolishScenario] {
    guard let url = findPrivateScenarioFile(filename) else { return [] }
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    else {
        fatalError("Failed to parse \(filename)")
    }
    var scenarios = entries.map { scenarioFromEntry($0) }

    // Filter by category if specified (env var or flag file).
    if let cats = flagFileOrEnv(
        "UNRAMBLE_TEST_CATEGORIES",
        flagPath: "/tmp/unramble-test-categories"),
       !cats.isEmpty {
        let allowed = Set(cats.split(separator: ",").map(String.init))
        scenarios = scenarios.filter { allowed.contains($0.category) }
    }

    // Exclude casual if specified.
    if ProcessInfo.processInfo.environment["UNRAMBLE_TEST_NO_CASUAL"] == "1" {
        scenarios = scenarios.filter { $0.style != "casual" }
    }

    return scenarios
}

/// Choose which scenario set the model eval harness runs over.
///
/// Pointed at a file via `UNRAMBLE_EVAL_FILE`, load that set; otherwise run
/// over the full scenario set.
func evalScenarios() -> [PolishScenario] {
    // Load an arbitrary eval set (ScenarioEntry JSON) when pointed at a file.
    if let path = flagFileOrEnv(
        "UNRAMBLE_EVAL_FILE", flagPath: "/tmp/unramble-eval-file"),
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let entries = try? JSONDecoder().decode([ScenarioEntry].self, from: data)
    {
        return entries.map(scenarioFromEntry)
    }
    return allScenarios
}

/// Read a flag file's contents as a comma-separated category filter,
/// or fall back to the environment variable.
private func flagFileOrEnv(_ envKey: String, flagPath: String) -> String? {
    if let content = try? String(contentsOfFile: flagPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !content.isEmpty {
        return content
    }
    return ProcessInfo.processInfo.environment[envKey]
}

/// Build a PolishScenario from a JSON entry, constructing an AppContext
/// that reflects the scenario's style and preceding text so that
/// `buildCloudSystemPrompt` and `toneLabel` work correctly.
private func scenarioFromEntry(_ entry: ScenarioEntry) -> PolishScenario {
    let bundleID = entry.style == "casual"
        ? "com.tinyspeck.slackmacgap" : ""
    let context = AppContext(
        bundleID: bundleID,
        appName: "",
        windowTitle: "",
        focusedFieldContent: entry.preceding_text)
    return PolishScenario(
        category: entry.category, input: entry.input,
        accepted: entry.accepted,
        style: entry.style, precedingText: entry.preceding_text,
        context: context)
}

// MARK: - JSON loading

private struct ScenarioEntry: Decodable {
    let category: String
    let input: String
    let accepted: [String]
    let style: String?
    let preceding_text: String?
}

private func findPrivateScenarioFile(_ name: String) -> URL? {
    let starts = [
        URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    ]
    for start in starts {
        var directory = start
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(
                ".scratch/archive/local-only/training/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
    }
    return nil
}
