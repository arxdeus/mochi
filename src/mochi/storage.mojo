from std.os import getenv
from std.os.path import exists

from mochi.json import JsonValue, parse_json, serialize_json


struct StorageError(Copyable, Movable):
    comptime HOME_NOT_SET = 0
    comptime IO = 1
    comptime JSON = 2
    comptime NOT_FOUND = 3
    comptime INVALID_ID = 4

    var tag: Int
    var message: String

    def __init__(out self, tag: Int, message: String = ""):
        self.tag = tag
        self.message = message

    @staticmethod
    def home_not_set() -> Self:
        return Self(Self.HOME_NOT_SET, "home directory not found")

    @staticmethod
    def io(message: String) -> Self:
        return Self(Self.IO, message)

    @staticmethod
    def json(message: String) -> Self:
        return Self(Self.JSON, message)

    @staticmethod
    def not_found(name: String) -> Self:
        return Self(Self.NOT_FOUND, "not found: " + name)

    @staticmethod
    def invalid_id(message: String) -> Self:
        return Self(Self.INVALID_ID, message)


@fieldwise_init
struct StoragePaths(Copyable, Movable):
    var config: String
    var data: String
    var state: String
    var logs: String
    var cache: String
    var xdg_config: String

    @staticmethod
    def resolve() raises -> Self:
        var home = getenv("HOME", "")
        if home == "":
            raise Error("home directory not found")
        return Self.from_roots(
            home,
            getenv("XDG_CONFIG_HOME", ""),
            getenv("XDG_DATA_HOME", ""),
            getenv("XDG_STATE_HOME", ""),
            getenv("XDG_CACHE_HOME", ""),
            exists(_join(home, ".maki")),
        )

    @staticmethod
    def from_roots(
        home: String,
        xdg_config_home: String,
        xdg_data_home: String,
        xdg_state_home: String,
        xdg_cache_home: String,
        legacy_exists: Bool = False,
    ) raises -> Self:
        if home == "":
            raise Error("home directory not found")
        var config_root = xdg_config_home
        if config_root == "":
            config_root = _join(home, ".config")
        var data_root = xdg_data_home
        if data_root == "":
            data_root = _join(home, ".local/share")
        var state_root = xdg_state_home
        if state_root == "":
            state_root = _join(home, ".local/state")
        var cache_root = xdg_cache_home
        if cache_root == "":
            cache_root = _join(home, ".cache")
        var xdg_config = _join(config_root, "maki")
        if legacy_exists:
            var legacy = _join(home, ".maki")
            return Self(legacy, legacy, legacy, legacy, legacy, xdg_config)
        var logs_root = _join(_parent(state_root), "logs")
        return Self(
            xdg_config,
            _join(data_root, "maki"),
            _join(state_root, "maki"),
            _join(logs_root, "maki"),
            _join(cache_root, "maki"),
            xdg_config,
        )

    @staticmethod
    def from_xdg_roots(
        home: String,
        config_home: String,
        data_home: String,
        state_home: String,
        cache_home: String,
    ) raises -> Self:
        return Self.from_roots(
            home, config_home, data_home, state_home, cache_home, False
        )

def _join(root: String, child: String) -> String:
    if root == "":
        return child
    if root.endswith("/"):
        return root + child
    return root + "/" + child


def _parent(path: String) -> String:
    var index = path.byte_length() - 1
    while index >= 0:
        if UInt8(ord(path[byte=index])) == UInt8(47):
            if index == 0:
                return "/"
            return _byte_prefix(path, index)
        index -= 1
    return ""


def _byte_prefix(value: String, count: Int) -> String:
    var output = String("")
    for i in range(count):
        output += String(value[byte=i])
    return output^


struct MakiId(Copyable, Movable):
    var bytes: List[UInt8]

    def __init__(out self, var bytes: List[UInt8]) raises:
        if len(bytes) != 16:
            raise Error("id decoded to " + String(len(bytes)) + " bytes, expected 16")
        self.bytes = bytes^

    @staticmethod
    def parse(value: String) raises -> Self:
        if value == "":
            raise Error("empty id")
        if _looks_like_uuid(value):
            return Self(_decode_uuid(value))
        return Self(decode_base58(value))

    def encode(self) -> String:
        return encode_base58(self.bytes)

    def canonical(self) -> String:
        return self.encode()

    def __eq__(self, other: Self) -> Bool:
        for i in range(16):
            if self.bytes[i] != other.bytes[i]:
                return False
        return True


def decode_base58(value: String) raises -> List[UInt8]:
    if value == "":
        raise Error("empty id")
    var bytes: List[Int] = [0]
    var leading_zeroes = 0
    var seen_nonzero = False
    for index in range(value.byte_length()):
        var digit = _base58_digit(UInt8(ord(value[byte=index])))
        if digit < 0:
            raise Error("invalid base58 character at " + String(index))
        if digit == 0 and not seen_nonzero:
            leading_zeroes += 1
        else:
            seen_nonzero = True
        var carry = digit
        for reverse in range(len(bytes)):
            var i = len(bytes) - 1 - reverse
            carry += bytes[i] * 58
            bytes[i] = carry & 255
            carry >>= 8
        while carry > 0:
            bytes.insert(0, carry & 255)
            carry >>= 8
    var start = 0
    while start < len(bytes) - 1 and bytes[start] == 0:
        start += 1
    var result = List[UInt8]()
    for _ in range(leading_zeroes):
        result.append(0)
    if seen_nonzero:
        for i in range(start, len(bytes)):
            result.append(UInt8(bytes[i]))
    return result^


