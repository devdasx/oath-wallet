import Foundation

/// Electrum 4.8 can append comma-separated RFC6902 operations to its JSON
/// snapshot. Applying the journal is essential: ignoring it can restore stale keys.
enum BitcoinElectrumJSON {
    static func read(_ data: Data) throws -> [String: Any]? {
        let values: [Any]
        do { values = try JSONSerialization.jsonObject(with: Data([91]) + data + Data([93])) as? [Any] ?? [] }
        catch { return try BitcoinElectrumLegacyLiteral.read(data) }
        guard let first = values.first as? [String: Any], BitcoinElectrumFileImporter.recognizes(first) else { return nil }
        guard values.count <= 100_001 else { throw BitcoinImportError.fileTooLarge }
        var root: Any = first
        var expansionBudget = data.count
        for value in values.dropFirst() {
            try Task.checkCancellation()
            guard let operation = value as? [String: Any], let op = operation["op"] as? String,
                  let rawPath = operation["path"] as? String else { throw BitcoinImportError.invalidFile }
            let path = try pointer(rawPath)
            switch op {
            case "add", "replace":
                guard let value = operation["value"] else { throw BitcoinImportError.invalidFile }
                root = try edit(root, path: path[...], op: op, value: value)
            case "remove": root = try edit(root, path: path[...], op: op, value: NSNull())
            case "copy", "move":
                guard let from = operation["from"] as? String else { throw BitcoinImportError.invalidFile }
                let source = try pointer(from)
                if op == "move", path.count > source.count, Array(path.prefix(source.count)) == source {
                    throw BitcoinImportError.invalidFile
                }
                let value = try get(root, path: source[...])
                if op == "copy" {
                    expansionBudget += try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed).count
                    guard expansionBudget <= BitcoinImportFileParser.maximumBytes else { throw BitcoinImportError.fileTooLarge }
                }
                if op == "move" { root = try edit(root, path: source[...], op: "remove", value: NSNull()) }
                root = try edit(root, path: path[...], op: "add", value: value)
            case "test":
                guard let expected = operation["value"],
                      (try get(root, path: path[...]) as? NSObject)?.isEqual(expected) == true else { throw BitcoinImportError.invalidFile }
            default: throw BitcoinImportError.invalidFile
            }

        }
        guard let result = root as? [String: Any] else { throw BitcoinImportError.invalidFile }
        return result
    }

    private static func pointer(_ string: String) throws -> [String] {
        guard string.isEmpty || string.hasPrefix("/") else { throw BitcoinImportError.invalidFile }
        if string.isEmpty { return [] }
        let parts = string.dropFirst().components(separatedBy: "/")
        guard parts.count <= 128 else { throw BitcoinImportError.invalidFile }
        return try parts.map { part in
            let chars = Array(part)
            for index in chars.indices where chars[index] == "~" {
                guard index + 1 < chars.count, chars[index + 1] == "0" || chars[index + 1] == "1" else {
                    throw BitcoinImportError.invalidFile
                }
            }
            return part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    private static func index(_ key: String, count: Int, append: Bool = false) throws -> Int {
        if key == "-", append { return count }
        guard !key.isEmpty, key == "0" || !key.hasPrefix("0"),
              key.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(key),
              value >= 0, value < count || (append && value == count) else { throw BitcoinImportError.invalidFile }
        return value
    }

    private static func get(_ object: Any, path: ArraySlice<String>) throws -> Any {
        guard let key = path.first else { return object }
        if let dict = object as? [String: Any], let child = dict[key] { return try get(child, path: path.dropFirst()) }
        if let array = object as? [Any] { return try get(array[index(key, count: array.count)], path: path.dropFirst()) }
        throw BitcoinImportError.invalidFile
    }

    private static func edit(_ object: Any, path: ArraySlice<String>, op: String, value: Any) throws -> Any {
        guard let key = path.first else {
            guard op != "remove" else { throw BitcoinImportError.invalidFile }
            return value
        }
        if var dict = object as? [String: Any] {
            if path.count == 1 {
                guard op == "add" || dict[key] != nil else { throw BitcoinImportError.invalidFile }
                if op == "remove" { dict.removeValue(forKey: key) } else { dict[key] = value }
            } else {
                guard let child = dict[key] else { throw BitcoinImportError.invalidFile }
                dict[key] = try edit(child, path: path.dropFirst(), op: op, value: value)
            }
            return dict
        }
        if var array = object as? [Any] {
            let i = try index(key, count: array.count, append: path.count == 1 && op == "add")
            if path.count > 1 { array[i] = try edit(array[i], path: path.dropFirst(), op: op, value: value) }
            else if op == "remove" { array.remove(at: i) }
            else if op == "add" { array.insert(value, at: i) }
            else { array[i] = value }
            return array
        }
        throw BitcoinImportError.invalidFile
    }
}
