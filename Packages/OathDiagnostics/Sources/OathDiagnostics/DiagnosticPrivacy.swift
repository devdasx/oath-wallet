import Foundation

/// Error text is untrusted. Never pass requests, headers, user input, keys,
/// wallet IDs, addresses, transaction bytes or arbitrary NSError.userInfo here.
public enum DiagnosticPrivacy {
    public static let limit = 4_096
    // Public compiler source names generated from this app's repository. Generic
    // credential detection otherwise consumes module/long-filename pairs as
    // base64-like tokens. Only these exact names can survive in location fields;
    // error messages and arbitrary filenames keep the full untrusted-text filter.
    static let appSourceFiles: Set<String> = {
        guard let url = Bundle.module.url(forResource: "app_source_files", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 128 * 1024,
              let names = try? JSONDecoder().decode([String].self, from: data), names.count <= 1024 else { return [] }
        return Set(names)
    }()
    // Public dictionaries already shipped by the app, never user phrases.
    private static let mnemonicWords: Set<String> = {
        guard let url = Bundle.module.url(forResource: "bip39_words", withExtension: "txt"),
              let words = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(words.split(separator: "\n").map(String.init))
    }()
    private static func redactMnemonic(_ input: String) -> String {
        // Normalize only for comparisons: preserve the provider's original text.
        // Removing invisible characters earlier prevents hidden word separators.
        guard !mnemonicWords.isEmpty,
              let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{M}]+"#) else {
            return input.replacingOccurrences(of: #"(?:[\p{L}\p{M}]+[\s,]+){11,}[\p{L}\p{M}]+"#,
                                              with: "[redacted]", options: .regularExpression)
        }
        let source = input as NSString
        let matches = expression.matches(in: input, range: NSRange(location: 0, length: source.length))
        var ranges: [NSRange] = [], run: [NSRange] = []
        func finishRun() {
            if run.count >= 12, let first = run.first, let last = run.last {
                ranges.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            }
            run.removeAll(keepingCapacity: true)
        }
        for match in matches {
            let word = source.substring(with: match.range).decomposedStringWithCompatibilityMapping.lowercased()
            if let previous = run.last {
                let gap = source.substring(with: NSRange(location: NSMaxRange(previous), length: match.range.location - NSMaxRange(previous)))
                if !gap.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "," }) { finishRun() }
            }
            if mnemonicWords.contains(word) { run.append(match.range) }
            else {
                finishRun()
                // Chinese BIP39 phrases may be pasted without spaces.
                if word.count >= 12, word.allSatisfy({ mnemonicWords.contains(String($0)) }) { ranges.append(match.range) }
            }
        }
        finishRun()
        let output = NSMutableString(string: input)
        for range in ranges.sorted(by: { $0.location > $1.location }) { output.replaceCharacters(in: range, with: "[redacted]") }
        return output as String
    }
    private static func bounded(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var prefix = Array(value.utf8.prefix(max(0, bytes)))
        while !prefix.isEmpty, String(bytes: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self) + " [truncated]"
    }
    public static func text(_ input: String, limit: Int = limit) -> String {
        // Bound work before running expressions, even for malicious providers.
        var value = String(input.prefix(16_384).unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint &&
            (!CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t") })
        value = redactMnemonic(value)
        let patterns = [
            // WalletConnect pairing URIs contain a symmetric encryption key.
            #"(?i)\bwc:[^\s<>\"']+"#,
            // Alchemy keys may be shorter than the generic credential pattern.
            #"(?i)\balch_[a-z0-9_-]+"#,
            #"(?i)(?:https?|wss?|file)://[^\s<>\"']+"#,
            #"(?i)(?:bearer|basic)\s+[^\s,;]+"#,
            #"(?i)(?:password|passphrase|mnemonic|seed|private[ _-]?key|api[ _-]?key|authorization|token|secret|credential)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            #"(?i)\b(?:[0-9a-f]{40,}|[a-z0-9_+/=]{32,})\b"#,
            // Local filenames and storage errors can expose wallet identifiers.
            // Structural MetricKit binary UUIDs are retained by runtime(), not
            // by this untrusted-text path.
            #"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#,
            #"(?:/Users/|/var/|/private/|/Volumes/)[^\s\"']+"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            // Messages sometimes quote rejected plaintext credentials/input.
            #"\"[^\"]*\"|'[^']*'|“[^”]*”|‘[^’]*’|«[^»]*»|„[^“]*“"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return bounded(value, bytes: limit) + (input.count > 16_384 ? " [truncated]" : "")
    }
    public static func runtime(_ input: String) -> String {
        guard input.utf8.count <= 4 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) else { return "[invalid runtime report]" }
        let allowed: Set<String> = ["callStackTree", "callStacks", "callStackRootFrames", "subFrames", "threadAttributed",
            "binaryUUID", "offsetIntoBinaryTextSegment", "binaryName", "address", "sampleCount", "threadNumber",
            "diagnosticMetaData", "exceptionType", "exceptionCode", "signal", "terminationReason", "hangDuration",
            "totalCPUTime", "totalSampledTime", "totalWritesCaused", "appBuildVersion", "appVersion", "osVersion",
            "platformArchitecture", "launchDuration"]
        var truncated = (object as? [String: Any])?["_truncated"] as? Bool ?? false
        var nodeBudget = 16_384
        func orderedKeys(_ object: [String: Any]) -> [String] {
            func priority(_ key: String) -> Int {
                switch key {
                case "diagnosticMetaData": 0
                case "threadAttributed": 1
                default: 2
                }
            }
            return object.keys.filter { allowed.contains($0) }.sorted {
                let left = priority($0), right = priority($1)
                return left == right ? $0 < $1 : left < right
            }
        }
        func clean(_ value: Any, depth: Int = 0, key: String? = nil) -> Any {
            // MetricKit nests every stack frame in a dictionary AND a subFrames
            // array. A JSON depth of 24 discarded app frames after only ~9 calls
            // through UIKit/libc. Bound work separately from useful stack depth.
            guard depth < 256, nodeBudget > 0 else { truncated = true; return "[depth limited]" }
            nodeBudget -= 1
            if let dict = value as? [String: Any] {
                var result: [String: Any] = [:]
                // The node budget is shared across the whole report. Preserve
                // build/exception metadata before visiting a potentially huge
                // call tree; dictionary iteration order must not decide this.
                for key in orderedKeys(dict) {
                    result[key] = clean(dict[key]!, depth: depth + 1, key: key)
                }
                return result
            }
            if let list = value as? [Any] {
                if list.count > 128 { truncated = true }
                // Keep the attributed crash/hang thread ahead of unrelated stacks.
                let ordered = list.enumerated().sorted {
                    let left = ($0.element as? [String: Any])?["threadAttributed"] as? Bool ?? false
                    let right = ($1.element as? [String: Any])?["threadAttributed"] as? Bool ?? false
                    return left == right ? $0.offset < $1.offset : left
                }
                let kept = Array(ordered.prefix(128))
                return kept.enumerated().map { index, item in
                    guard key == "callStacks", kept.count > 1 else {
                        return clean(item.element, depth: depth + 1)
                    }
                    // A large attributed stack must not consume all traversal
                    // work before another attributed stack can even be read.
                    let available = nodeBudget
                    let attributed = kept[index...].filter { ($0.element as? [String: Any])?["threadAttributed"] as? Bool == true }.count
                    let share = available / max(1, attributed > 0 ? attributed : kept.count - index)
                    nodeBudget = share
                    let result = clean(item.element, depth: depth + 1)
                    nodeBudget += available - share
                    return result
                }
            }
            if let number = value as? NSNumber { return number }
            if let string = value as? String { return UUID(uuidString: string) != nil ? string : text(string, limit: 512) }
            return "[omitted]"
        }
        // Truncate whole nodes, never JSON text: even a large report stays
        // parseable for symbolication. Reserve space for the truncation marker.
        var remaining = 14 * 1_024 - 64
        func compact(_ value: Any, key: String? = nil) -> Any? {
            guard remaining >= 4 else { truncated = true; return nil }
            if let object = value as? [String: Any] {
                remaining -= 2
                var result: [String: Any] = [:]
                // Preserve the attributed-thread flag before its frame tree
                // consumes the byte budget, including when filtering again.
                for key in orderedKeys(object) {
                    let overhead = key.utf8.count * 2 + 4
                    guard remaining > overhead else { truncated = true; break }
                    remaining -= overhead
                    if let child = compact(object[key]!, key: key) { result[key] = child }
                    else { break }
                }
                return result
            }
            if let list = value as? [Any] {
                remaining -= 2
                var result: [Any] = []
                for (index, child) in list.enumerated() {
                    // Share the budget among attributed stacks first, then use
                    // remaining space for the other stacks. Keep frame order,
                    // nesting and attributed flag; never invent a main thread.
                    let available = remaining
                    let attributed = key == "callStacks" ? list[index...].filter {
                        ($0 as? [String: Any])?["threadAttributed"] as? Bool == true
                    }.count : 0
                    let divisor = max(1, attributed > 0 ? attributed : list.count - index)
                    let share = key == "callStacks" ? available / divisor : available
                    remaining = share
                    let value = compact(child)
                    remaining += available - share
                    if let value { result.append(value); remaining -= 1 }
                    else if key != "callStacks" { break }
                }
                return result
            }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  data.count <= remaining else { truncated = true; return nil }
            remaining -= data.count
            return value
        }
        guard var result = compact(clean(object)) as? [String: Any] else { return "[invalid runtime report]" }
        if truncated { result["_truncated"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return "[invalid runtime report]" }
        return String(decoding: data, as: UTF8.self)
    }
    public static func identifier(_ value: String) -> String {
        String(value.prefix(120).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._:-/".contains($0)) })
    }
    public static func context(_ values: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["chain", "stage", "method", "host", "http_status", "rpc_code", "attempt",
            "input_count", "duration_ms", "category", "source", "retryable", "count", "reason", "asset_kind",
            "screen", "origin_screen", "screen_source", "action", "step", "step_source", "app_state",
            "action_started_at", "elapsed_ms", "cause_status", "time_source"]
        return Dictionary(uniqueKeysWithValues: values.filter { allowed.contains($0.key) }
            .map { ($0.key, sourceContext($0.value, key: $0.key) ?? text($0.value, limit: 256)) })
    }
    private static func sourceContext(_ value: String, key: String) -> String? {
        guard ["screen", "origin_screen", "action", "step"].contains(key), value.utf8.count <= 256,
              let colon = value.firstIndex(of: ":"), appSourceFiles.contains(String(value[..<colon])) else { return nil }
        let suffix = String(value[value.index(after: colon)...])
        let parts = suffix.split(separator: ":", omittingEmptySubsequences: false)
        guard let line = parts.last, !line.isEmpty, line.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt(line), number > 0, number <= 1_000_000 else { return nil }
        if ["screen", "origin_screen"].contains(key), parts.count != 1 { return nil }
        // Only the exact known filename is trusted. A function/step suffix can
        // still contain arbitrary supplied context and must be privacy-filtered.
        return bounded(String(value[..<colon]) + ":" + text(suffix, limit: 256), bytes: 256)
    }
}