def encode_base58(bytes: List[UInt8]) -> String:
    if len(bytes) == 0:
        return ""
    comptime alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    var digits: List[Int] = [0]
    var leading_zeroes = 0
    var seen_nonzero = False
    for byte in bytes:
        var value = Int(byte)
        if value == 0 and not seen_nonzero:
            leading_zeroes += 1
        else:
            seen_nonzero = True
        var carry = value
        for reverse in range(len(digits)):
            var i = len(digits) - 1 - reverse
            carry += digits[i] << 8
            digits[i] = carry % 58
            carry //= 58
        while carry > 0:
            digits.insert(0, carry % 58)
            carry //= 58
    var start = 0
    while start < len(digits) - 1 and digits[start] == 0:
        start += 1
    var output = String("")
    for _ in range(leading_zeroes):
        output += "1"
    if seen_nonzero:
        for i in range(start, len(digits)):
            output += String(alphabet[byte=digits[i]])
    return output^


def _base58_digit(byte: UInt8) -> Int:
    comptime alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    for i in range(58):
        if UInt8(ord(alphabet[byte=i])) == byte:
            return i
    return -1


def _looks_like_uuid(value: String) -> Bool:
    return value.byte_length() == 32 or (
        value.byte_length() == 36
        and value[byte=8] == "-"
        and value[byte=13] == "-"
        and value[byte=18] == "-"
        and value[byte=23] == "-"
    )


def _decode_uuid(value: String) raises -> List[UInt8]:
    var digits = List[Int]()
    for i in range(value.byte_length()):
        var byte = UInt8(ord(value[byte=i]))
        if byte == UInt8(45):
            continue
        var digit = _hex_digit(byte)
        if digit < 0:
            raise Error("invalid UUID character at " + String(i))
        digits.append(digit)
    if len(digits) != 32:
        raise Error("invalid UUID length")
    var bytes = List[UInt8]()
    for i in range(16):
        bytes.append(UInt8((digits[i * 2] << 4) | digits[i * 2 + 1]))
    return bytes^


def _hex_digit(byte: UInt8) -> Int:
    if byte >= UInt8(48) and byte <= UInt8(57):
        return Int(byte - UInt8(48))
    if byte >= UInt8(65) and byte <= UInt8(70):
        return Int(byte - UInt8(65)) + 10
    if byte >= UInt8(97) and byte <= UInt8(102):
        return Int(byte - UInt8(97)) + 10
    return -1


struct SessionRef(Copyable, Movable):
    var id: MakiId
    var raw: String

    def __init__(out self, value: String) raises:
        self.id = MakiId.parse(value)
        self.raw = value

    @staticmethod
    def from_id(id: MakiId) -> Self:
        return Self(id, id.encode())

    def __init__(out self, id: MakiId, raw: String):
        self.id = id.copy()
        self.raw = raw

    def as_str(self) -> String:
        return self.raw


@fieldwise_init
struct OAuthTokens(Copyable, Movable):
    var access: String
    var refresh: String
    var expires: Int
    var account_id: Optional[String]

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("access", JsonValue.string(self.access))
        value.set("refresh", JsonValue.string(self.refresh))
        value.set("expires", JsonValue.integer(self.expires))
        if self.account_id:
            value.set("account_id", JsonValue.string(self.account_id.value()))
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value.kind != JsonValue.OBJECT:
            raise Error("OAuth tokens must be a JSON object")
        var account_id: Optional[String] = None
        if value.contains("account_id") and not value.get("account_id").is_null():
            account_id = Optional(_required_string(value, "account_id"))
        return Self(
            _required_string(value, "access"),
            _required_string(value, "refresh"),
            _required_int(value, "expires"),
            account_id,
        )


@fieldwise_init
struct AuthRecord(Copyable, Movable):
    var api_key: String
    var host: Optional[String]

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("api_key", JsonValue.string(self.api_key))
        if self.host:
            value.set("host", JsonValue.string(self.host.value()))
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value.kind != JsonValue.OBJECT:
            raise Error("auth record must be a JSON object")
        var host: Optional[String] = None
        if value.contains("host") and not value.get("host").is_null():
            host = Optional(_required_string(value, "host"))
        return Self(_required_string(value, "api_key"), host)


def oauth_tokens_to_json(tokens: OAuthTokens) raises -> String:
    return serialize_json(tokens.to_json())


def oauth_tokens_from_json(text: String) raises -> OAuthTokens:
    return OAuthTokens.from_json(parse_json(text))


def auth_record_to_json(record: AuthRecord) raises -> String:
    return serialize_json(record.to_json())


def auth_record_from_json(text: String) raises -> AuthRecord:
    return AuthRecord.from_json(parse_json(text))


def _required_string(value: JsonValue, key: String) raises -> String:
    if not value.contains(key):
        raise Error("missing JSON field: " + key)
    var field = value.get(key)
    if field.kind != JsonValue.STRING:
        raise Error("JSON field is not a string: " + key)
    return field.string_value


def _required_int(value: JsonValue, key: String) raises -> Int:
    if not value.contains(key):
        raise Error("missing JSON field: " + key)
    var field = value.get(key)
    if field.kind != JsonValue.INT:
        raise Error("JSON field is not an integer: " + key)
    return field.int_value
