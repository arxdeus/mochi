from std.collections.string import Codepoint


struct JsonValue(Copyable, Movable):
    """An owning JSON value. Use the named constructors to create values."""

    comptime NULL = 0
    comptime BOOL = 1
    comptime INT = 2
    comptime FLOAT = 3
    comptime STRING = 4
    comptime ARRAY = 5
    comptime OBJECT = 6

    var kind: Int
    var bool_value: Bool
    var int_value: Int
    var float_value: Float64
    var string_value: String
    var array_value: List[JsonValue]
    var object_keys: List[String]
    var object_values: List[JsonValue]

    def __init__(out self):
        self.kind = Self.NULL
        self.bool_value = False
        self.int_value = 0
        self.float_value = 0.0
        self.string_value = ""
        self.array_value = List[JsonValue]()
        self.object_keys = List[String]()
        self.object_values = List[JsonValue]()

    def __deinit__(deinit self):
        pass

    @staticmethod
    def null() -> JsonValue:
        return JsonValue()

    @staticmethod
    def boolean(value: Bool) -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.BOOL
        result.bool_value = value
        return result^

    @staticmethod
    def integer(value: Int) -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.INT
        result.int_value = value
        return result^

    @staticmethod
    def number(value: Float64) -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.FLOAT
        result.float_value = value
        return result^

    @staticmethod
    def string(var value: String) -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.STRING
        result.string_value = value^
        return result^

    @staticmethod
    def array() -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.ARRAY
        return result^

    @staticmethod
    def object() -> JsonValue:
        var result = JsonValue()
        result.kind = JsonValue.OBJECT
        return result^

    def is_null(self) -> Bool:
        return self.kind == Self.NULL

    def append(mut self, var value: JsonValue) raises:
        if self.kind != Self.ARRAY:
            raise Error("JSON value is not an array")
        self.array_value.append(value^)

    def object_index(self, key: String) -> Int:
        for i in range(len(self.object_keys)):
            if self.object_keys[i] == key:
                return i
        return -1

    def contains(self, key: String) -> Bool:
        return self.kind == Self.OBJECT and self.object_index(key) >= 0

    def get(self, key: String) raises -> JsonValue:
        if self.kind != Self.OBJECT:
            raise Error("JSON value is not an object")
        var index = self.object_index(key)
        if index < 0:
            raise Error("JSON object key not found: " + key)
        return self.object_values[index].copy()

    def set(mut self, var key: String, var value: JsonValue) raises:
        if self.kind != Self.OBJECT:
            raise Error("JSON value is not an object")
        var index = self.object_index(key)
        if index >= 0:
            self.object_values[index] = value^
        else:
            self.object_keys.append(key^)
            self.object_values.append(value^)

    def remove(mut self, key: String) raises -> Bool:
        if self.kind != Self.OBJECT:
            raise Error("JSON value is not an object")
        var index = self.object_index(key)
        if index < 0:
            return False
        _ = self.object_keys.pop(index)
        _ = self.object_values.pop(index)
        return True

    def serialize(self) -> String:
        if self.kind == Self.NULL:
            return "null"
        if self.kind == Self.BOOL:
            if self.bool_value:
                return "true"
            return "false"
        if self.kind == Self.INT:
            return String(self.int_value)
        if self.kind == Self.FLOAT:
            return String(self.float_value)
        if self.kind == Self.STRING:
            return _quote(self.string_value)
        var output = String("")
        if self.kind == Self.ARRAY:
            output += "["
            for i in range(len(self.array_value)):
                if i != 0:
                    output += ","
                output += self.array_value[i].serialize()
            output += "]"
            return output^
        output += "{"
        for i in range(len(self.object_keys)):
            if i != 0:
                output += ","
            output += _quote(self.object_keys[i])
            output += ":"
            output += self.object_values[i].serialize()
        output += "}"
        return output^


def _quote(value: String) -> String:
    var output = String("\"")
    for cp in value.codepoints():
        var n = Int(cp.to_u32())
        if n == 34:
            output += "\\\""
        elif n == 92:
            output += "\\\\"
        elif n == 8:
            output += "\\b"
        elif n == 12:
            output += "\\f"
        elif n == 10:
            output += "\\n"
        elif n == 13:
            output += "\\r"
        elif n == 9:
            output += "\\t"
        elif n < 32:
            comptime digits = "0123456789abcdef"
            output += "\\u00"
            output += String(digits[byte=(n >> 4) & 15])
            output += String(digits[byte=n & 15])
        else:
            output += String(cp)
    output += "\""
    return output^


