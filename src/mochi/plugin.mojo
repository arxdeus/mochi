"""Pure Mojo protocol primitives for executable Mochi plugins.

Plugins are standalone Mojo executables speaking one JSON-RPC 2.0 document per
line over standard input/output.  This module deliberately does not load shared
libraries or depend on Python.
"""

from std.ffi import (
    CStringSlice,
    c_int,
    c_long,
    c_pid_t,
    c_size_t,
    external_call,
)
from std.sys._libc import close, pipe

from mochi.json import JsonValue, parse_json, serialize_json


comptime PLUGIN_PROTOCOL = "mochi.plugin"
comptime PLUGIN_PROTOCOL_VERSION = 1
comptime JSONRPC_VERSION = "2.0"
comptime PLUGIN_MAX_LINE_BYTES = 8 * 1024 * 1024
comptime PLUGIN_REQUEST_TIMEOUT_SECONDS = 60

comptime METHOD_HANDSHAKE = "plugin/handshake"
comptime METHOD_REGISTER = "plugin/register"
comptime METHOD_INVOKE = "plugin/invoke"
comptime METHOD_SHUTDOWN = "plugin/shutdown"

comptime ERROR_PARSE = -32700
comptime ERROR_INVALID_REQUEST = -32600
comptime ERROR_METHOD_NOT_FOUND = -32601
comptime ERROR_INVALID_PARAMS = -32602
comptime ERROR_INTERNAL = -32603
comptime ERROR_PROTOCOL = -32001
comptime ERROR_INVALID_STATE = -32002
comptime ERROR_INVOKE = -32003


struct PluginRegistration(Copyable, Movable):
    """Metadata advertised by a plugin after the handshake."""

    var name: String
    var version: String
    var tools: JsonValue
    var commands: JsonValue
    var events: JsonValue
    var prompt_hints: JsonValue
    var keymaps: JsonValue

    def __init__(out self, var name: String, var version: String):
        self.name = name^
        self.version = version^
        self.tools = JsonValue.array()
        self.commands = JsonValue.array()
        self.events = JsonValue.array()
        self.prompt_hints = JsonValue.array()
        self.keymaps = JsonValue.array()

    def to_json(self) raises -> JsonValue:
        self.validate()
        var value = JsonValue.object()
        value.set("name", JsonValue.string(self.name))
        value.set("version", JsonValue.string(self.version))
        value.set("tools", self.tools.copy())
        value.set("commands", _normalized_commands(self.commands))
        value.set("events", self.events.copy())
        value.set("prompt_hints", self.prompt_hints.copy())
        value.set("keymaps", self.keymaps.copy())
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> PluginRegistration:
        _require_object(value, "plugin registration")
        var result = PluginRegistration(
            _required_string(value, "name"), _required_string(value, "version")
        )
        result.tools = _required_array(value, "tools")
        result.commands = _normalized_commands(
            _required_array(value, "commands")
        )
        result.events = _required_array(value, "events")
        result.prompt_hints = _required_array(value, "prompt_hints")
        result.keymaps = _required_array(value, "keymaps")
        result.validate()
        return result^

    def validate(self) raises:
        if self.name == "":
            raise Error("plugin registration name must not be empty")
        if self.version == "":
            raise Error("plugin registration version must not be empty")
        for item in self.tools.array_value:
            if item.kind != JsonValue.OBJECT:
                raise Error("plugin tool registration must be an object")
            var name = _required_string(item, "name")
            _validate_tool_name(name)
            var description = _required_string(item, "description")
            if description == "":
                raise Error(
                    "plugin tool description must not be empty: " + name
                )
            var schema = JsonValue.null()
            if item.contains("inputSchema"):
                schema = item.get("inputSchema")
            elif item.contains("parameters"):
                schema = item.get("parameters")
            elif item.contains("schema"):
                # Maki's register_tool contract calls this field `schema`.
                schema = item.get("schema")
            if schema.kind != JsonValue.OBJECT:
                raise Error("plugin tool schema must be an object: " + name)
        var command_keys = List[String]()
        for name in self.command_names():
            var key = plugin_command_key(name)
            for existing in command_keys:
                if existing == key:
                    raise Error("duplicate plugin command name: " + name)
            command_keys.append(key^)

    def command_names(self) raises -> List[String]:
        var names = List[String]()
        var commands = _normalized_commands(self.commands)
        for item in commands.array_value:
            if item.kind == JsonValue.STRING:
                names.append(item.string_value)
            else:
                names.append(_required_string(item, "name"))
        return names^


