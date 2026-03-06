import Foundation

// MARK: - TaskTypeMode

enum TaskTypeMode: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case general = "General"
    var id: String { rawValue }
}

// MARK: - ClaudeModel

enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - ClaudePermissionMode

enum ClaudePermissionMode: String, CaseIterable, Identifiable {
    case plan = "plan"
    case autoEdit = "acceptEdits"
    case fullAuto = "bypass"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plan: return "Plan (safe)"
        case .autoEdit: return "Auto-approve"
        case .fullAuto: return "Unrestricted"
        }
    }

    var cliFlag: String {
        switch self {
        case .plan: return "--permission-mode plan"
        case .autoEdit: return "--permission-mode acceptEdits"
        case .fullAuto: return "--dangerously-skip-permissions"
        }
    }
}

// MARK: - ClaudeToolPreset

enum ClaudeToolPreset: String, CaseIterable, Identifiable {
    case readOnly = "Read-only"
    case standard = "Standard"
    case full = "Full"
    case custom = "Custom"

    var id: String { rawValue }

    var tools: Set<String>? {
        switch self {
        case .readOnly: return ["Read", "Glob", "Grep", "WebSearch"]
        case .standard: return ["Read", "Glob", "Grep", "Edit", "Bash", "Write", "WebSearch"]
        case .full: return nil
        case .custom: return nil
        }
    }
}

// MARK: - ClaudeTool

struct ClaudeTool: Identifiable, Hashable {
    let name: String
    var id: String { name }

    static let all: [ClaudeTool] = [
        "Read", "Edit", "Write", "Bash", "Glob", "Grep",
        "WebSearch", "WebFetch", "Agent", "Notebook",
    ].map { ClaudeTool(name: $0) }
}

// MARK: - ClaudeCommandBuilder

/// Encapsulates all Claude CLI knowledge: command generation, shell escaping,
/// and command parsing. Decoupled from SwiftUI so the socket API can reuse it.
struct ClaudeCommandBuilder {

    static let knownToolNames: Set<String> = Set(ClaudeTool.all.map(\.name))

