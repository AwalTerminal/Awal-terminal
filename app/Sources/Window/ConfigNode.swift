import Foundation

class ConfigNode {
    enum ValueType {
        case string(String)
        case number(NSNumber)
        case bool(Bool)
        case null
        case object
        case array
    }

    var key: String
    var value: ValueType
    var children: [ConfigNode]
    weak var parent: ConfigNode?

    init(key: String, value: ValueType, children: [ConfigNode] = []) {
        self.key = key
        self.value = value
        self.children = children
    }

    var typeName: String {
        switch value {
        case .string: return "String"
        case .number: return "Number"
        case .bool: return "Boolean"
        case .null: return "Null"
        case .object: return "Object (\(children.count))"
        case .array: return "Array (\(children.count))"
        }
    }

    var displayValue: String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n.stringValue
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object: return "{ \(children.count) keys }"
        case .array: return "[ \(children.count) items ]"
        }
    }

    var isContainer: Bool {
        switch value {
        case .object, .array: return true
        default: return false
        }
    }

    func addChild(_ child: ConfigNode) {
        child.parent = self
        children.append(child)
    }

    func removeChild(at index: Int) {
        guard index >= 0, index < children.count else { return }
        children[index].parent = nil
        children.remove(at: index)
        // Re-index array children
        if case .array = value {
            for (i, child) in children.enumerated() {
                child.key = "\(i)"
            }
        }
    }

    // MARK: - JSON Parsing

    static func fromJSON(_ json: Any, key: String = "Root") -> ConfigNode {
        if let dict = json as? [String: Any] {
            let node = ConfigNode(key: key, value: .object)
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                let child = fromJSON(v, key: k)
                node.addChild(child)
            }
            return node
        }
        if let arr = json as? [Any] {
            let node = ConfigNode(key: key, value: .array)
            for (i, v) in arr.enumerated() {
                let child = fromJSON(v, key: "\(i)")
                node.addChild(child)
            }
            return node
        }
        // Check Bool before NSNumber since Bool bridges to NSNumber
        if let b = json as? Bool {
            return ConfigNode(key: key, value: .bool(b))
        }
        if let n = json as? NSNumber {
            return ConfigNode(key: key, value: .number(n))
        }
        if let s = json as? String {
            return ConfigNode(key: key, value: .string(s))
        }
        if json is NSNull {
            return ConfigNode(key: key, value: .null)
        }
        return ConfigNode(key: key, value: .null)
    }

    // MARK: - JSON Serialization

    func toJSON() -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .object:
            var dict: [String: Any] = [:]
            for child in children {
                dict[child.key] = child.toJSON()
            }
            return dict
        case .array:
            return children.map { $0.toJSON() }
        }
    }

    static func prettyJSON(from node: ConfigNode) -> String? {
        let json = node.toJSON()
        guard JSONSerialization.isValidJSONObject(json) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
