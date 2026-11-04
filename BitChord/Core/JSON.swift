import Foundation

/// A decoded JSON object, as `JSONSerialization` produces it.
typealias JObj = [String: Any]

/// Null-safe navigation over InnerTube's deeply nested responses.
/// Every accessor returns nil rather than throwing, mirroring the Kotlin parser.
extension Dictionary where Key == String, Value == Any {
    func o(_ key: String) -> JObj? { self[key] as? JObj }
    func a(_ key: String) -> [Any]? { self[key] as? [Any] }
    func s(_ key: String) -> String? {
        if let v = self[key] as? String { return v }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
    /// The run list under `key` joined into one string ("" when absent).
    func runs(_ key: String) -> String {
        guard let runs = o(key)?.a("runs") else {
            return o(key)?.s("simpleText") ?? ""
        }
        return runs.compactMap { ($0 as? JObj)?.s("text") }.joined()
    }
    /// The raw run objects under `key`.
    func runList(_ key: String) -> [JObj] {
        (o(key)?.a("runs") ?? []).compactMap { $0 as? JObj }
    }
    /// Largest thumbnail URL from a `thumbnails` array somewhere under `self`.
    var objects: [JObj] { values.compactMap { $0 as? JObj } }
}

extension Array where Element == Any {
    var objects: [JObj] { compactMap { $0 as? JObj } }
}

enum JSONWalk {
    /// Depth-first collection of every object stored under `name`, preserving array order.
    static func collect(_ root: Any?, _ name: String) -> [JObj] {
        var out: [JObj] = []
        func walk(_ node: Any) {
            if let obj = node as? JObj {
                if let hit = obj[name] as? JObj { out.append(hit) }
                // Visit keys in a stable order so results are deterministic.
                for key in obj.keys.sorted() {
                    if let child = obj[key], child is JObj || child is [Any] { walk(child) }
                }
            } else if let arr = node as? [Any] {
                for child in arr { walk(child) }
            }
        }
        if let root { walk(root) }
        return out
    }

    /// First string under `key` anywhere in the subtree.
    static func findString(_ root: Any?, _ key: String) -> String? {
        if let obj = root as? JObj {
            if let s = obj[key] as? String { return s }
            for k in obj.keys.sorted() {
                if let found = findString(obj[k], key) { return found }
            }
        } else if let arr = root as? [Any] {
            for child in arr { if let found = findString(child, key) { return found } }
        }
        return nil
    }

    static func hasKey(_ root: Any?, _ key: String) -> Bool {
        if let obj = root as? JObj {
            if obj[key] != nil { return true }
            return obj.values.contains { hasKey($0, key) }
        } else if let arr = root as? [Any] {
            return arr.contains { hasKey($0, key) }
        }
        return false
    }

    static func hasValue(_ root: Any?, _ value: String) -> Bool {
        if let s = root as? String { return s == value }
        if let obj = root as? JObj { return obj.values.contains { hasValue($0, value) } }
        if let arr = root as? [Any] { return arr.contains { hasValue($0, value) } }
        return false
    }
}

extension Optional where Wrapped == [Any] {
    /// Last (largest) thumbnail URL.
    var bestThumbnail: String? {
        (self?.last as? JObj)?.s("url")
    }
    var isNotSquare: Bool {
        guard let last = self?.last as? JObj,
              let w = last.double("width"), let h = last.double("height"), w > 0, h > 0 else { return false }
        let r = w / h
        return r < 0.85 || r > 1.15
    }
}
