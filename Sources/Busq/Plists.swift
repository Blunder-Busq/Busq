/**
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import Foundation
import libplist

public struct PlistError: Error {
    public enum PlistErrorType {
        case invalidArgument
    }

    public let type: PlistErrorType
    public let message: String

    public init(type: PlistErrorType, message: String) {
        self.type = type
        self.message = message
    }
}

public enum PlistType {
    case boolean
    case uint
    case real
    case string
    case array
    case dict
    case date
    case data
    case key
    case uid
    case none

    public init(rawValue: plist_type) {
        switch rawValue {
        case PLIST_BOOLEAN:
            self = .boolean
        case PLIST_UINT:
            self = .uint
        case PLIST_REAL:
            self = .real
        case PLIST_STRING:
            self = .string
        case PLIST_ARRAY:
            self = .array
        case PLIST_DICT:
            self = .dict
        case PLIST_DATE:
            self = .date
        case PLIST_DATA:
            self = .data
        case PLIST_KEY:
            self = .key
        case PLIST_UID:
            self = .uid
        default:
            self = .none
        }
    }
}


public struct Plist {
    public var rawValue: plist_t?

    public init(rawValue: plist_t) {
        self.rawValue = rawValue
    }

    public init?(nillableValue: plist_t?) {
        guard let rawValue = nillableValue else {
            return nil
        }
        self.rawValue = rawValue
    }

    mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        plist_free(rawValue)
        self.rawValue = nil
    }
}

public extension Plist {
    var size: UInt32? {
        switch nodeType {
        case .array:
            return plist_array_get_size(rawValue)
        case .dict:
            return plist_dict_get_size(rawValue)
        default:
            return nil
        }
    }
}

public extension Plist {
    init(string: String) {
        self.rawValue = plist_new_string(string)
    }

    init(bool: Bool) {
        self.rawValue = plist_new_bool(bool ? 1 : 0)
    }

    init(uint: UInt64) {
        self.rawValue = plist_new_uint(uint)
    }

    init(uid: UInt64) {
        self.rawValue = plist_new_uid(uid)
    }

    init(real: Double) {
        self.rawValue = plist_new_real(real)
    }

    init(data: Data) {
        let count = data.count
        self.rawValue = data.withUnsafeBytes { (data) -> plist_t? in
            let value = data.baseAddress?.assumingMemoryBound(to: Int8.self)
            return plist_new_data(value, UInt64(count))
        }
    }

    init(date: Date) {
        let timeInterval = date.timeIntervalSinceReferenceDate
        var sec = 0.0
        let usec = modf(timeInterval, &sec)
        self.rawValue = plist_new_date(Int32(sec), Int32(round(usec * 1000000)))
    }

    var key: String? {
        get {
            guard nodeType == .key else {
                return nil
            }
            var pkey: UnsafeMutablePointer<Int8>? = nil
            plist_get_key_val(rawValue, &pkey)
            guard let key = pkey else {
                return nil
            }
            defer { key.deallocate() }
            return String(cString: key)
        }
        set {
            guard let key = newValue else {
                return
            }
            plist_set_key_val(rawValue, key)
        }
    }

    var string: String? {
        get {
            guard nodeType == .string else {
                return nil
            }
            var pkey: UnsafeMutablePointer<Int8>? = nil
            plist_get_string_val(rawValue, &pkey)
            guard let key = pkey else {
                return nil
            }
            defer { key.deallocate() }
            return String(cString: key)
        }
        set {
            guard let string = newValue else {
                return
            }
            plist_set_string_val(rawValue, string)
        }
    }

    var bool: Bool? {
        get {
            guard nodeType == .boolean else {
                return nil
            }
            var bool: UInt8 = 0
            plist_get_bool_val(rawValue, &bool)

            return bool > 0
        }
        set {
            guard let bool = newValue else {
                return
            }
            plist_set_bool_val(rawValue, bool ? 1 : 0)
        }
    }

    var real: Double? {
        get {
            guard nodeType == .real else {
                return nil
            }
            var double: Double = 0
            plist_get_real_val(rawValue, &double)

            return double
        }
        set {
            guard let real = newValue else {
                return
            }
            plist_set_real_val(rawValue, real)
        }
    }

    var data: Data? {
        get {
            guard nodeType == .data else {
                return nil
            }
            var pvalue: UnsafeMutablePointer<Int8>? = nil
            var length: UInt64 = 0
            plist_get_data_val(rawValue, &pvalue, &length)
            guard let value = pvalue else {
                return nil
            }
            defer { value.deallocate() }
            return Data(bytes: UnsafeRawPointer(value), count: Int(length))
        }
        set {
            newValue?.withUnsafeBytes { (data: UnsafeRawBufferPointer) -> Void in
                plist_set_data_val(rawValue, data.bindMemory(to: Int8.self).baseAddress, UInt64(data.count))
            }
        }
    }

    var date: Date? {
        get {
            guard nodeType == .date else {
                return nil
            }

            var sec: Int32 = 0
            var usec: Int32 = 0
            plist_get_date_val(rawValue, &sec, &usec)

            return Date(timeIntervalSinceReferenceDate: Double(sec) + Double(usec) / 1000000)
        }
        set {
            guard nodeType == .date, let date = newValue?.timeIntervalSinceReferenceDate else {
                return
            }
            var sec: Double = 0
            let usec = modf(date, &sec)
            plist_set_date_val(rawValue, Int32(sec), Int32(usec * 1000000))
        }
    }

    var uid: UInt64? {
        get {
            guard nodeType == .uid else {
                return nil
            }
            var uid: UInt64 = 0
            plist_get_uid_val(rawValue, &uid)

            return uid
        }
        set {
            guard let uid = newValue else {
                return
            }
            plist_set_uid_val(rawValue, uid)
        }
    }

    var uint: UInt64? {
        get {
            guard nodeType == .uint else {
                return nil
            }
            var uint: UInt64 = 0
            plist_get_uint_val(rawValue, &uint)
            return uint
        }
        set {
            guard let uint = newValue else {
                return
            }
            plist_set_uint_val(rawValue, uint)
        }
    }
}


public extension Plist {
    static func copy(from node: Self) -> Self {
        return node
    }

    func getParent() -> Plist? {
        let parent = plist_get_parent(rawValue)
        return Plist(nillableValue: parent)
    }

//    func xml() -> String? {
//        var pxml: UnsafeMutablePointer<Int8>? = nil
//        var length: UInt32 = 0
//        plist_to_xml(rawValue, &pxml, &length)
//        guard let xml = pxml else {
//            return nil
//        }
//
//        defer { plist_to_xml_free(xml) }
//        return String(cString: xml)
//    }

//    func bin() -> Data? {
//        var pbin: UnsafeMutablePointer<Int8>? = nil
//        var length: UInt32 = 0
//        plist_to_bin(rawValue, &pbin, &length)
//        guard let bin = pbin else {
//            return nil
//        }
//
//        defer { plist_to_bin_free(bin) }
//        return Data(bytes: UnsafeRawPointer(bin), count: Int(length))
//    }

    var nodeType: PlistType {
        let type = plist_get_node_type(rawValue)
        return PlistType(rawValue: type)
    }
}

extension Plist: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        plist_compare_node_value(lhs.rawValue, rhs.rawValue) > 0
    }
}

public extension Plist {
    init?(xml: String) {
        let length = xml.utf8CString.count
        var prawValue: plist_t? = nil
        plist_from_xml(xml, UInt32(length), &prawValue)
        guard let rawValue = prawValue else {
            return nil
        }
        self.rawValue = rawValue
    }

    init?(bin: Data) {
        let prawValue = bin.withUnsafeBytes { (bin) -> plist_t? in
            var plist: plist_t? = nil
            guard let pointer = bin.baseAddress else {
                return nil
            }

            plist_from_bin(pointer.bindMemory(to: Int8.self, capacity: bin.count), UInt32(bin.count), &plist)
            return plist
        }

        guard let rawValue = prawValue else {
            return nil
        }
        self.rawValue = rawValue
    }

    init?(memory: String) {
        let length = memory.utf8CString.count
        var prawValue: plist_t? = nil
        plist_from_memory(memory, UInt32(length), &prawValue)
        guard let rawValue = prawValue else {
            return nil
        }
        self.rawValue = rawValue
    }

    static func isBinary(data: String) -> Bool {
        plist_is_binary(data, UInt32(data.utf8CString.count)) > 0
    }
}

//extension Plist: CustomStringConvertible {
//    public var description: String {
//        return xml() ?? ""
//    }
//}


public struct PlistArrayIterator: IteratorProtocol {
    private let node: PlistArray?
    public private(set) var rawValue:plist_array_iter? = nil

    public init(node: PlistArray) {
        var rawValue: plist_array_iter? = nil
        plist_array_new_iter(node.plist.rawValue, &rawValue)
        self.rawValue = rawValue
        self.node = node
    }

    public func next() -> Plist? {
        var pitem: plist_t? = nil
        plist_array_next_item(node?.plist.rawValue, rawValue, &pitem)
        guard let item = pitem else {
            return nil
        }
        return Plist(rawValue: item)
    }

    public mutating func free() {
        guard let rawValue = self.rawValue else {
            return
        }
        rawValue.deallocate()
        self.rawValue = nil
    }
}

public struct PlistArray {
    fileprivate let plist: Plist

    public init?(plist: Plist) {
        guard case .array = plist.nodeType else {
            return nil
        }

        self.plist = plist
    }

    func append(item: Plist) {
        plist_array_append_item(plist.rawValue, item.rawValue)
    }

    func insert(index: UInt32, item: Plist) {
        plist_array_insert_item(plist.rawValue, item.rawValue, index)
    }

    func remove(index: UInt32) {
        plist_array_remove_item(plist.rawValue, index)
    }

    func itemRemove() {
        plist_array_item_remove(plist.rawValue)
    }

    func getItemIndex() -> UInt32 {
        plist_array_get_item_index(plist.rawValue)
    }
}

extension PlistArray: Sequence {
    public func makeIterator() -> PlistArrayIterator {
        PlistArrayIterator(node: self)
    }
}

public extension Plist {
    init(array: [Plist]) {
        self.rawValue = plist_new_array()
        for value in array {
            plist_array_append_item(rawValue, value.rawValue)
        }
    }

    subscript(index: UInt32) -> Plist? {
        get { Plist(rawValue: plist_array_get_item(rawValue, index)) }
        set { plist_array_set_item(rawValue, newValue?.rawValue, index) }
    }
}

public extension Plist {
    var array: PlistArray? {
        guard case .array = nodeType else {
            return nil
        }
        return PlistArray(plist: self)
    }
}

public struct PlistDictIterator: IteratorProtocol {
    private let node: PlistDict
    public private(set) var rawValue: plist_dict_iter?

    public init(node: PlistDict) {
        var rawValue: plist_dict_iter? = nil
        plist_dict_new_iter(node.plist.rawValue, &rawValue)
        self.rawValue = rawValue
        self.node = node
    }

    public func next() -> (key: String, value:Plist)? {
        var pkey: UnsafeMutablePointer<Int8>? = nil
        var pitem: plist_t? = nil
        plist_dict_next_item(node.plist.rawValue, rawValue, &pkey, &pitem)
        guard let key = pkey, let plist = Plist(nillableValue: pitem) else {
            return nil
        }
        return (String(cString: key), plist)
    }
}

public struct PlistDict {
    fileprivate let plist: Plist

    public init?(plist: Plist) {
        guard case .dict = plist.nodeType else {
            return nil
        }

        self.plist = plist
    }
}

extension PlistDict: Sequence {
    public func makeIterator() -> PlistDictIterator {
        return PlistDictIterator(node: self)
    }
}

public extension Plist {
    init(dictionary: [String: Plist]) {
        self.rawValue = plist_new_dict()
        for (key, value) in dictionary {
            plist_dict_set_item(rawValue, key, value.rawValue)
        }
    }

    func getItemKey() -> String? {
        var pkey: UnsafeMutablePointer<Int8>? = nil
        plist_dict_get_item_key(rawValue, &pkey)

        guard let key = pkey else {
            return nil
        }
        defer { key.deallocate() }
        return String(cString: key)
    }

    subscript(key: String) -> Plist? {
        get {
            let plist = plist_dict_get_item(rawValue, key)
            return Plist(nillableValue: plist)
        }

        set {
            guard let newRawValue = newValue?.rawValue else {
                return
            }
            plist_dict_set_item(rawValue, key, newRawValue)
        }
    }
}

public extension Plist {
    var dictionary: PlistDict? {
        return PlistDict(plist: self)
    }
}



