from mochi.json import JsonValue, parse_json
from mochi.runtime import Runtime
from mochi.session import Session, SessionStore
from mochi.storage import MakiId, SessionRef
from mochi.types import CancellationToken, Message


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


struct AcpRuntimeServer:
    var protocol: AcpSession
    var runtime: Runtime
    var store: SessionStore
    var sessions: List[Session]
    var active_session_id: String
    var now_ms: Int

    def __init__(
        out self,
        var runtime: Runtime,
        var store: SessionStore,
        now_ms: Int = 0,
    ):
        self.protocol = AcpSession()
        self.runtime = runtime^
        self.store = store^
        self.sessions = List[Session]()
        self.active_session_id = ""
        self.now_ms = now_ms

    def handle(mut self, request: AcpMessage) raises -> List[AcpMessage]:
        var output = List[AcpMessage]()
        if request.method == "session/new":
            if not self.protocol.initialized:
                output.append(self.protocol.handle(request))
                return output^
            var id = self._new_session_id(request.payload)
            var cwd = _optional_string(request.payload, "cwd", ".")
            var session = Session(id, self.runtime.model, cwd, self.now_ms)
            self.sessions.append(session^)
            self.active_session_id = id
            self.runtime.set_messages(List[Message]())
            var params = JsonValue.object()
            params.set("sessionId", JsonValue.string(id))
            output.append(
                self.protocol.handle(
                    AcpMessage.request(request.id, request.method, params^)
                )
            )
            return output^
        if request.method == "session/load":
            if not self.protocol.initialized:
                output.append(self.protocol.handle(request))
                return output^
            var id = _string(request.payload, "sessionId")
            var session = self.store.load(id)
            self._replace_session(session.copy())
            self.active_session_id = id
            self.runtime.set_messages(session.runtime_messages())
            if not self.protocol._has_session(id):
                self.protocol.sessions.append(id)
            output.append(self.protocol.handle(request))
            output.append(
                session_update(id, _history_update(session.runtime_messages()))
            )
            return output^
        if request.method == "session/prompt":
            if not self.protocol.initialized:
                output.append(self.protocol.handle(request))
                return output^
            var id = _string(request.payload, "sessionId")
            var index = self._session_index(id)
            if index < 0:
                output.append(
                    AcpMessage.failure(request.id, -32004, "unknown ACP session")
                )
                return output^
            var prompt = _prompt_text(request.payload)
            var result = self.runtime.run(prompt, CancellationToken())
            self.sessions[index].update_from_result(
                result.messages, result.usage, self.runtime.model, self.now_ms
            )
            self.store.save(self.sessions[index])
            output.append(
                session_update(id, _agent_message_update(result.text))
            )
            var response = JsonValue.object()
            response.set("stopReason", JsonValue.string(result.stop_reason))
            output.append(AcpMessage.response(request.id, response^))
            return output^
        if request.method == "session/cancel":
            output.append(self.protocol.handle(request))
            return output^
        output.append(self.protocol.handle(request))
        return output^

    def shutdown(mut self):
        self.runtime.shutdown_remotes()

    def _new_session_id(self, payload: JsonValue) raises -> String:
        if payload.contains("sessionId"):
            return _string(payload, "sessionId")
        return SessionRef.from_id(MakiId.generate()).as_str()

    def _session_index(self, id: String) -> Int:
        for i in range(len(self.sessions)):
            if self.sessions[i].id == id:
                return i
        return -1

    def _replace_session(mut self, var session: Session):
        var index = self._session_index(session.id)
        if index >= 0:
            self.sessions[index] = session^
        else:
            self.sessions.append(session^)


def _optional_string(value: JsonValue, key: String, fallback: String) raises -> String:
    if not value.contains(key):
        return fallback
    return _string(value, key)


def _prompt_text(payload: JsonValue) raises -> String:
    if not payload.contains("prompt"):
        return _string(payload, "text")
    var prompt = payload.get("prompt")
    if prompt.kind == JsonValue.STRING:
        return prompt.string_value
    if prompt.kind != JsonValue.ARRAY:
        raise Error("ACP prompt must be a string or content array")
    var result = String("")
    for part in prompt.array_value:
        if part.kind == JsonValue.OBJECT and part.contains("text"):
            result += _string(part, "text")
    return result^


def _agent_message_update(text: String) raises -> JsonValue:
    var update = JsonValue.object()
    update.set("sessionUpdate", JsonValue.string("agent_message_chunk"))
    var content = JsonValue.object()
    content.set("type", JsonValue.string("text"))
    content.set("text", JsonValue.string(text))
    update.set("content", content^)
    return update^


def _history_update(messages: List[Message]) raises -> JsonValue:
    var update = JsonValue.object()
    update.set("sessionUpdate", JsonValue.string("history"))
    var values = JsonValue.array()
    for message in messages:
        var value = JsonValue.object()
        value.set("role", JsonValue.string(message.role))
        value.set("text", JsonValue.string(message.content))
        values.append(value^)
    update.set("messages", values^)
    return update^


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
