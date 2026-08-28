"""Plugin-side SDK for Mochi's native executable plugin protocol.

Implement ``PluginHandler`` and pass it to ``run_stdio`` from a Mojo plugin's
``main`` function.  The SDK owns the strict JSON-RPC lifecycle and keeps plugin
code independent from pipe and framing details.
"""

from mochi.json import JsonValue
from mochi.plugin import (
    ERROR_INTERNAL,
    ERROR_INVALID_PARAMS,
    ERROR_INVALID_REQUEST,
    ERROR_INVALID_STATE,
    ERROR_INVOKE,
    ERROR_METHOD_NOT_FOUND,
    ERROR_PARSE,
    ERROR_PROTOCOL,
    METHOD_HANDSHAKE,
    METHOD_INVOKE,
    METHOD_REGISTER,
    METHOD_SHUTDOWN,
    PLUGIN_MAX_LINE_BYTES,
    PLUGIN_PROTOCOL,
    PLUGIN_PROTOCOL_VERSION,
    PluginRegistration,
    RpcMessage,
    error_result,
    handshake_result,
    invoke_result,
    registration_result,
    shutdown_result,
)


trait PluginHandler:
    """Application callbacks implemented by a standalone Mojo plugin."""

    def registration(self) raises -> PluginRegistration:
        ...

    def invoke(
        mut self, kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        ...

    def shutdown(mut self) raises:
        ...


struct PluginServer[Handler: PluginHandler & Movable & Deinitable](Movable):
    """Strict plugin-side state machine and newline JSON-RPC codec."""

    comptime NEW = 0
    comptime HANDSHAKEN = 1
    comptime READY = 2
    comptime CLOSED = 3
    comptime FAILED = 4

    var handler: Self.Handler
    var state: Int

    def __init__(out self, var handler: Self.Handler):
        self.handler = handler^
        self.state = Self.NEW

    def is_ready(self) -> Bool:
        return self.state == Self.READY

    def is_closed(self) -> Bool:
        return self.state == Self.CLOSED

    def handle_line(mut self, line: String) raises -> String:
        """Decode one request line and always return one response line."""
        if line.byte_length() > PLUGIN_MAX_LINE_BYTES:
            return error_result(
                0,
                ERROR_INVALID_REQUEST,
                "plugin JSON-RPC line exceeds transport limit",
            )
        var request: RpcMessage
        try:
            request = RpcMessage.parse(line)
        except:
            return error_result(0, ERROR_PARSE, "JSON-RPC parse error")

        if request.kind != RpcMessage.REQUEST:
            return error_result(
                request.id, ERROR_INVALID_REQUEST, "expected JSON-RPC request"
            )
        if request.method == METHOD_HANDSHAKE:
            return self._handshake(request)
        if request.method == METHOD_REGISTER:
            return self._register(request)
        if request.method == METHOD_INVOKE:
            return self._invoke(request)
        if request.method == METHOD_SHUTDOWN:
            return self._shutdown(request)
        return error_result(
            request.id,
            ERROR_METHOD_NOT_FOUND,
            "unknown plugin method: " + request.method,
        )

    def _handshake(mut self, request: RpcMessage) raises -> String:
        if self.state != Self.NEW:
            return self._state_error(request.id, METHOD_HANDSHAKE)
        if request.payload.kind != JsonValue.OBJECT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake params must be an object",
            )
        if not request.payload.contains("protocol"):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake protocol is required",
            )
        if not request.payload.contains("version"):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake version is required",
            )
        if not request.payload.contains("host"):
            return error_result(
                request.id, ERROR_INVALID_PARAMS, "handshake host is required"
            )
        var protocol = request.payload.get("protocol")
        var version = request.payload.get("version")
        var host = request.payload.get("host")
        if protocol.kind != JsonValue.STRING:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake protocol must be a string",
            )
        if version.kind != JsonValue.INT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake version must be an integer",
            )
        if host.kind != JsonValue.STRING or host.string_value == "":
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "handshake host must be non-empty",
            )
        if protocol.string_value != PLUGIN_PROTOCOL:
            return error_result(
                request.id, ERROR_PROTOCOL, "plugin protocol mismatch"
            )
        if version.int_value != PLUGIN_PROTOCOL_VERSION:
            return error_result(
                request.id, ERROR_PROTOCOL, "plugin protocol version mismatch"
            )
        self.state = Self.HANDSHAKEN
        return handshake_result(request.id)

    def _register(mut self, request: RpcMessage) raises -> String:
        if self.state != Self.HANDSHAKEN:
            return self._state_error(request.id, METHOD_REGISTER)
        if request.payload.kind != JsonValue.OBJECT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "registration params must be an object",
            )
        var registration: PluginRegistration
        try:
            registration = self.handler.registration()
            if not _registration_arrays_are_valid(registration):
                raise Error("plugin registration arrays are invalid")
            registration.validate()
        except:
            self.state = Self.FAILED
            return error_result(
                request.id, ERROR_INTERNAL, "plugin registration failed"
            )
        self.state = Self.READY
        return registration_result(request.id, registration)

    def _invoke(mut self, request: RpcMessage) raises -> String:
        if self.state != Self.READY:
            return self._state_error(request.id, METHOD_INVOKE)
        if request.payload.kind != JsonValue.OBJECT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "invoke params must be an object",
            )
        if not request.payload.contains("kind"):
            return error_result(
                request.id, ERROR_INVALID_PARAMS, "invoke kind is required"
            )
        if not request.payload.contains("name"):
            return error_result(
                request.id, ERROR_INVALID_PARAMS, "invoke name is required"
            )
        if not request.payload.contains("arguments"):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "invoke arguments are required",
            )
        var kind = request.payload.get("kind")
        var name = request.payload.get("name")
        if kind.kind != JsonValue.STRING or kind.string_value == "":
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "invoke kind must be non-empty",
            )
        if name.kind != JsonValue.STRING or name.string_value == "":
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "invoke name must be non-empty",
            )
        var arguments = request.payload.get("arguments")
        var result: JsonValue
        try:
            result = self.handler.invoke(
                kind.string_value, name.string_value, arguments^
            )
        except:
            return error_result(
                request.id, ERROR_INVOKE, "plugin invocation failed"
            )
        return invoke_result(request.id, result^)

    def _shutdown(mut self, request: RpcMessage) raises -> String:
        if self.state != Self.READY:
            return self._state_error(request.id, METHOD_SHUTDOWN)
        if request.payload.kind != JsonValue.OBJECT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "shutdown params must be an object",
            )
        try:
            self.handler.shutdown()
        except:
            self.state = Self.FAILED
            return error_result(
                request.id, ERROR_INTERNAL, "plugin shutdown failed"
            )
        self.state = Self.CLOSED
        return shutdown_result(request.id)

    def _state_error(self, id: Int, operation: String) raises -> String:
        return error_result(
            id,
            ERROR_INVALID_STATE,
            "plugin operation out of sequence: " + operation,
        )


