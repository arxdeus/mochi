from std.ffi import c_int, c_long, c_size_t, external_call
from std.os import getenv, makedirs, remove
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
    def generate() raises -> Self:
        var bytes = List[UInt8](length=16, fill=0)
        var random_status = external_call[
            "mochi_secure_random",
            c_int,
            Pointer[mut=True, UInt8, MutAnyOrigin],
            c_size_t,
        ](
            rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](bytes.unsafe_ptr()),
            c_size_t(len(bytes)),
        )
        if random_status != 0:
            raise Error("UUIDv7 CSPRNG unavailable")

        var tick = List[c_long](length=2, fill=0)
        _read_realtime(tick)
        var seconds = Int(tick[0])
        var nanoseconds = Int(tick[1])
        if seconds < 0 or nanoseconds < 0 or nanoseconds >= 1_000_000_000:
            raise Error("UUIDv7 clock returned an invalid timestamp")
        var milliseconds = UInt(seconds * 1000 + nanoseconds // 1_000_000)
        for reverse in range(6):
            bytes[5 - reverse] = UInt8(milliseconds & 255)
            milliseconds >>= 8
        bytes[6] = UInt8((bytes[6] & 0x0F) | 0x70)
        bytes[8] = UInt8((bytes[8] & 0x3F) | 0x80)
        return Self(bytes^)

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


def _read_realtime(mut parts: List[c_long]) raises:
    var status = external_call[
        "clock_gettime",
        c_int,
        c_int,
        Pointer[mut=True, c_long, MutAnyOrigin],
    ](
        c_int(0),
        rebind[Pointer[mut=True, c_long, MutAnyOrigin]](parts.unsafe_ptr()),
    )
    if status != 0:
        raise Error("UUIDv7 realtime clock unavailable")


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
struct McpAuthData(Copyable, Movable):
    var server_url: String
    var tokens: Optional[OAuthTokens]
    var client_id: String
    var client_secret: Optional[String]
    var client_secret_expires_at: Optional[Int]
    var redirect_uri: Optional[String]
    var token_endpoint: Optional[String]

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("server_url", JsonValue.string(self.server_url))
        if self.tokens:
            value.set("tokens", self.tokens.value().to_json())
        else:
            value.set("tokens", JsonValue.null())
        value.set("client_id", JsonValue.string(self.client_id))
        _set_optional_string(value, "client_secret", self.client_secret)
        if self.client_secret_expires_at:
            value.set(
                "client_secret_expires_at",
                JsonValue.integer(self.client_secret_expires_at.value()),
            )
        _set_optional_string(value, "redirect_uri", self.redirect_uri)
        _set_optional_string(value, "token_endpoint", self.token_endpoint)
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value.kind != JsonValue.OBJECT:
            raise Error("MCP auth data must be a JSON object")
        var tokens: Optional[OAuthTokens] = None
        if value.contains("tokens") and not value.get("tokens").is_null():
            tokens = Optional(OAuthTokens.from_json(value.get("tokens")))
        var secret_expires: Optional[Int] = None
        if (
            value.contains("client_secret_expires_at")
            and not value.get("client_secret_expires_at").is_null()
        ):
            secret_expires = Optional(_required_int(value, "client_secret_expires_at"))
        return Self(
            _required_string(value, "server_url"),
            tokens^,
            _required_string(value, "client_id"),
            _optional_string(value, "client_secret"),
            secret_expires,
            _optional_string(value, "redirect_uri"),
            _optional_string(value, "token_endpoint"),
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


def provider_credentials_path(paths: StoragePaths, provider: String) -> String:
    return paths.state + "/auth/" + provider + ".json"


def mcp_auth_path(paths: StoragePaths, server_name: String) -> String:
    return provider_credentials_path(paths, "mcp-" + server_name)


def save_mcp_auth(
    paths: StoragePaths, server_name: String, data: McpAuthData
) raises:
    var directory = paths.state + "/auth"
    makedirs(directory, exist_ok=True)
    _atomic_write_text(mcp_auth_path(paths, server_name), serialize_json(data.to_json()))


def load_mcp_auth(
    paths: StoragePaths,
    server_name: String,
    expected_url: String,
    now_seconds: Int = 0,
) raises -> Optional[McpAuthData]:
    var path = mcp_auth_path(paths, server_name)
    if not exists(path):
        return None
    var data = McpAuthData.from_json(parse_json(open(path, "r").read()))
    if data.server_url != expected_url:
        return None
    if (
        data.client_secret_expires_at
        and now_seconds > 0
        and now_seconds >= data.client_secret_expires_at.value()
    ):
        return None
    return Optional(data^)


def delete_mcp_auth(paths: StoragePaths, server_name: String):
    try:
        remove(mcp_auth_path(paths, server_name))
    except:
        pass


def save_provider_credentials(
    paths: StoragePaths, provider: String, record: AuthRecord
) raises:
    var directory = paths.state + "/auth"
    makedirs(directory, exist_ok=True)
    _atomic_write_text(
        provider_credentials_path(paths, provider), auth_record_to_json(record)
    )


def load_provider_credentials(
    paths: StoragePaths, provider: String
) raises -> Optional[AuthRecord]:
    var path = provider_credentials_path(paths, provider)
    if not exists(path):
        return None
    return Optional(auth_record_from_json(open(path, "r").read()))


def delete_provider_credentials(paths: StoragePaths, provider: String):
    try:
        remove(provider_credentials_path(paths, provider))
    except:
        pass


def _atomic_write_text(path: String, content: String) raises:
    var temporary = path + ".tmp"
    try:
        with open(temporary, "w") as file:
            file.write(content)
        var temporary_c = temporary.as_c_string_slice()
        var destination_path = String(path)
        var destination = destination_path.as_c_string_slice()
        var status = external_call["rename", c_int](
            temporary_c.unsafe_ptr(), destination.unsafe_ptr()
        )
        if status != 0:
            raise Error("credential atomic rename failed")
    except error:
        try:
            remove(temporary)
        except:
            pass
        raise error


def auth_record_to_json(record: AuthRecord) raises -> String:
    return serialize_json(record.to_json())


def auth_record_from_json(text: String) raises -> AuthRecord:
    return AuthRecord.from_json(parse_json(text))


def _set_optional_string(
    mut value: JsonValue, key: String, optional: Optional[String]
) raises:
    if optional:
        value.set(key, JsonValue.string(optional.value()))


def _optional_string(value: JsonValue, key: String) raises -> Optional[String]:
    if not value.contains(key) or value.get(key).is_null():
        return None
    return Optional(_required_string(value, key))


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