struct PluginExecutable(Copyable, Movable):
    """Launch metadata for an external executable; transport owns the process."""

    var path: String
    var arguments: List[String]

    def __init__(out self, var path: String):
        self.path = path^
        self.arguments = List[String]()

    def add_argument(mut self, var argument: String):
        self.arguments.append(argument^)

    def command(self) -> List[String]:
        var result = List[String]()
        result.append(self.path)
        for argument in self.arguments:
            result.append(argument)
        return result^


struct PluginTransport(Movable):
    """Newline JSON-RPC transport backed by a child process or test fixtures."""

    var pid: c_pid_t
    var write_fd: Int32
    var read_fd: Int32
    var read_buffer: List[UInt8]
    var read_scan_offset: Int
    var request_timeout_seconds: Int
    var fixture_mode: Bool
    var fixture_responses: List[String]
    var fixture_writes: List[String]

    def __init__(out self):
        self.pid = -1
        self.write_fd = -1
        self.read_fd = -1
        self.read_buffer = List[UInt8]()
        self.read_scan_offset = 0
        self.request_timeout_seconds = PLUGIN_REQUEST_TIMEOUT_SECONDS
        self.fixture_mode = False
        self.fixture_responses = List[String]()
        self.fixture_writes = List[String]()

    def __deinit__(deinit self):
        self._cleanup()

    @staticmethod
    def spawn(executable: PluginExecutable) raises -> Self:
        var command = executable.command()
        if len(command) == 0 or command[0] == "":
            raise Error("plugin executable path is empty")
        # Construct every allocation-backed argument before the C spawn helper
        # forks. Its child path is restricted to async-signal-safe operations.
        var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
            length=len(command) + 1, fill={}
        )
        for i in range(len(command)):
            argv[i] = rebind[CStringSlice[ImmutAnyOrigin]](
                command[i].as_c_string_slice()
            )
        var input_fds = List[c_int](length=2, fill=0)
        var output_fds = List[c_int](length=2, fill=0)
        if pipe(input_fds.unsafe_ptr()) != 0:
            raise Error("unable to create plugin stdin pipe")
        if pipe(output_fds.unsafe_ptr()) != 0:
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            raise Error("unable to create plugin stdout pipe")
        var pid = external_call["mochi_spawn_process", c_pid_t](
            command[0].as_c_string_slice(),
            argv.unsafe_ptr(),
            input_fds[0],
            output_fds[1],
            c_int(-1),
        )
        if pid < 0:
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            _ = close(output_fds[0])
            _ = close(output_fds[1])
            raise Error("unable to spawn plugin process")
        _ = close(input_fds[0])
        _ = close(output_fds[1])
        var result = Self()
        result.pid = pid
        result.write_fd = input_fds[1]
        result.read_fd = output_fds[0]
        return result^

    def enqueue_fixture_response(mut self, var line: String):
        self.fixture_mode = True
        self.fixture_responses.append(line^)

    def send_line(mut self, line: String) raises -> String:
        var framed = line
        if not framed.endswith("\n"):
            framed += "\n"
        if framed.byte_length() > PLUGIN_MAX_LINE_BYTES + 1:
            raise Error("plugin JSON-RPC line exceeds transport limit")
        if self.fixture_mode:
            self.fixture_writes.append(framed)
        if len(self.fixture_responses) != 0:
            return self.fixture_responses.pop(0)
        if self.write_fd < 0 or self.read_fd < 0:
            raise Error("plugin transport is not connected")
        if self.request_timeout_seconds <= 0:
            raise Error("plugin request deadline must be positive")
        var deadline = external_call[
            "mochi_deadline_after_millis", c_long, c_long
        ](c_long(self.request_timeout_seconds * 1000))
        if deadline < 0:
            raise Error("unable to create plugin request deadline")
        var write_status = external_call[
            "mochi_fd_write_all_until",
            c_int,
            c_int,
            CStringSlice[ImmutAnyOrigin],
            c_size_t,
            c_long,
        ](
            c_int(self.write_fd),
            rebind[CStringSlice[ImmutAnyOrigin]](framed.as_c_string_slice()),
            c_size_t(framed.byte_length()),
            deadline,
        )
        if write_status == -2:
            raise Error("plugin request deadline exceeded")
        if write_status != 0:
            raise Error("unable to write plugin request")
        return self.read_line(deadline)

    def read_line(mut self, deadline: c_long) raises -> String:
        if self.read_fd < 0:
            raise Error("plugin transport is not connected")
        while True:
            for newline in range(self.read_scan_offset, len(self.read_buffer)):
                if self.read_buffer[newline] != UInt8(10):
                    continue
                if newline > PLUGIN_MAX_LINE_BYTES:
                    raise Error("plugin JSON-RPC line exceeds transport limit")
                var line = List[UInt8]()
                var remainder = List[UInt8]()
                for index in range(newline):
                    line.append(self.read_buffer[index])
                for index in range(newline + 1, len(self.read_buffer)):
                    remainder.append(self.read_buffer[index])
                self.read_buffer = remainder^
                self.read_scan_offset = 0
                return String(from_utf8=Span(line))
            if len(self.read_buffer) > PLUGIN_MAX_LINE_BYTES:
                raise Error("plugin JSON-RPC line exceeds transport limit")
            self.read_scan_offset = len(self.read_buffer)
            var buffer = List[UInt8](length=4096, fill=0)
            var count = external_call[
                "mochi_fd_read_some_until",
                c_int,
                c_int,
                Pointer[mut=True, UInt8, MutAnyOrigin],
                c_size_t,
                c_long,
            ](
                c_int(self.read_fd),
                rebind[Pointer[mut=True, UInt8, MutAnyOrigin]](
                    buffer.unsafe_ptr()
                ),
                c_size_t(len(buffer)),
                deadline,
            )
            if count == -2:
                raise Error("plugin request deadline exceeded")
            if count < 0:
                raise Error("unable to read plugin response")
            if count == 0:
                raise Error("plugin process closed stdout")
            for index in range(count):
                self.read_buffer.append(buffer[index])

    def cancel(mut self):
        self._cleanup()

    def _cleanup(mut self):
        if self.write_fd >= 0:
            _ = close(c_int(self.write_fd))
            self.write_fd = -1
        if self.read_fd >= 0:
            _ = close(c_int(self.read_fd))
            self.read_fd = -1
        if self.pid > 0:
            var status = List[c_int](length=1, fill=0)
            _ = external_call[
                "mochi_kill_process_group_and_wait",
                c_int,
                c_int,
                Pointer[mut=True, c_int, MutAnyOrigin],
            ](
                c_int(self.pid),
                rebind[Pointer[mut=True, c_int, MutAnyOrigin]](
                    status.unsafe_ptr()
                ),
            )
            self.pid = -1


