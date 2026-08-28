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
    ERROR_LIFECYCLE,
    ERROR_METHOD_NOT_FOUND,
    ERROR_PARSE,
    ERROR_PROTOCOL,
    EVENT_SESSION_END,
    METHOD_HANDSHAKE,
    METHOD_INVOKE,
    METHOD_LIFECYCLE,
    METHOD_REGISTER,
    METHOD_SHUTDOWN,
    PLUGIN_LIFECYCLE_VERSION,
    PLUGIN_MAX_LINE_BYTES,
    PLUGIN_MAX_SESSION_ID_BYTES,
    PLUGIN_PROTOCOL,
    PLUGIN_PROTOCOL_VERSION,
    PluginRegistration,
    RpcMessage,
    error_result,
    handshake_result,
    invoke_result,
    registration_result,
    session_end_result,
    shutdown_result,
)
from std.ffi import external_call, get_errno


trait PluginHandler:
    """Application callbacks implemented by a standalone Mojo plugin."""

    def registration(self) raises -> PluginRegistration:
        ...

    def invoke(
        mut self, kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        ...

    def session_end(mut self, session_id: String) raises:
        """Observe teardown for the exact session being left behind."""
        _ = session_id

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
        var response: String
        if request.method == METHOD_HANDSHAKE:
            response = self._handshake(request)
        elif request.method == METHOD_REGISTER:
            response = self._register(request)
        elif request.method == METHOD_INVOKE:
            response = self._invoke(request)
        elif request.method == METHOD_LIFECYCLE:
            response = self._lifecycle(request)
        elif request.method == METHOD_SHUTDOWN:
            response = self._shutdown(request)
        else:
            response = error_result(
                request.id,
                ERROR_METHOD_NOT_FOUND,
                "unknown plugin method: " + request.method,
            )
        return _bounded_response(request.id, response)

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

    def _lifecycle(mut self, request: RpcMessage) raises -> String:
        if self.state != Self.READY:
            return self._state_error(request.id, METHOD_LIFECYCLE)
        if request.payload.kind != JsonValue.OBJECT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "lifecycle params must be an object",
            )
        if (
            len(request.payload.object_keys) != 3
            or not request.payload.contains("version")
            or not request.payload.contains("event")
            or not request.payload.contains("data")
        ):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "lifecycle params must contain only version, event, and data",
            )
        var version = request.payload.get("version")
        if version.kind != JsonValue.INT:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "lifecycle version must be an integer",
            )
        if version.int_value != PLUGIN_LIFECYCLE_VERSION:
            return error_result(
                request.id,
                ERROR_PROTOCOL,
                "lifecycle protocol version mismatch",
            )
        var event = request.payload.get("event")
        if event.kind != JsonValue.STRING:
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "lifecycle event must be a string",
            )
        if event.string_value != EVENT_SESSION_END:
            return error_result(
                request.id,
                ERROR_METHOD_NOT_FOUND,
                "unsupported plugin lifecycle event: " + event.string_value,
            )
        var data = request.payload.get("data")
        if (
            data.kind != JsonValue.OBJECT
            or len(data.object_keys) != 1
            or not data.contains("session_id")
        ):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "SessionEnd data must contain only session_id",
            )
        var session_id = data.get("session_id")
        if (
            session_id.kind != JsonValue.STRING
            or session_id.string_value == ""
            or session_id.string_value.byte_length()
            > PLUGIN_MAX_SESSION_ID_BYTES
        ):
            return error_result(
                request.id,
                ERROR_INVALID_PARAMS,
                "SessionEnd session_id is empty or exceeds its byte limit",
            )
        try:
            self.handler.session_end(session_id.string_value)
        except:
            return error_result(
                request.id, ERROR_LIFECYCLE, "plugin SessionEnd handler failed"
            )
        return session_end_result(request.id)

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
    var buffered = List[UInt8]()
    while not server.is_closed():
        var line = _read_line(reader, buffered)
        if not line:
            return
        var response = server.handle_line(line.value())
        _write_response(1, response)


def _read_line(
    mut reader: FileDescriptor,
    mut buffered: List[UInt8],
    max_line_bytes: Int = PLUGIN_MAX_LINE_BYTES,
) raises -> Optional[String]:
    """Read a bounded line while retaining bytes already read for the next one."""
    var scan_offset = 0
    while True:
        var scan_end = len(buffered)
        if scan_end > max_line_bytes + 1:
            scan_end = max_line_bytes + 1
        for index in range(scan_offset, scan_end):
            if buffered[index] != UInt8(10):
                continue
            if index > max_line_bytes:
                raise Error("plugin JSON-RPC line exceeds transport limit")
            var line = List[UInt8]()
            var remainder = List[UInt8]()
            for line_index in range(index):
                line.append(buffered[line_index])
            for remainder_index in range(index + 1, len(buffered)):
                remainder.append(buffered[remainder_index])
            buffered = remainder^
            return Optional(String(from_utf8=Span(line)))
        scan_offset = scan_end
        if scan_offset > max_line_bytes:
            raise Error("plugin JSON-RPC line exceeds transport limit")
        var buffer = Array[Byte, 4096](fill=0)
        var count = reader.read_bytes(buffer)
        if count < 0:
            if get_errno().value == 4:
                continue
            raise Error("unable to read plugin JSON-RPC request")
        if count == 0:
            if len(buffered) == 0:
                return None
            var final_line = String(from_utf8=Span(buffered))
            buffered.clear()
            return Optional(final_line^)
        for index in range(count):
            buffered.append(UInt8(buffer[index]))


def _bounded_response(
    id: Int,
    response: String,
    max_line_bytes: Int = PLUGIN_MAX_LINE_BYTES,
) raises -> String:
    if response.byte_length() <= max_line_bytes + 1:
        return response
    return error_result(
        id,
        ERROR_INTERNAL,
        "plugin JSON-RPC response exceeds transport limit",
    )


def _write_response(fd: Int, response: String) raises:
    if not response.endswith("\n"):
        raise Error("plugin JSON-RPC response is missing line framing")
    if response.byte_length() > PLUGIN_MAX_LINE_BYTES + 1:
        raise Error("plugin JSON-RPC response exceeds transport limit")
    _write_all(fd, response)


def _write_all(fd: Int, value: String, max_write_bytes: Int = 0) raises:
    """Write all bytes, retrying interrupts and advancing after short writes."""
    var bytes = List[UInt8](value.as_bytes())
    var offset = 0
    while offset < len(bytes):
        var pointer = bytes.unsafe_ptr().unsafe_offset(offset)
        var write_bytes = len(bytes) - offset
        if max_write_bytes > 0 and write_bytes > max_write_bytes:
            write_bytes = max_write_bytes
        var count = external_call[
            "write",
            Int,
            Int,
            Pointer[mut=True, UInt8, MutAnyOrigin],
            Int,
        ](
            fd,
            rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](pointer),
            write_bytes,
        )
        if count < 0:
            if get_errno().value == 4:
                continue
            raise Error("unable to write plugin JSON-RPC response")
        if count == 0:
            raise Error("plugin JSON-RPC response write made no progress")
        offset += count


def _registration_arrays_are_valid(registration: PluginRegistration) -> Bool:
    return (
        registration.tools.kind == JsonValue.ARRAY
        and registration.commands.kind == JsonValue.ARRAY
        and registration.events.kind == JsonValue.ARRAY
        and registration.prompt_hints.kind == JsonValue.ARRAY
        and registration.keymaps.kind == JsonValue.ARRAY
    )
