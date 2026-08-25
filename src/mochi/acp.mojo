from mochi.json import JsonValue, parse_json


comptime ACP_PROTOCOL_VERSION = 1
comptime JSONRPC_VERSION = "2.0"


struct AcpMessage(Copyable, Movable):
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
        value.set("jsonrpc", JsonValue.string(JSONRPC_VERSION))
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

    def line(self) raises -> String:
        return self.to_json().serialize() + "\n"

    @staticmethod
    def parse(line: String) raises -> Self:
        var value = parse_json(line)
        if value.kind != JsonValue.OBJECT:
            raise Error("ACP message must be an object")
        if _string(value, "jsonrpc") != JSONRPC_VERSION:
            raise Error("unsupported ACP JSON-RPC version")
        if value.contains("method"):
            var params = JsonValue.object()
            if value.contains("params"):
                params = value.get("params")
            if value.contains("id"):
                return Self.request(
                    _integer(value, "id"), _string(value, "method"), params^
                )
            return Self.notification(_string(value, "method"), params^)
        var id = _integer(value, "id")
        if value.contains("result") and not value.contains("error"):
            return Self.response(id, value.get("result"))
        if value.contains("error") and not value.contains("result"):
            var error = value.get("error")
            return Self.failure(
                id, _integer(error, "code"), _string(error, "message")
            )
        raise Error("invalid ACP response")


struct AcpSession(Copyable, Movable):
    var initialized: Bool
    var sessions: List[String]
    var cancelled_sessions: List[String]

    def __init__(out self):
        self.initialized = False
        self.sessions = List[String]()
        self.cancelled_sessions = List[String]()

    def handle(mut self, request: AcpMessage) raises -> AcpMessage:
        if request.kind != AcpMessage.REQUEST:
            raise Error("ACP handler requires a request")
        if request.method == "initialize":
            var result = JsonValue.object()
            result.set("protocolVersion", JsonValue.integer(ACP_PROTOCOL_VERSION))
            var capabilities = JsonValue.object()
            capabilities.set("loadSession", JsonValue.boolean(True))
            capabilities.set("promptCapabilities", JsonValue.object())
            result.set("agentCapabilities", capabilities^)
            self.initialized = True
            return AcpMessage.response(request.id, result^)
        if not self.initialized:
            return AcpMessage.failure(request.id, -32002, "ACP is not initialized")
        if request.method == "session/new" or request.method == "session/load":
            var id = _string(request.payload, "sessionId")
            if not self._has_session(id):
                self.sessions.append(id)
            var result = JsonValue.object()
            result.set("sessionId", JsonValue.string(id))
            return AcpMessage.response(request.id, result^)
        if request.method == "session/cancel":
            var id = _string(request.payload, "sessionId")
            self.cancelled_sessions.append(id)
            return AcpMessage.response(request.id, JsonValue.object())
        if request.method == "session/prompt":
            var id = _string(request.payload, "sessionId")
            if not self._has_session(id):
                return AcpMessage.failure(request.id, -32004, "unknown ACP session")
            var result = JsonValue.object()
            result.set("stopReason", JsonValue.string("end_turn"))
            return AcpMessage.response(request.id, result^)
        return AcpMessage.failure(request.id, -32601, "ACP method not found")

    def _has_session(self, id: String) -> Bool:
        for current in self.sessions:
            if current == id:
                return True
        return False


def session_update(session_id: String, var update: JsonValue) raises -> AcpMessage:
    var params = JsonValue.object()
    params.set("sessionId", JsonValue.string(session_id))
    params.set("update", update^)
    return AcpMessage.notification("session/update", params^)


def permission_request(
    id: Int, session_id: String, tool_call: JsonValue, options: JsonValue
) raises -> AcpMessage:
    var params = JsonValue.object()
    params.set("sessionId", JsonValue.string(session_id))
    params.set("toolCall", tool_call.copy())
    params.set("options", options.copy())
    return AcpMessage.request(id, "session/request_permission", params^)


def _string(value: JsonValue, key: String) raises -> String:
    if not value.contains(key) or value.get(key).kind != JsonValue.STRING:
        raise Error("ACP string field required: " + key)
    return value.get(key).string_value


def _integer(value: JsonValue, key: String) raises -> Int:
    if not value.contains(key) or value.get(key).kind != JsonValue.INT:
        raise Error("ACP integer field required: " + key)
    return value.get(key).int_value