struct RpcError(Copyable, Movable):
    var code: Int
    var message: String
    var data: JsonValue

    def __init__(out self, code: Int, var message: String):
        self.code = code
        self.message = message^
        self.data = JsonValue.null()

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("code", JsonValue.integer(self.code))
        value.set("message", JsonValue.string(self.message))
        if not self.data.is_null():
            value.set("data", self.data.copy())
        return value^

    @staticmethod
    def from_json(value: JsonValue) raises -> RpcError:
        _require_object(value, "JSON-RPC error")
        var result = RpcError(
            _required_int(value, "code"), _required_string(value, "message")
        )
        if value.contains("data"):
            result.data = value.get("data")
        return result^


struct RpcMessage(Copyable, Movable):
    """A validated JSON-RPC request, success response, or error response."""

    comptime REQUEST = 0
    comptime RESULT = 1
    comptime ERROR = 2

    var kind: Int
    var id: Int
    var method: String
    var payload: JsonValue
    var error: RpcError

    def __init__(out self):
        self.kind = Self.REQUEST
        self.id = 0
        self.method = ""
        self.payload = JsonValue.null()
        self.error = RpcError(0, "")

    @staticmethod
    def request(
        id: Int, var method: String, var params: JsonValue
    ) -> RpcMessage:
        var message = RpcMessage()
        message.kind = RpcMessage.REQUEST
        message.id = id
        message.method = method^
        message.payload = params^
        return message^

    @staticmethod
    def result(id: Int, var result: JsonValue) -> RpcMessage:
        var message = RpcMessage()
        message.kind = RpcMessage.RESULT
        message.id = id
        message.payload = result^
        return message^

    @staticmethod
    def failure(id: Int, var error: RpcError) -> RpcMessage:
        var message = RpcMessage()
        message.kind = RpcMessage.ERROR
        message.id = id
        message.error = error^
        return message^

    def to_json(self) raises -> JsonValue:
        var value = JsonValue.object()
        value.set("jsonrpc", JsonValue.string(JSONRPC_VERSION))
        value.set("id", JsonValue.integer(self.id))
        if self.kind == Self.REQUEST:
            value.set("method", JsonValue.string(self.method))
            value.set("params", self.payload.copy())
        elif self.kind == Self.RESULT:
            value.set("result", self.payload.copy())
        else:
            value.set("error", self.error.to_json())
        return value^

    def to_line(self) raises -> String:
        return serialize_json(self.to_json()) + "\n"

    @staticmethod
    def parse(line: String) raises -> RpcMessage:
        var value: JsonValue
        try:
            value = parse_json(line)
        except:
            raise Error("JSON-RPC parse error")
        _require_object(value, "JSON-RPC message")
        if _required_string(value, "jsonrpc") != JSONRPC_VERSION:
            raise Error("unsupported JSON-RPC version")
        var id = _required_int(value, "id")
        if value.contains("method"):
            if value.contains("result") or value.contains("error"):
                raise Error("invalid JSON-RPC request")
            var params = JsonValue.object()
            if value.contains("params"):
                params = value.get("params")
            return RpcMessage.request(
                id, _required_string(value, "method"), params^
            )
        if value.contains("result") and not value.contains("error"):
            return RpcMessage.result(id, value.get("result"))
        if value.contains("error") and not value.contains("result"):
            return RpcMessage.failure(
                id, RpcError.from_json(value.get("error"))
            )
        raise Error("invalid JSON-RPC response")