def run_stdio[
    Handler: PluginHandler & Movable & Deinitable
](var handler: Handler) raises:
    """Serve one JSON-RPC document per line on standard input/output."""
    var server = PluginServer[Handler](handler^)
    var reader = FileDescriptor(0)
    var writer = FileDescriptor(1)
    while not server.is_closed():
        var line = _read_line(reader)
        if not line:
            return
        var response = server.handle_line(line.value())
        writer.write_bytes(response.as_bytes())


def _read_line(mut reader: FileDescriptor) raises -> Optional[String]:
    var result = List[UInt8]()
    while True:
        var buffer = Array[Byte, 1](fill=0)
        var count = reader.read_bytes(buffer)
        if count <= 0:
            if len(result) == 0:
                return None
            return Optional(String(from_utf8=Span(result)))
        if buffer[0] == 10:
            return Optional(String(from_utf8=Span(result)))
        if len(result) >= PLUGIN_MAX_LINE_BYTES:
            raise Error("plugin JSON-RPC line exceeds transport limit")
        result.append(UInt8(buffer[0]))


def _registration_arrays_are_valid(registration: PluginRegistration) -> Bool:
    return (
        registration.tools.kind == JsonValue.ARRAY
        and registration.commands.kind == JsonValue.ARRAY
        and registration.events.kind == JsonValue.ARRAY
        and registration.prompt_hints.kind == JsonValue.ARRAY
        and registration.keymaps.kind == JsonValue.ARRAY
    )
