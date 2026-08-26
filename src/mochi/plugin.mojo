"""Pure Mojo protocol primitives for executable Mochi plugins.

Plugins are standalone Mojo executables speaking one JSON-RPC 2.0 document per
line over standard input/output.  This module deliberately does not load shared
libraries or depend on Python.
"""

from std.ffi import CStringSlice, c_int, c_pid_t, external_call
from std.sys._libc import close, exit, pipe

from mochi.json import JsonValue, parse_json, serialize_json


comptime PLUGIN_PROTOCOL = "mochi.plugin"
comptime PLUGIN_PROTOCOL_VERSION = 1
comptime JSONRPC_VERSION = "2.0"

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
        var value = JsonValue.object()
        value.set("name", JsonValue.string(self.name))
        value.set("version", JsonValue.string(self.version))
        value.set("tools", self.tools.copy())
        value.set("commands", self.commands.copy())
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
        result.commands = _required_array(value, "commands")
        result.events = _required_array(value, "events")
        result.prompt_hints = _required_array(value, "prompt_hints")
        result.keymaps = _required_array(value, "keymaps")
        return result^


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
    var read_buffer: String
    var fixture_responses: List[String]
    var fixture_writes: List[String]

    def __init__(out self):
        self.pid = -1
        self.write_fd = -1
        self.read_fd = -1
        self.read_buffer = ""
        self.fixture_responses = List[String]()
        self.fixture_writes = List[String]()

    def __deinit__(deinit self):
        self._cleanup()

    @staticmethod
    def spawn(executable: PluginExecutable) raises -> Self:
        var command = executable.command()
        if len(command) == 0 or command[0] == "":
            raise Error("plugin executable path is empty")
        var input_fds = List[c_int](length=2, fill=0)
        var output_fds = List[c_int](length=2, fill=0)
        if pipe(input_fds.unsafe_ptr()) != 0:
            raise Error("unable to create plugin stdin pipe")
        if pipe(output_fds.unsafe_ptr()) != 0:
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            raise Error("unable to create plugin stdout pipe")
        var pid = external_call["fork", c_pid_t]()
        if pid < 0:
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            _ = close(output_fds[0])
            _ = close(output_fds[1])
            raise Error("unable to fork plugin process")
        if pid == 0:
            _ = external_call["dup2", c_int](input_fds[0], c_int(0))
            _ = external_call["dup2", c_int](output_fds[1], c_int(1))
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            _ = close(output_fds[0])
            _ = close(output_fds[1])
            var argv = List[Optional[CStringSlice[ImmutAnyOrigin]]](
                length=len(command) + 1, fill={}
            )
            for i in range(len(command)):
                argv[i] = rebind[CStringSlice[ImmutAnyOrigin]](
                    command[i].as_c_string_slice()
                )
            _ = external_call["execvp", c_int](
                command[0].as_c_string_slice(), argv.unsafe_ptr()
            )
            exit(c_int(127))
        _ = close(input_fds[0])
        _ = close(output_fds[1])
        var result = Self()
        result.pid = pid
        result.write_fd = input_fds[1]
        result.read_fd = output_fds[0]
        return result^

    def enqueue_fixture_response(mut self, var line: String):
        self.fixture_responses.append(line^)

    def send_line(mut self, line: String) raises -> String:
        var framed = line
        if not framed.endswith("\n"):
            framed += "\n"
        self.fixture_writes.append(framed)
        if len(self.fixture_responses) != 0:
            return self.fixture_responses.pop(0)
        if self.write_fd < 0 or self.read_fd < 0:
            raise Error("plugin transport is not connected")
        var writer = FileDescriptor(Int(self.write_fd))
        writer.write_bytes(framed.as_bytes())
        return self.read_line()

    def read_line(mut self) raises -> String:
        if self.read_fd < 0:
            raise Error("plugin transport is not connected")
        var reader = FileDescriptor(Int(self.read_fd))
        while True:
            var buffer = Array[Byte, 1](fill=0)
            var count = reader.read_bytes(buffer)
            if count <= 0:
                raise Error("plugin process closed stdout")
            var byte = buffer[0]
            if byte == 10:
                var result = self.read_buffer.copy()
                self.read_buffer = ""
                return result^
            self.read_buffer += String(byte)

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
            _ = external_call["kill", c_int](self.pid, c_int(9))
            var status = List[c_int](length=1, fill=0)
            _ = external_call["waitpid", c_pid_t](
                self.pid, status.unsafe_ptr(), c_int(0)
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
    def request(id: Int, var method: String, var params: JsonValue) -> RpcMessage:
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
            return RpcMessage.request(id, _required_string(value, "method"), params^)
        if value.contains("result") and not value.contains("error"):
            return RpcMessage.result(id, value.get("result"))
        if value.contains("error") and not value.contains("result"):
            return RpcMessage.failure(id, RpcError.from_json(value.get("error")))
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

    def invoke(mut self, target_kind: String, name: String, var arguments: JsonValue) raises -> String:
        self._require_state(Self.READY, "invoke")
        var params = JsonValue.object()
        params.set("kind", JsonValue.string(target_kind))
        params.set("name", JsonValue.string(name))
        params.set("arguments", arguments^)
        self.state = Self.INVOKE_PENDING
        return self._request(METHOD_INVOKE, params^).to_line()

    def accept_invoke(mut self, line: String) raises -> JsonValue:
        self._require_state(Self.INVOKE_PENDING, "invoke response")
        var result = self._accept_result(line)
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

    def _accept_result(mut self, line: String) raises -> JsonValue:
        var message = RpcMessage.parse(line)
        if message.id != self.pending_id:
            self.state = Self.FAILED
            raise Error("JSON-RPC response id mismatch")
        self.pending_id = 0
        if message.kind == RpcMessage.ERROR:
            self.state = Self.FAILED
            raise Error(
                "plugin error " + String(message.error.code) + ": " + message.error.message
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
        return client^

    def connect(mut self, host_name: String = "mochi") raises:
        try:
            var handshake = self.transport.send_line(self.protocol.handshake(host_name))
            self.protocol.accept_handshake(handshake)
            var registration = self.transport.send_line(
                self.protocol.registration_request()
            )
            self.protocol.accept_registration(registration)
        except err:
            self.cancel()
            raise err

    def reconnect(mut self, host_name: String = "mochi") raises:
        if self.protocol.state != PluginProtocol.CLOSED:
            self.cancel()
        self.protocol = PluginProtocol()
        self.connect(host_name)

    def reload(mut self, host_name: String = "mochi") raises:
        if self.executable:
            self.cancel()
            self.transport = PluginTransport.spawn(self.executable.value().copy())
            self.protocol = PluginProtocol()
            self.connect(host_name)
            return
        self.reconnect(host_name)

    def invoke(
        mut self, target_kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        try:
            var response = self.transport.send_line(
                self.protocol.invoke(target_kind, name, arguments^)
            )
            return self.protocol.accept_invoke(response)
        except err:
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


def registration_result(id: Int, registration: PluginRegistration) raises -> String:
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