struct PluginProtocol(Copyable, Movable):
    """Host-side state machine independent of child-process pipe support."""

    comptime NEW = 0
    comptime HANDSHAKE_PENDING = 1
    comptime REGISTRATION_PENDING = 2
    comptime READY = 3
    comptime INVOKE_PENDING = 4
    comptime SHUTDOWN_PENDING = 5
    comptime CLOSED = 6
    comptime FAILED = 7

    var state: Int
    var next_id: Int
    var pending_id: Int
    var registration: Optional[PluginRegistration]

    def __init__(out self):
        self.state = Self.NEW
        self.next_id = 1
        self.pending_id = 0
        self.registration = None

    def handshake(mut self, host_name: String = "mochi") raises -> String:
        self._require_state(Self.NEW, "handshake")
        var params = JsonValue.object()
        params.set("protocol", JsonValue.string(PLUGIN_PROTOCOL))
        params.set("version", JsonValue.integer(PLUGIN_PROTOCOL_VERSION))
        params.set("host", JsonValue.string(host_name))
        self.state = Self.HANDSHAKE_PENDING
        return self._request(METHOD_HANDSHAKE, params^).to_line()

    def accept_handshake(mut self, line: String) raises:
        self._require_state(Self.HANDSHAKE_PENDING, "handshake response")
        var result = self._accept_result(line)
        if _required_string(result, "protocol") != PLUGIN_PROTOCOL:
            self.state = Self.FAILED
            raise Error("plugin protocol mismatch")
        if _required_int(result, "version") != PLUGIN_PROTOCOL_VERSION:
            self.state = Self.FAILED
            raise Error("plugin protocol version mismatch")
        self.state = Self.REGISTRATION_PENDING

    def registration_request(mut self) raises -> String:
        self._require_state(Self.REGISTRATION_PENDING, "registration")
        return self._request(METHOD_REGISTER, JsonValue.object()).to_line()

    def accept_registration(mut self, line: String) raises:
        self._require_state(Self.REGISTRATION_PENDING, "registration response")
        var result = self._accept_result(line)
        self.registration = PluginRegistration.from_json(result)
        self.state = Self.READY

    def invoke(
        mut self, target_kind: String, name: String, var arguments: JsonValue
    ) raises -> String:
        self._require_state(Self.READY, "invoke")
        var params = JsonValue.object()
        params.set("kind", JsonValue.string(target_kind))
        params.set("name", JsonValue.string(name))
        params.set("arguments", arguments^)
        self.state = Self.INVOKE_PENDING
        return self._request(METHOD_INVOKE, params^).to_line()

    def accept_invoke(mut self, line: String) raises -> JsonValue:
        self._require_state(Self.INVOKE_PENDING, "invoke response")
        # A handler error is an application-level failure, not a broken
        # transport.  Keep the negotiated process usable for later calls.
        var result = self._accept_result(line, recover_state=Self.READY)
        self.state = Self.READY
        return result^

    def shutdown(mut self) raises -> String:
        self._require_state(Self.READY, "shutdown")
        self.state = Self.SHUTDOWN_PENDING
        return self._request(METHOD_SHUTDOWN, JsonValue.object()).to_line()

    def accept_shutdown(mut self, line: String) raises:
        self._require_state(Self.SHUTDOWN_PENDING, "shutdown response")
        _ = self._accept_result(line)
        self.state = Self.CLOSED

    def is_ready(self) -> Bool:
        return self.state == Self.READY

    def _request(mut self, method: String, var params: JsonValue) -> RpcMessage:
        var id = self.next_id
        self.next_id += 1
        self.pending_id = id
        return RpcMessage.request(id, method, params^)

    def _accept_result(
        mut self, line: String, recover_state: Int = -1
    ) raises -> JsonValue:
        var message = RpcMessage.parse(line)
        if message.id != self.pending_id:
            self.state = Self.FAILED
            raise Error("JSON-RPC response id mismatch")
        self.pending_id = 0
        if message.kind == RpcMessage.ERROR:
            self.state = recover_state if recover_state >= 0 else Self.FAILED
            raise Error(
                "plugin error "
                + String(message.error.code)
                + ": "
                + message.error.message
            )
        if message.kind != RpcMessage.RESULT:
            self.state = Self.FAILED
            raise Error("expected JSON-RPC response")
        return message.payload.copy()

    def _require_state(self, expected: Int, operation: String) raises:
        if self.state != expected:
            raise Error("plugin operation out of sequence: " + operation)