    /// Environment variable names that should not be set by users.
    /// Shared between the UI form and socket API validation paths.
    static let blockedEnvKeys: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
        "BASH_ENV", "ENV", "PROMPT_COMMAND", "IFS", "CDPATH",
        "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR", "GIT_SSH_COMMAND",
        "PYTHONPATH", "PYTHONSTARTUP", "NODE_OPTIONS", "NODE_PATH",
        "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB",
        "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS",
    ]

    /// Blocked prefixes for environment variable names.
    private static let blockedEnvPrefixes = ["DYLD_", "LD_", "BASH_FUNC_"]

    /// Returns true if the key is blocked or uses a blocked prefix.
    static func isBlockedEnvKey(_ key: String) -> Bool {
        blockedEnvKeys.contains(key)
            || blockedEnvPrefixes.contains(where: { key.hasPrefix($0) })
    }

    /// Returns true if the key conforms to POSIX env var name syntax: [A-Za-z_][A-Za-z0-9_]*
    static func isValidEnvKeyName(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: - Shell Escaping

    /// Shell-escape a string using single-quote wrapping.
    /// Newlines are replaced with spaces since initial_input delivers
    /// characters as keyboard input (newlines act as Enter).
    /// Unicode scalar ranges that are stripped from shell-escaped strings.
    /// Includes bidi overrides (Trojan Source), zero-width chars, and control chars.
    private static let strippedUnicodeRanges: [ClosedRange<UInt32>] = [
        0x00...0x08,    // ASCII control (before TAB)
        0x0B...0x0C,    // VT, FF
        0x0E...0x1F,    // ASCII control (after CR)
        0x7F...0x7F,    // DEL
        0x200B...0x200F, // zero-width space, ZWNJ, ZWJ, LRM, RLM
        0x202A...0x202E, // bidi overrides (LRE, RLE, PDF, LRO, RLO)
        0x2066...0x2069, // bidi isolates (LRI, RLI, FSI, PDI)
        0xFEFF...0xFEFF, // BOM / ZWNBSP
    ]

    static func shellEscape(_ s: String) -> String {
        // Replace newlines with spaces (initial_input treats \n as Enter).
        // Strip ASCII control chars, Unicode bidi overrides, and zero-width chars
        // to prevent terminal escape injection and Trojan Source attacks.
        let sanitized = String(s.unicodeScalars.compactMap { scalar -> Character? in
            if scalar.value == 0x0A { return " " }  // newline → space
            if scalar.value == 0x0D { return nil }   // carriage return → strip
            if scalar.value == 0x09 { return " " }   // tab → space
            for range in strippedUnicodeRanges {
                if range.contains(scalar.value) { return nil }
            }
            return Character(scalar)
        })
        return "'" + sanitized.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Command Generation

    struct Config {
        var model: ClaudeModel = .sonnet
        var prompt: String = ""
        var permission: ClaudePermissionMode = .fullAuto
        var maxTurns: String = ""
        var maxBudget: String = ""
        var toolPreset: ClaudeToolPreset = .standard
        var customTools: Set<String> = ["Read", "Glob", "Grep", "WebSearch"]
    }

    static let maxPromptLength = 32_000
    static let maxTurns = 200
    static let maxBudgetUSD = 100.0

    /// Build the argument list for a `claude -p` command.
    static func commandParts(from config: Config) -> [String] {
        var parts = ["claude", "-p", shellEscape(config.prompt)]
        parts.append(contentsOf: ["--model", config.model.rawValue])
        parts.append(config.permission.cliFlag)

        if let turns = Int(config.maxTurns), turns > 0, turns <= maxTurns {
            parts.append(contentsOf: ["--max-turns", "\(turns)"])
        }
        if let budget = Double(config.maxBudget), budget > 0, budget <= maxBudgetUSD {
            parts.append(contentsOf: ["--max-budget-usd", String(format: "%.2f", budget)])
        }

        // --allowedTools is ignored with --dangerously-skip-permissions
        if config.permission != .fullAuto {
            let toolsList: String? = {
                switch config.toolPreset {
                case .readOnly, .standard:
                    return config.toolPreset.tools?.sorted().joined(separator: ",")
                case .full:
                    return nil
                case .custom:
                    let safe = config.customTools.filter { knownToolNames.contains($0) }
                    return safe.isEmpty ? nil : safe.sorted().joined(separator: ",")
                }
            }()
            if let tools = toolsList {
                parts.append(contentsOf: ["--allowedTools", shellEscape(tools)])
            }
        }

        return parts
    }

    /// Single-line command string for execution via shell.
    static func command(from config: Config) -> String {
        commandParts(from: config).joined(separator: " ")
    }

    /// Multi-line display string for the preview panel.
    static func commandPreview(from config: Config) -> String {
        commandParts(from: config).joined(separator: " \\\n  ")
    }

    // MARK: - Command Parsing

    /// Parse a claude command string back into a Config.
    /// Used by the form's prefill to restore fields when editing an existing task.
    static func parseCommand(_ cmd: String) -> Config {
        var config = Config()

        // Extract --model <value>
        if let range = cmd.range(of: #"--model\s+(\w+)"#, options: .regularExpression) {
            let modelStr = String(cmd[range]).replacingOccurrences(
                of: "--model ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            if let model = ClaudeModel.allCases.first(where: { $0.rawValue == modelStr }) {
                config.model = model
            }
        }

        // Extract permission mode
        if cmd.contains("--dangerously-skip-permissions") {
            config.permission = .fullAuto
        } else if let range = cmd.range(
            of: #"--permission-mode\s+([\w-]+)"#, options: .regularExpression
        ) {
            let modeStr = String(cmd[range]).replacingOccurrences(
                of: "--permission-mode ", with: ""
            ).trimmingCharacters(in: .whitespaces)
            if let perm = ClaudePermissionMode.allCases.first(where: { $0.rawValue == modeStr }) {
                config.permission = perm
            }
        }

        // Extract --max-turns <value>
        if let range = cmd.range(of: #"--max-turns\s+(\d+)"#, options: .regularExpression) {
            config.maxTurns = String(cmd[range]).replacingOccurrences(
                of: "--max-turns ", with: ""
            ).trimmingCharacters(in: .whitespaces)
        }

        // Extract --max-budget-usd <value>
        if let range = cmd.range(
            of: #"--max-budget-usd\s+([\d.]+)"#, options: .regularExpression
        ) {
            config.maxBudget = String(cmd[range]).replacingOccurrences(
                of: "--max-budget-usd ", with: ""
            ).trimmingCharacters(in: .whitespaces)
        }

        // Extract --allowedTools '<csv>'
        if let range = cmd.range(
            of: #"--allowedTools\s+'([^']+)'"#, options: .regularExpression
        ) {
            let toolsMatch = String(cmd[range])
            if let qStart = toolsMatch.firstIndex(of: "'"),
               let qEnd = toolsMatch[toolsMatch.index(after: qStart)...].firstIndex(of: "'")
            {
                let csv = String(toolsMatch[toolsMatch.index(after: qStart)..<qEnd])
                let tools = Set(csv.split(separator: ",").map { String($0) })
                let validTools = tools.filter { knownToolNames.contains($0) }

                if validTools == ClaudeToolPreset.readOnly.tools {
                    config.toolPreset = .readOnly
                } else if validTools == ClaudeToolPreset.standard.tools {
                    config.toolPreset = .standard
                } else {
                    config.toolPreset = .custom
                    config.customTools = validTools
                }
            }
        } else if !cmd.contains("--allowedTools") {
            config.toolPreset = .full
        }

        // Extract prompt: the argument after -p, which is single-quoted.
        // Format: claude -p 'prompt text' --model ...
        let stripped = cmd.replacingOccurrences(of: " \\\n  ", with: " ")
        if let pRange = stripped.range(of: "-p '") {
            let afterP = stripped[pRange.upperBound...]
            // Find the closing quote (handling '\'' escapes)
            var result = ""
            var i = afterP.startIndex
            while i < afterP.endIndex {
                if afterP[i] == "'" {
                    // Check for '\'' escape pattern
                    let remaining = afterP[i...]
                    if remaining.hasPrefix("'\\''") {
                        result.append("'")
                        i = afterP.index(i, offsetBy: 4)
                    } else {
                        // End of quoted string
                        break
                    }
                } else {
                    result.append(afterP[i])
                    i = afterP.index(after: i)
                }
            }
            config.prompt = result
        }

        return config
    }
}
