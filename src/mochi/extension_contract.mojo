"""Versioned bidirectional executable-extension protocol contracts."""

from mochi.json import JsonValue, parse_json


comptime EXTENSION_PROTOCOL = "mochi.extension"
comptime EXTENSION_PROTOCOL_VERSION = 1


@fieldwise_init
struct ExtensionCapabilities(Copyable, Movable):
    var host_calls: Bool
    var concurrent_calls: Bool
    var cancellation: Bool
    var reload: Bool
    var ui_actions: Bool
    var ui_events: Bool
    var max_in_flight: Int
    var max_buffered: Int

    def __init__(out self):
        self.host_calls = False
        self.concurrent_calls = False
        self.cancellation = False
        self.reload = False
        self.ui_actions = False
        self.ui_events = False
        self.max_in_flight = 1
        self.max_buffered = 64

    def validate(self) raises:
        if self.max_in_flight < 1:
            raise Error("extension max_in_flight must be positive")
        if self.max_buffered < 1:
            raise Error("extension max_buffered must be positive")
        if not self.concurrent_calls and self.max_in_flight != 1:
            raise Error("serial extension max_in_flight must equal one")

    def to_json(self) raises -> JsonValue:
        self.validate()
        var value = JsonValue.object()
        value.set("host_calls", JsonValue.boolean(self.host_calls))
        value.set("concurrent_calls", JsonValue.boolean(self.concurrent_calls))
        value.set("cancellation", JsonValue.boolean(self.cancellation))
        value.set("reload", JsonValue.boolean(self.reload))
        value.set("ui_actions", JsonValue.boolean(self.ui_actions))
        value.set("ui_events", JsonValue.boolean(self.ui_events))
        value.set("max_in_flight", JsonValue.integer(self.max_in_flight))
        value.set("max_buffered", JsonValue.integer(self.max_buffered))
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value.kind != JsonValue.OBJECT:
            raise Error("extension capabilities must be an object")
        var result = Self()
        result.host_calls = _bool_or(value, "host_calls", False)
        result.concurrent_calls = _bool_or(value, "concurrent_calls", False)
        result.cancellation = _bool_or(value, "cancellation", False)
        result.reload = _bool_or(value, "reload", False)
        result.ui_actions = _bool_or(value, "ui_actions", False)
        result.ui_events = _bool_or(value, "ui_events", False)
        result.max_in_flight = _int_or(value, "max_in_flight", 1)
        result.max_buffered = _int_or(value, "max_buffered", 64)
        result.validate()
        return result^


struct ExtensionEnvelope(Copyable, Movable):
    comptime REQUEST = 0
    comptime RESPONSE = 1
    comptime ERROR = 2
    comptime NOTIFICATION = 3

    var kind: Int
    var id: Int
    var method: String
    var payload: JsonValue
    var error_code: Int
    var error_message: String

    def __init__(out self, kind: Int):
        self.kind = kind
        self.id = 0
        self.method = ""
        self.payload = JsonValue.null()
        self.error_code = 0
        self.error_message = ""

    @staticmethod
    def request(id: Int, method: String, var params: JsonValue) -> Self:
        var value = Self(Self.REQUEST)
        value.id = id
        value.method = method
        value.payload = params^
        return value^

    @staticmethod
    def response(id: Int, var result: JsonValue) -> Self:
        var value = Self(Self.RESPONSE)
        value.id = id
        value.payload = result^
        return value^

    @staticmethod
    def failure(id: Int, code: Int, message: String) -> Self:
        var value = Self(Self.ERROR)
        value.id = id
        value.error_code = code
        value.error_message = message
        return value^

    @staticmethod
    def notification(method: String, var params: JsonValue) -> Self:
        var value = Self(Self.NOTIFICATION)
        value.method = method
        value.payload = params^
        return value^

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("jsonrpc", JsonValue.string("2.0"))
        if self.kind != Self.NOTIFICATION:
            value.set("id", JsonValue.integer(self.id))
        if self.kind == Self.REQUEST or self.kind == Self.NOTIFICATION:
            value.set("method", JsonValue.string(self.method))
            value.set("params", self.payload.copy())
        elif self.kind == Self.RESPONSE:
            value.set("result", self.payload.copy())
        else:
            var error = JsonValue.object()
            error.set("code", JsonValue.integer(self.error_code))
            error.set("message", JsonValue.string(self.error_message))
            value.set("error", error^)
        return value^

    def to_line(self) raises -> String:
        return self.to_json().serialize() + "\n"

    @staticmethod
    def parse(line: String) raises -> Self:
        var value = parse_json(line)
        if value.kind != JsonValue.OBJECT:
            raise Error("extension message must be an object")
        if _string_or(value, "jsonrpc", "") != "2.0":
            raise Error("unsupported JSON-RPC version")
        if value.contains("method"):
            var method = _required_string(value, "method")
            var params = JsonValue.object()
            if value.contains("params"):
                params = value.get("params")
            if value.contains("id"):
                return Self.request(_required_int(value, "id"), method, params^)
            return Self.notification(method, params^)
        var id = _required_int(value, "id")
        if value.contains("result") and not value.contains("error"):
            return Self.response(id, value.get("result"))
        if value.contains("error") and not value.contains("result"):
            var error = value.get("error")
            return Self.failure(
                id,
                _required_int(error, "code"),
                _required_string(error, "message"),
            )
        raise Error("invalid extension response")