struct PluginClient(Movable):
    """Owns a plugin process and performs the complete host-side protocol."""

    var transport: PluginTransport
    var protocol: PluginProtocol
    var executable: Optional[PluginExecutable]

    def __init__(out self, var transport: PluginTransport):
        self.transport = transport^
        self.protocol = PluginProtocol()
        self.executable = None

    @staticmethod
    def launch(
        executable: PluginExecutable, host_name: String = "mochi"
    ) raises -> Self:
        var saved = executable.copy()
        var client = Self(PluginTransport.spawn(executable))
        client.executable = Optional(saved^)
        client.connect(host_name)
        client.require_live_process()
        return client^

    def connect(mut self, host_name: String = "mochi") raises:
        try:
            var handshake = self.transport.send_line(
                self.protocol.handshake(host_name)
            )
            self.protocol.accept_handshake(handshake)
            var registration = self.transport.send_line(
                self.protocol.registration_request()
            )
            self.protocol.accept_registration(registration)
        except err:
            self.cancel()
            raise err

    def reconnect(mut self, host_name: String = "mochi") raises:
        # Executable transports cannot be reused after shutdown closes their
        # descriptors. Use the same validated shadow transition as reload so a
        # failed reconnect also leaves a live generation untouched.
        self.reload(host_name)

    def replacement(self, host_name: String = "mochi") raises -> Self:
        """Start and validate a shadow process without disturbing this client."""
        if self.executable:
            return Self.launch(self.executable.value().copy(), host_name)
        if (
            self.transport.pid > 0
            or self.transport.write_fd >= 0
            or self.transport.read_fd >= 0
        ):
            raise Error("plugin client has no executable launch metadata")
        # Unit fixtures also get a real shadow generation: copy only the
        # remaining scripted responses, negotiate the candidate, and leave the
        # live protocol untouched until the caller commits the replacement.
        var transport = PluginTransport()
        transport.request_timeout_seconds = (
            self.transport.request_timeout_seconds
        )
        transport.fixture_mode = self.transport.fixture_mode
        transport.fixture_responses = self.transport.fixture_responses.copy()
        transport.fixture_writes = self.transport.fixture_writes.copy()
        var candidate = Self(transport^)
        candidate.connect(host_name)
        return candidate^

    def reload(mut self, host_name: String = "mochi") raises:
        # The replacement must finish handshake and registration before the
        # live process is touched. A process or fixture protocol failure leaves
        # the last known-good generation callable.
        var candidate = self.replacement(host_name)
        candidate.require_live_process()
        self.cancel()
        self = candidate^

    def require_live_process(mut self) raises:
        """Reject an executable whose negotiated leader already terminated."""
        if self.transport.pid <= 0:
            return
        var alive = external_call["mochi_process_is_alive", c_int](
            c_int(self.transport.pid)
        )
        if alive == 1:
            return
        self.cancel()
        if alive == 0:
            raise Error("plugin process exited after registration")
        raise Error("unable to verify plugin process liveness")

    def invoke(
        mut self, target_kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        try:
            var response = self.transport.send_line(
                self.protocol.invoke(target_kind, name, arguments^)
            )
            return self.protocol.accept_invoke(response)
        except err:
            if not self.protocol.is_ready():
                self.cancel()
            raise err

    def shutdown(mut self) raises:
        try:
            var response = self.transport.send_line(self.protocol.shutdown())
            self.protocol.accept_shutdown(response)
            self.transport.cancel()
        except err:
            self.cancel()
            raise err

    def cancel(mut self):
        if self.protocol.state != PluginProtocol.CLOSED:
            self.protocol.state = PluginProtocol.FAILED
        self.transport.cancel()

    def is_ready(self) -> Bool:
        return self.protocol.is_ready()


def handshake_result(id: Int, plugin_name: String = "plugin") raises -> String:
    """Build the plugin-side response to a successful handshake."""
    var result = JsonValue.object()
    result.set("protocol", JsonValue.string(PLUGIN_PROTOCOL))
    result.set("version", JsonValue.integer(PLUGIN_PROTOCOL_VERSION))
    result.set("plugin", JsonValue.string(plugin_name))
    return RpcMessage.result(id, result^).to_line()


def registration_result(
    id: Int, registration: PluginRegistration
) raises -> String:
    return RpcMessage.result(id, registration.to_json()).to_line()


def invoke_result(id: Int, var result: JsonValue) raises -> String:
    return RpcMessage.result(id, result^).to_line()


def shutdown_result(id: Int) raises -> String:
    return RpcMessage.result(id, JsonValue.null()).to_line()


def error_result(id: Int, code: Int, message: String) raises -> String:
    return RpcMessage.failure(id, RpcError(code, message)).to_line()


def _require_object(value: JsonValue, label: String) raises:
    if value.kind != JsonValue.OBJECT:
        raise Error(label + " must be a JSON object")


def _required_string(value: JsonValue, key: String) raises -> String:
    var field = value.get(key)
    if field.kind != JsonValue.STRING:
        raise Error("JSON field must be a string: " + key)
    return field.string_value


def _required_int(value: JsonValue, key: String) raises -> Int:
    var field = value.get(key)
    if field.kind != JsonValue.INT:
        raise Error("JSON field must be an integer: " + key)
    return field.int_value


def _required_array(value: JsonValue, key: String) raises -> JsonValue:
    var field = value.get(key)
    if field.kind != JsonValue.ARRAY:
        raise Error("JSON field must be an array: " + key)
    return field^


def _validate_tool_name(value: String) raises:
    if value == "" or value.byte_length() > 64:
        raise Error("plugin tool name must contain 1 to 64 ASCII characters")
    for index in range(value.byte_length()):
        var byte = UInt8(ord(value[byte=index]))
        var alpha = (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)
        var valid = alpha or byte == 95
        if index > 0:
            valid = valid or (byte >= 48 and byte <= 57)
        if not valid:
            raise Error("invalid plugin tool name: " + value)


def normalize_plugin_command_name(value: String) raises -> String:
    """Return one leading slash and reject names the UI cannot tokenize."""
    var plain = value.copy()
    if plain.startswith("/"):
        var source = plain.copy()
        plain = String(source.removeprefix("/"))
    if plain == "" or plain.startswith("/"):
        raise Error("plugin command name must contain one non-slash character")
    for cp in plain.codepoints():
        var codepoint = Int(cp.to_u32())
        var control = codepoint < 32 or (codepoint >= 127 and codepoint <= 159)
        var whitespace = (
            codepoint == 32
            or codepoint == 160
            or codepoint == 5760
            or (codepoint >= 8192 and codepoint <= 8202)
            or codepoint == 8232
            or codepoint == 8233
            or codepoint == 8239
            or codepoint == 8287
            or codepoint == 12288
        )
        if control or whitespace:
            raise Error(
                "plugin command name must not contain whitespace or control"
                " characters"
            )
    return "/" + plain


def plugin_command_key(value: String) raises -> String:
    """Canonical command identity shared by registration, runtime, and UI."""
    var normalized = normalize_plugin_command_name(value)
    return normalized.lower()


def _normalized_commands(value: JsonValue) raises -> JsonValue:
    if value.kind != JsonValue.ARRAY:
        raise Error("plugin commands registration must be an array")
    var commands = JsonValue.array()
    for item in value.array_value:
        var name: String
        if item.kind == JsonValue.STRING:
            name = normalize_plugin_command_name(item.string_value)
            commands.append(JsonValue.string(name))
        elif item.kind == JsonValue.OBJECT:
            name = normalize_plugin_command_name(_required_string(item, "name"))
            var normalized = item.copy()
            normalized.set("name", JsonValue.string(name))
            commands.append(normalized^)
        else:
            raise Error(
                "plugin command registration must be a string or object"
            )
    return commands^
