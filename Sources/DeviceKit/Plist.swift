import CMobileDevice
import Foundation

/// Narrow helpers for the `plist_t` values that cross the C boundary.
/// Ownership rule: every `plist_t` produced by libimobiledevice is freed here.
enum Plist {
    /// Reads a string node, returning nil for a null pointer or wrong node type.
    static func string(_ node: plist_t?) -> String? {
        guard let node, plist_get_node_type(node) == PLIST_STRING else { return nil }
        var raw: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &raw)
        guard let raw else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    static func integer(_ node: plist_t?) -> Int? {
        guard let node else { return nil }
        switch plist_get_node_type(node) {
        case PLIST_INT:
            var value: UInt64 = 0
            plist_get_uint_val(node, &value)
            return Int(bitPattern: UInt(value))
        case PLIST_STRING:
            return Plist.string(node).flatMap(Int.init)
        default:
            return nil
        }
    }

    /// Wraps arbitrary bytes as a `PLIST_DATA` node. Used for the sinf and the
    /// iTunes metadata handed to installation_proxy.
    static func data(_ bytes: Data) -> plist_t? {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return plist_new_data(base.assumingMemoryBound(to: CChar.self), UInt64(buffer.count))
        }
    }

    /// Iterates a `PLIST_DICT`, handing each key/value to `body`.
    /// The values stay owned by the dictionary and must not be freed by the caller.
    static func forEachDictEntry(_ dict: plist_t?, _ body: (String, plist_t) -> Void) {
        guard let dict, plist_get_node_type(dict) == PLIST_DICT else { return }
        var iterator: plist_dict_iter? = nil
        plist_dict_new_iter(dict, &iterator)
        guard iterator != nil else { return }
        defer { free(iterator) }

        while true {
            var key: UnsafeMutablePointer<CChar>?
            var value: plist_t?
            plist_dict_next_item(dict, iterator, &key, &value)
            guard let key, let value else { break }
            body(String(cString: key), value)
            free(key)
        }
    }

    /// Iterates a `PLIST_ARRAY`.
    static func forEachArrayItem(_ array: plist_t?, _ body: (plist_t) -> Void) {
        guard let array, plist_get_node_type(array) == PLIST_ARRAY else { return }
        let count = plist_array_get_size(array)
        for index in 0..<count {
            if let item = plist_array_get_item(array, index) { body(item) }
        }
    }
}