struct _Parser(Movable):
    var chars: List[Codepoint]
    var position: Int

    def __init__(out self, text: String):
        self.chars = List[Codepoint]()
        for cp in text.codepoints():
            self.chars.append(cp)
        self.position = 0

    def peek(self) -> Int:
        if self.position >= len(self.chars):
            return -1
        return Int(self.chars[self.position].to_u32())

    def take(mut self) raises -> Int:
        var value = self.peek()
        if value < 0:
            raise Error("Unexpected end of JSON input")
        self.position += 1
        return value

    def skip_space(mut self):
        while self.peek() == 32 or self.peek() == 9 or self.peek() == 10 or self.peek() == 13:
            self.position += 1

    def expect_word(mut self, word: String) raises:
        for cp in word.codepoints():
            if self.take() != Int(cp.to_u32()):
                raise Error("Invalid JSON literal")

    def parse_value(mut self) raises -> JsonValue:
        self.skip_space()
        var ch = self.peek()
        if ch == 110:
            self.expect_word("null")
            return JsonValue.null()
        if ch == 116:
            self.expect_word("true")
            return JsonValue.boolean(True)
        if ch == 102:
            self.expect_word("false")
            return JsonValue.boolean(False)
        if ch == 34:
            return JsonValue.string(self.parse_string())
        if ch == 91:
            return self.parse_array()
        if ch == 123:
            return self.parse_object()
        if ch == 45 or (ch >= 48 and ch <= 57):
            return self.parse_number()
        raise Error("Expected a JSON value")

    def parse_string(mut self) raises -> String:
        if self.take() != 34:
            raise Error("Expected JSON string")
        var output = String("")
        while True:
            var ch = self.take()
            if ch == 34:
                return output^
            if ch < 32:
                raise Error("Unescaped control character in JSON string")
            if ch != 92:
                output += String(Codepoint(unsafe_unchecked_codepoint=UInt32(ch)))
                continue
            ch = self.take()
            if ch == 34 or ch == 92 or ch == 47:
                output += String(Codepoint(unsafe_unchecked_codepoint=UInt32(ch)))
            elif ch == 98:
                output += String(Codepoint(UInt8(8)))
            elif ch == 102:
                output += String(Codepoint(UInt8(12)))
            elif ch == 110:
                output += "\n"
            elif ch == 114:
                output += "\r"
            elif ch == 116:
                output += "\t"
            elif ch == 117:
                var code = self.parse_hex4()
                if code >= 0xD800 and code <= 0xDBFF:
                    if self.take() != 92 or self.take() != 117:
                        raise Error("Missing low surrogate in JSON string")
                    var low = self.parse_hex4()
                    if low < 0xDC00 or low > 0xDFFF:
                        raise Error("Invalid low surrogate in JSON string")
                    code = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00
                elif code >= 0xDC00 and code <= 0xDFFF:
                    raise Error("Unexpected low surrogate in JSON string")
                output += String(Codepoint(unsafe_unchecked_codepoint=UInt32(code)))
            else:
                raise Error("Invalid escape in JSON string")

    def parse_hex4(mut self) raises -> Int:
        var result = 0
        for _ in range(4):
            var ch = self.take()
            var digit: Int
            if ch >= 48 and ch <= 57:
                digit = ch - 48
            elif ch >= 65 and ch <= 70:
                digit = ch - 55
            elif ch >= 97 and ch <= 102:
                digit = ch - 87
            else:
                raise Error("Invalid Unicode escape in JSON string")
            result = result * 16 + digit
        return result

    def parse_array(mut self) raises -> JsonValue:
        _ = self.take()
        var result = JsonValue.array()
        self.skip_space()
        if self.peek() == 93:
            _ = self.take()
            return result^
        while True:
            result.append(self.parse_value())
            self.skip_space()
            var ch = self.take()
            if ch == 93:
                return result^
            if ch != 44:
                raise Error("Expected ',' or ']' in JSON array")
            self.skip_space()

    def parse_object(mut self) raises -> JsonValue:
        _ = self.take()
        var result = JsonValue.object()
        self.skip_space()
        if self.peek() == 125:
            _ = self.take()
            return result^
        while True:
            if self.peek() != 34:
                raise Error("Expected string key in JSON object")
            var key = self.parse_string()
            self.skip_space()
            if self.take() != 58:
                raise Error("Expected ':' in JSON object")
            result.set(key^, self.parse_value())
            self.skip_space()
            var ch = self.take()
            if ch == 125:
                return result^
            if ch != 44:
                raise Error("Expected ',' or '}' in JSON object")
            self.skip_space()

    def parse_number(mut self) raises -> JsonValue:
        var negative = False
        if self.peek() == 45:
            negative = True
            self.position += 1
        if self.peek() < 48 or self.peek() > 57:
            raise Error("Expected digit in JSON number")
        var integer: Int = 0
        if self.peek() == 48:
            self.position += 1
            if self.peek() >= 48 and self.peek() <= 57:
                raise Error("Leading zero in JSON number")
        else:
            while self.peek() >= 48 and self.peek() <= 57:
                integer = integer * 10 + self.peek() - 48
                self.position += 1
        var value = Float64(integer)
        var is_float = False
        if self.peek() == 46:
            is_float = True
            self.position += 1
            if self.peek() < 48 or self.peek() > 57:
                raise Error("Expected digit after decimal point")
            var scale: Float64 = 0.1
            while self.peek() >= 48 and self.peek() <= 57:
                value += Float64(self.peek() - 48) * scale
                scale *= 0.1
                self.position += 1
        if negative:
            integer = -integer
            value = -value
        if self.peek() == 101 or self.peek() == 69:
            is_float = True
            self.position += 1
            var exponent_negative = False
            if self.peek() == 43 or self.peek() == 45:
                exponent_negative = self.peek() == 45
                self.position += 1
            if self.peek() < 48 or self.peek() > 57:
                raise Error("Expected exponent digits")
            var exponent = 0
            while self.peek() >= 48 and self.peek() <= 57:
                exponent = exponent * 10 + self.peek() - 48
                self.position += 1
            var factor: Float64 = 1.0
            for _ in range(exponent):
                if exponent_negative:
                    factor *= 0.1
                else:
                    factor *= 10.0
            value *= factor
        if is_float:
            return JsonValue.number(value)
        return JsonValue.integer(integer)


def parse_json(text: String) raises -> JsonValue:
    """Parse one complete JSON document, rejecting trailing non-whitespace."""
    var parser = _Parser(text)
    var result = parser.parse_value()
    parser.skip_space()
    if parser.position != len(parser.chars):
        raise Error("Trailing characters after JSON value")
    return result^


def serialize_json(value: JsonValue) -> String:
    return value.serialize()