struct ExtensionSession(Copyable, Movable):
    comptime OWNED = 0
    comptime BORROWED = 1

    var capabilities: ExtensionCapabilities
    var process_ownership: Int
    var generation: Int
    var next_id: Int
    var pending_ids: List[Int]
    var pending_methods: List[String]
    var outbound: List[ExtensionEnvelope]
    var closed: Bool

    def __init__(
        out self,
        var capabilities: ExtensionCapabilities = ExtensionCapabilities(),
        process_ownership: Int = Self.OWNED,
    ) raises:
        capabilities.validate()
        if process_ownership != Self.OWNED and process_ownership != Self.BORROWED:
            raise Error("invalid extension process ownership")
        self.capabilities = capabilities^
        self.process_ownership = process_ownership
        self.generation = 1
        self.next_id = 1
        self.pending_ids = List[Int]()
        self.pending_methods = List[String]()
        self.outbound = List[ExtensionEnvelope]()
        self.closed = False

    def request(mut self, method: String, var params: JsonValue) raises -> Int:
        self._require_open()
        if len(self.pending_ids) >= self.capabilities.max_in_flight:
            raise Error("extension in-flight capacity exceeded")
        var id = self.next_id
        self.next_id += 1
        self.pending_ids.append(id)
        self.pending_methods.append(method)
        self._enqueue(ExtensionEnvelope.request(id, method, params^))
        return id

    def notify(mut self, method: String, var params: JsonValue) raises:
        self._require_open()
        self._enqueue(ExtensionEnvelope.notification(method, params^))

    def accept(mut self, message: ExtensionEnvelope) raises:
        if message.kind == ExtensionEnvelope.REQUEST:
            if not self.capabilities.host_calls:
                raise Error("extension host calls were not negotiated")
            return
        if message.kind == ExtensionEnvelope.NOTIFICATION:
            return
        var index = self._pending_index(message.id)
        if index < 0:
            raise Error("extension response id is not pending")
        _ = self.pending_ids.pop(index)
        _ = self.pending_methods.pop(index)

    def cancel(mut self, id: Int, reason: String = "cancelled") raises:
        if not self.capabilities.cancellation:
            raise Error("extension cancellation was not negotiated")
        if self._pending_index(id) < 0:
            raise Error("extension cancellation id is not pending")
        var params = JsonValue.object()
        params.set("id", JsonValue.integer(id))
        params.set("reason", JsonValue.string(reason))
        self.notify("$/cancelRequest", params^)

    def reload(mut self) raises:
        if not self.capabilities.reload:
            raise Error("extension reload was not negotiated")
        if len(self.pending_ids) != 0:
            raise Error("extension cannot reload with pending calls")
        self.generation += 1
        self.next_id = 1
        self.outbound.clear()

    def close(mut self):
        self.closed = True
        self.pending_ids.clear()
        self.pending_methods.clear()
        self.outbound.clear()

    def should_terminate_process(self) -> Bool:
        return self.process_ownership == Self.OWNED

    def _enqueue(mut self, var message: ExtensionEnvelope) raises:
        if len(self.outbound) >= self.capabilities.max_buffered:
            raise Error("extension outbound buffer capacity exceeded")
        self.outbound.append(message^)

    def _pending_index(self, id: Int) -> Int:
        for i in range(len(self.pending_ids)):
            if self.pending_ids[i] == id:
                return i
        return -1

    def _require_open(self) raises:
        if self.closed:
            raise Error("extension session is closed")


def _required_string(value: JsonValue, key: String) raises -> String:
    if not value.contains(key) or value.get(key).kind != JsonValue.STRING:
        raise Error("missing extension string field: " + key)
    return value.get(key).string_value


def _string_or(value: JsonValue, key: String, fallback: String) raises -> String:
    if value.contains(key) and value.get(key).kind == JsonValue.STRING:
        return value.get(key).string_value
    return fallback


def _required_int(value: JsonValue, key: String) raises -> Int:
    if not value.contains(key) or value.get(key).kind != JsonValue.INT:
        raise Error("missing extension integer field: " + key)
    return value.get(key).int_value


def _int_or(value: JsonValue, key: String, fallback: Int) raises -> Int:
    if value.contains(key) and value.get(key).kind == JsonValue.INT:
        return value.get(key).int_value
    return fallback


def _bool_or(value: JsonValue, key: String, fallback: Bool) raises -> Bool:
    if value.contains(key) and value.get(key).kind == JsonValue.BOOL:
        return value.get(key).bool_value
    return fallback
