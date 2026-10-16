import Foundation

/// Error text is untrusted. Never pass requests, headers, user input, keys,
/// wallet IDs, addresses, transaction bytes or arbitrary NSError.userInfo here.
public enum DiagnosticPrivacy {
    public static let limit = 4_096
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
            #"(?:/Users/|/var/|/private/|/Volumes/)[^\s\"']+"#,
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            // Messages sometimes quote rejected plaintext credentials/input.
            #"\"[^\"]*\"|'[^']*'"#
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
        var nodes = 0
        func clean(_ value: Any, depth: Int = 0) -> Any {
            // MetricKit nests every stack frame in a dictionary AND a subFrames
            // array. A JSON depth of 24 discarded app frames after only ~9 calls
            // through UIKit/libc. Bound work separately from useful stack depth.
            nodes += 1
            guard depth < 256, nodes <= 16_384 else { truncated = true; return "[depth limited]" }
            if let dict = value as? [String: Any] { return dict.filter { allowed.contains($0.key) }.mapValues { clean($0, depth: depth + 1) } }
            if let list = value as? [Any] {
                if list.count > 128 { truncated = true }
                // Keep the attributed crash/hang thread ahead of unrelated stacks.
                let ordered = list.enumerated().sorted {
                    let left = ($0.element as? [String: Any])?["threadAttributed"] as? Bool ?? false
                    let right = ($1.element as? [String: Any])?["threadAttributed"] as? Bool ?? false
                    return left == right ? $0.offset < $1.offset : left
                }
                return ordered.prefix(128).map { clean($0.element, depth: depth + 1) }
            }
            if let number = value as? NSNumber { return number }
            if let string = value as? String { return UUID(uuidString: string) != nil ? string : text(string, limit: 512) }
            return "[omitted]"
        }
        // Truncate whole nodes, never JSON text: even a large report stays
        // parseable for symbolication. Reserve space for the truncation marker.
        var remaining = 14 * 1_024 - 64
        func compact(_ value: Any) -> Any? {
            guard remaining >= 4 else { truncated = true; return nil }
            if let object = value as? [String: Any] {
                remaining -= 2
                var result: [String: Any] = [:]
                let keys = object.keys.sorted { left, right in
                    if (left == "diagnosticMetaData") != (right == "diagnosticMetaData") { return left == "diagnosticMetaData" }
                    return left < right
                }
                for key in keys {
                    let overhead = key.utf8.count * 2 + 4
                    guard remaining > overhead else { truncated = true; break }
                    remaining -= overhead
                    if let child = compact(object[key]!) { result[key] = child }
                    else { break }
                }
                return result
            }
            if let list = value as? [Any] {
                remaining -= 2
                var result: [Any] = []
                for child in list {
                    if let child = compact(child) { result.append(child); remaining -= 1 }
                    else { break }
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
            "input_count", "duration_ms", "category", "source", "retryable", "count", "reason", "asset_kind"]
        return Dictionary(uniqueKeysWithValues: values.filter { allowed.contains($0.key) }
            .map { ($0.key, text($0.value, limit: 256)) })
    }
}
