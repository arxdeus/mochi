"""Pure Mojo Model Context Protocol client primitives and transports."""

from std.ffi import CStringSlice, c_char, c_int, c_pid_t, external_call
from std.os import Process
from std.sys._libc import close, dup2, execvp, exit, pipe

from mochi.http import FlokiTransport, HttpRequest, HttpTransport
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.storage import OAuthTokens


comptime MCP_PROTOCOL_VERSION = "2025-06-18"


@fieldwise_init
struct McpOAuthState(Copyable, Movable):
    var tokens: OAuthTokens
    var token_endpoint: String
    var client_id: String
    var client_secret: String
    var resource: String

    def expired(self, now_ms: Int, margin_ms: Int = 30000) -> Bool:
        return self.tokens.expires > 0 and now_ms + margin_ms >= self.tokens.expires

    def can_refresh(self) -> Bool:
        return self.tokens.refresh != "" and self.token_endpoint != "" and self.client_id != ""

    def authorization_header(self) -> String:
        if self.tokens.access == "":
            return ""
        return "Bearer " + self.tokens.access

    def refresh_request(self) raises -> HttpRequest:
        if not self.can_refresh():
            raise Error("MCP OAuth refresh is not configured")
        var request = HttpRequest("POST", self.token_endpoint)
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        request.body = (
            "grant_type=refresh_token&refresh_token=" + _form_encode(self.tokens.refresh)
            + "&client_id=" + _form_encode(self.client_id)
        )
        if self.client_secret != "":
            request.body += "&client_secret=" + _form_encode(self.client_secret)
        if self.resource != "":
            request.body += "&resource=" + _form_encode(self.resource)
        return request^

    def apply_refresh_response(mut self, body: String, now_ms: Int) raises:
        var value = parse_json(body)
        if not value.contains("access_token"):
            raise Error("MCP OAuth refresh response has no access token")
        self.tokens.access = value.get("access_token").string_value
        if value.contains("refresh_token"):
            var refresh = value.get("refresh_token").string_value
            if refresh != "":
                self.tokens.refresh = refresh
        var expires_in = 3600
        if value.contains("expires_in"):
            expires_in = value.get("expires_in").int_value
        self.tokens.expires = now_ms + expires_in * 1000


def _form_encode(value: String) -> String:
    var output = String("")
    comptime digits = "0123456789ABCDEF"
    for byte in value.as_bytes():
        var code = Int(byte)
        if (
            (code >= 48 and code <= 57)
            or (code >= 65 and code <= 90)
            or (code >= 97 and code <= 122)
            or code == 45
            or code == 46
            or code == 95
            or code == 126
        ):
            output += chr(code)
        else:
            output += "%" + String(digits[byte=(code >> 4) & 15]) + String(digits[byte=code & 15])
    return output^


def _empty_object() -> JsonValue:
    return JsonValue.object()


def _request_envelope(
    id: Int, method: String, var params: Optional[JsonValue] = None
) raises -> JsonValue:
    var message = JsonValue.object()
    message.set("jsonrpc", JsonValue.string("2.0"))
    message.set("id", JsonValue.integer(id))
    message.set("method", JsonValue.string(method))
    if params:
        message.set("params", params.value().copy())
    return message^


def _notification_envelope(
    method: String, var params: Optional[JsonValue] = None
) raises -> JsonValue:
    var message = JsonValue.object()
    message.set("jsonrpc", JsonValue.string("2.0"))
    message.set("method", JsonValue.string(method))
    if params:
        message.set("params", params.value().copy())
    return message^


def _response_result(message: JsonValue, expected_id: Int) raises -> JsonValue:
    if message.kind != JsonValue.OBJECT:
        raise Error("MCP response is not an object")
    if (
        not message.contains("jsonrpc")
        or message.get("jsonrpc").string_value != "2.0"
    ):
        raise Error("Invalid JSON-RPC version")
    if not message.contains("id") or message.get("id").int_value != expected_id:
        raise Error("MCP response id mismatch")
    if message.contains("error"):
        raise Error("MCP JSON-RPC error: " + message.get("error").serialize())
    if not message.contains("result"):
        raise Error("MCP response has no result")
    return message.get("result")


def _page_params(cursor: String) raises -> Optional[JsonValue]:
    if cursor == "":
        return None
    var params = JsonValue.object()
    params.set("cursor", JsonValue.string(cursor))
    return Optional(params^)


def _collect_pages(
    pages: List[JsonValue], field: String
) raises -> List[JsonValue]:
    var values = List[JsonValue]()
    var expected_cursor = String("")
    for i in range(len(pages)):
        var page = pages[i].copy()
        if page.kind != JsonValue.OBJECT or not page.contains(field):
            raise Error("Invalid MCP pagination result")
        var items = page.get(field)
        if items.kind != JsonValue.ARRAY:
            raise Error("MCP page field is not an array")
        for j in range(len(items.array_value)):
            values.append(items.array_value[j].copy())
        var next_cursor = String("")
        if page.contains("nextCursor"):
            next_cursor = page.get("nextCursor").string_value
        if next_cursor != "" and i + 1 == len(pages):
            raise Error("Missing MCP pagination page")
        if next_cursor == "" and i + 1 != len(pages):
            raise Error("Unexpected MCP pagination page")
        expected_cursor = next_cursor
    _ = expected_cursor
    return values^


struct McpSession(Copyable, Movable):
    """Transport-independent JSON-RPC state machine with fixture helpers."""

    var next_id: Int
    var initialized: Bool
    var capabilities: JsonValue
    var pending_ids: List[Int]
    var cancelled_ids: List[Int]
    var fixture_outbox: List[String]

    def __init__(out self):
        self.next_id = 0
        self.initialized = False
        self.capabilities = JsonValue.object()
        self.pending_ids = List[Int]()
        self.cancelled_ids = List[Int]()
        self.fixture_outbox = List[String]()

    def make_request(
        mut self, method: String, var params: Optional[JsonValue] = None
    ) raises -> JsonValue:
        self.next_id += 1
        self.pending_ids.append(self.next_id)
        return _request_envelope(self.next_id, method, params^)

    def make_notification(
        self, method: String, var params: Optional[JsonValue] = None
    ) raises -> JsonValue:
        return _notification_envelope(method, params^)

    def accept_response(
        mut self, var response: JsonValue, expected_id: Int
    ) raises -> JsonValue:
        var result = _response_result(response, expected_id)
        for i in range(len(self.pending_ids)):
            if self.pending_ids[i] == expected_id:
                _ = self.pending_ids.pop(i)
                return result^
        raise Error("MCP response is not pending")

    def initialize_request(
        mut self,
        client_name: String = "mochi",
        client_version: String = "0.1.0",
    ) raises -> JsonValue:
        var info = JsonValue.object()
        info.set("name", JsonValue.string(client_name))
        info.set("version", JsonValue.string(client_version))
        var params = JsonValue.object()
        params.set("protocolVersion", JsonValue.string(MCP_PROTOCOL_VERSION))
        params.set("capabilities", JsonValue.object())
        params.set("clientInfo", info^)
        return self.make_request("initialize", Optional(params^))

    def accept_initialize(
        mut self, var response: JsonValue, expected_id: Int
    ) raises -> JsonValue:
        var result = self.accept_response(response^, expected_id)
        if result.kind != JsonValue.OBJECT:
            raise Error("Invalid MCP initialize result")
        if (
            result.contains("protocolVersion")
            and result.get("protocolVersion").string_value
            != MCP_PROTOCOL_VERSION
        ):
            raise Error("Unsupported MCP protocol version")
        self.capabilities = result.copy()
        self.initialized = True
        return result^

    def initialized_notification(self) raises -> JsonValue:
        if not self.initialized:
            raise Error("MCP session has not initialized")
        return self.make_notification("notifications/initialized")

    def tools_list_request(mut self, cursor: String = "") raises -> JsonValue:
        return self.make_request("tools/list", _page_params(cursor))

    def tools_call_request(
        mut self, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        var params = JsonValue.object()
        params.set("name", JsonValue.string(name))
        params.set("arguments", arguments^)
        return self.make_request("tools/call", Optional(params^))

    def prompts_list_request(mut self, cursor: String = "") raises -> JsonValue:
        return self.make_request("prompts/list", _page_params(cursor))

    def prompts_get_request(
        mut self, name: String, var arguments: Optional[JsonValue] = None
    ) raises -> JsonValue:
        var params = JsonValue.object()
        params.set("name", JsonValue.string(name))
        if arguments:
            params.set("arguments", arguments.value().copy())
        return self.make_request("prompts/get", Optional(params^))

    def resources_list_request(
        mut self, cursor: String = ""
    ) raises -> JsonValue:
        return self.make_request("resources/list", _page_params(cursor))

    def resources_read_request(mut self, uri: String) raises -> JsonValue:
        var params = JsonValue.object()
        params.set("uri", JsonValue.string(uri))
        return self.make_request("resources/read", Optional(params^))

    def cancellation_notification(
        mut self, request_id: Int, reason: String = ""
    ) raises -> JsonValue:
        self.cancelled_ids.append(request_id)
        var params = JsonValue.object()
        params.set("requestId", JsonValue.integer(request_id))
        if reason != "":
            params.set("reason", JsonValue.string(reason))
        return self.make_notification(
            "notifications/cancelled", Optional(params^)
        )

    def accept_notification(mut self, notification: JsonValue) raises:
        if notification.kind != JsonValue.OBJECT or notification.contains("id"):
            raise Error("Invalid MCP notification")
        if notification.get("jsonrpc").string_value != "2.0":
            raise Error("Invalid JSON-RPC version")
        if notification.get("method").string_value == "notifications/cancelled":
            self.cancelled_ids.append(
                notification.get("params").get("requestId").int_value
            )

    def is_cancelled(self, request_id: Int) -> Bool:
        for value in self.cancelled_ids:
            if value == request_id:
                return True
        return False

    def fixture_exchange(
        mut self, var request: JsonValue, response_text: String
    ) raises -> JsonValue:
        """Record an outbound message and consume a supplied server response."""
        self.fixture_outbox.append(serialize_json(request))
        var response = parse_json(response_text)
        return self.accept_response(response^, request.get("id").int_value)

    @staticmethod
    def collect_tools(pages: List[JsonValue]) raises -> List[JsonValue]:
        return _collect_pages(pages, "tools")

    @staticmethod
    def collect_prompts(pages: List[JsonValue]) raises -> List[JsonValue]:
        return _collect_pages(pages, "prompts")

    @staticmethod
    def collect_resources(pages: List[JsonValue]) raises -> List[JsonValue]:
        return _collect_pages(pages, "resources")


struct StdioTransport(Movable):
    """Newline-delimited MCP transport backed by POSIX pipes and a child process.
    """

    var process: Optional[Process]
    var pid: c_pid_t
    var write_fd: Int32
    var read_fd: Int32
    var read_buffer: String
    var fixture_responses: List[String]
    var fixture_writes: List[String]

    def __init__(out self):
        """Create a fixture-only transport that does not spawn a process."""
        self.process = None
        self.pid = -1
        self.write_fd = -1
        self.read_fd = -1
        self.read_buffer = ""
        self.fixture_responses = List[String]()
        self.fixture_writes = List[String]()

    def __deinit__(deinit self):
        self._cleanup()

    @staticmethod
    def spawn(var command: List[String]) raises -> Self:
        if len(command) == 0:
            raise Error("MCP command is empty")
        var input_fds = List[c_int](length=2, fill=0)
        var output_fds = List[c_int](length=2, fill=0)
        if pipe(input_fds.unsafe_ptr()) != 0:
            raise Error("Unable to create MCP stdin pipe")
        if pipe(output_fds.unsafe_ptr()) != 0:
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            raise Error("Unable to create MCP stdout pipe")
        var pid = external_call["fork", c_pid_t]()
        if pid < 0:
            raise Error("Unable to fork MCP process")
        if pid == 0:
            _ = dup2(input_fds[0], c_int(0))
            _ = dup2(output_fds[1], c_int(1))
            _ = close(input_fds[0])
            _ = close(input_fds[1])
            _ = close(output_fds[0])
            _ = close(output_fds[1])
            var argv = List[OptionalPointer[mut=False, c_char, ImmutAnyOrigin]](
                length=len(command) + 1, fill={}
            )
            for i in range(len(command)):
                argv[i] = rebind[
                    OptionalPointer[mut=False, c_char, ImmutAnyOrigin]
                ](command[i].as_c_string_slice().ptr())
            _ = execvp(command[0].as_c_string_slice().ptr(), argv.unsafe_ptr())
            exit(c_int(127))
        _ = close(input_fds[0])
        _ = close(output_fds[1])
        var result = Self()
        result.process = Process(child_pid=pid)
        result.pid = pid
        result.write_fd = input_fds[1]
        result.read_fd = output_fds[0]
        return result^

    def enqueue_fixture_response(mut self, response: String):
        self.fixture_responses.append(response)

    def send(mut self, message: JsonValue) raises -> JsonValue:
        var line = serialize_json(message) + "\n"
        self.fixture_writes.append(line)
        if len(self.fixture_responses) != 0:
            return parse_json(self.fixture_responses.pop(0))
        if self.write_fd < 0 or self.read_fd < 0:
            raise Error("MCP stdio transport is not connected")
        var writer = FileDescriptor(Int(self.write_fd))
        writer.write_bytes(line.as_bytes())
        var reader = FileDescriptor(Int(self.read_fd))
        while True:
            var buffer = Array[Byte, 1](fill=0)
            var count = reader.read_bytes(buffer)
            if count <= 0:
                raise Error("MCP stdio server closed")
            var byte = buffer[0]
            if byte == 10:
                var response = parse_json(self.read_buffer)
                self.read_buffer = ""
                return response^
            self.read_buffer += String(byte)

    def notify(mut self, message: JsonValue) raises:
        var line = serialize_json(message) + "\n"
        self.fixture_writes.append(line)
        if self.write_fd < 0:
            return
        var writer = FileDescriptor(Int(self.write_fd))
        writer.write_bytes(line.as_bytes())

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
            self.process = None


struct StreamableHttpTransport(Copyable, Movable):
    """Synchronous MCP Streamable HTTP adapter over injectable HttpTransport."""

    var url: String
    var session_id: String
    var timeout_ms: Int
    var bearer_token: String
    var fixture_only: Bool
    var fixture_status: Int
    var fixture_content_type: String
    var fixture_session_id: String
    var fixture_body: String

    def __init__(out self, url: String, timeout_ms: Int = 60000):
        self.url = url
        self.session_id = ""
        self.timeout_ms = timeout_ms
        self.bearer_token = ""
        self.fixture_only = False
        self.fixture_status = 0
        self.fixture_content_type = "application/json"
        self.fixture_session_id = ""
        self.fixture_body = ""

    def request_body(self, message: JsonValue) -> String:
        return serialize_json(message)

    def content_type(self) -> String:
        return "application/json"

    def accept_header(self) -> String:
        return "application/json, text/event-stream"

    def session_header(self) -> String:
        return self.session_id

    def set_bearer_token(mut self, token: String):
        self.bearer_token = token

    def clear_bearer_token(mut self):
        self.bearer_token = ""

    def fixture_response(
        mut self,
        status: Int,
        content_type: String,
        body: String,
        session_id: String = "",
    ):
        self.fixture_only = True
        self.fixture_status = status
        self.fixture_content_type = content_type
        self.fixture_body = body
        self.fixture_session_id = session_id

    def consume_fixture(mut self, expected_id: Int) raises -> JsonValue:
        var status = self.fixture_status
        var content_type = self.fixture_content_type.copy()
        var body = self.fixture_body.copy()
        var session_id = self.fixture_session_id.copy()
        self.fixture_status = 0
        return self.accept_response(
            status, content_type, body, session_id, expected_id
        )

    def _request(self, method: String, body: String = "") -> HttpRequest:
        var request = HttpRequest(method, self.url)
        request.timeout_ms = self.timeout_ms
        request.add_header("Accept", self.accept_header())
        if self.bearer_token != "":
            request.add_header("Authorization", "Bearer " + self.bearer_token)
        if method == "POST":
            request.add_header("Content-Type", self.content_type())
            request.body = body
        if self.session_id != "":
            request.add_header("Mcp-Session-Id", self.session_id)
        return request^

    def send(mut self, message: JsonValue) raises -> JsonValue:
        var expected_id = message.get("id").int_value
        if self.fixture_status != 0:
            return self.consume_fixture(expected_id)
        var transport = FlokiTransport()
        return self.send_with(transport, message)

    def send_with[T: HttpTransport](
        mut self, mut transport: T, message: JsonValue
    ) raises -> JsonValue:
        var expected_id = message.get("id").int_value
        var response = transport.perform(
            self._request("POST", self.request_body(message))
        )
        var content_type = response.content_type()
        if content_type == "":
            content_type = "application/json"
        return self.accept_response(
            response.status,
            content_type,
            response.body,
            response.mcp_session_id(),
            expected_id,
        )

    def notify(mut self, message: JsonValue) raises:
        if self.fixture_only and self.fixture_status == 0:
            return
        if self.fixture_status != 0:
            var status = self.fixture_status
            var fixture_session_id = self.fixture_session_id.copy()
            self.fixture_status = 0
            if status < 200 or status >= 300:
                raise Error("MCP HTTP request failed with status " + String(status))
            if fixture_session_id != "":
                self.session_id = fixture_session_id
            return
        var transport = FlokiTransport()
        self.notify_with(transport, message)

    def notify_with[T: HttpTransport](
        mut self, mut transport: T, message: JsonValue
    ) raises:
        var response = transport.perform(
            self._request("POST", self.request_body(message))
        )
        if response.status < 200 or response.status >= 300:
            raise Error("MCP HTTP request failed with status " + String(response.status))
        if response.mcp_session_id() != "":
            self.session_id = response.mcp_session_id()

    def delete_session(mut self) raises:
        if self.session_id == "":
            return
        if self.fixture_only and self.fixture_status == 0:
            self.session_id = ""
            return
        if self.fixture_status != 0:
            var status = self.fixture_status
            self.fixture_status = 0
            if status < 200 or status >= 300:
                raise Error("MCP HTTP DELETE failed with status " + String(status))
            self.session_id = ""
            return
        var transport = FlokiTransport()
        self.delete_session_with(transport)

    def delete_session_with[T: HttpTransport](
        mut self, mut transport: T
    ) raises:
        if self.session_id == "":
            return
        var response = transport.perform(self._request("DELETE"))
        if response.status < 200 or response.status >= 300:
            raise Error("MCP HTTP DELETE failed with status " + String(response.status))
        self.session_id = ""

    def accept_response(
        mut self,
        status: Int,
        content_type: String,
        body: String,
        new_session_id: String,
        expected_id: Int,
    ) raises -> JsonValue:
        if status < 200 or status >= 300:
            raise Error("MCP HTTP request failed with status " + String(status))
        if new_session_id != "":
            self.session_id = new_session_id
        var message: JsonValue
        if content_type == "text/event-stream":
            message = self._parse_sse(body, expected_id)
        else:
            if body == "":
                raise Error("Empty MCP HTTP response")
            message = parse_json(body)
        return message^

    def _parse_sse(self, body: String, expected_id: Int) raises -> JsonValue:
        for event in body.split("\n\n"):
            var data = String("")
            for line in event.split("\n"):
                if line.startswith("data:"):
                    var value = String(line.removeprefix("data:"))
                    if value.startswith(" "):
                        var trimmed = String(value.removeprefix(" "))
                        value = trimmed^
                    data += value
            if data != "":
                var message = parse_json(data)
                if (
                    message.contains("id")
                    and message.get("id").int_value == expected_id
                ):
                    return message^
        raise Error("MCP SSE response did not contain the requested id")


struct McpClient(Copyable, Movable):
    """High-level MCP operations with stdio and HTTP transport overloads."""

    var name: String
    var session: McpSession

    def __init__(out self, name: String):
        self.name = name
        self.session = McpSession()

    def _accept(
        mut self, request: JsonValue, var response: JsonValue
    ) raises -> JsonValue:
        return self.session.accept_response(
            response^, request.get("id").int_value
        )

    def initialize(
        mut self, mut transport: StdioTransport
    ) raises -> JsonValue:
        var request = self.session.initialize_request(self.name)
        var response = transport.send(request)
        var result = self.session.accept_initialize(
            response^, request.get("id").int_value
        )
        transport.notify(self.session.initialized_notification())
        return result^

    def initialize(
        mut self, mut transport: StreamableHttpTransport
    ) raises -> JsonValue:
        var request = self.session.initialize_request(self.name)
        var response = transport.send(request)
        var result = self.session.accept_initialize(
            response^, request.get("id").int_value
        )
        transport.notify(self.session.initialized_notification())
        return result^

    def list_tools(
        mut self, mut transport: StdioTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.tools_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "tools")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def list_tools(
        mut self, mut transport: StreamableHttpTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.tools_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "tools")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def call_tool(
        mut self,
        mut transport: StdioTransport,
        name: String,
        var arguments: JsonValue,
    ) raises -> JsonValue:
        var request = self.session.tools_call_request(name, arguments^)
        return self._accept(request, transport.send(request))

    def call_tool(
        mut self,
        mut transport: StreamableHttpTransport,
        name: String,
        var arguments: JsonValue,
    ) raises -> JsonValue:
        var request = self.session.tools_call_request(name, arguments^)
        return self._accept(request, transport.send(request))

    def list_prompts(
        mut self, mut transport: StdioTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.prompts_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "prompts")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def list_prompts(
        mut self, mut transport: StreamableHttpTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.prompts_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "prompts")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def get_prompt(
        mut self,
        mut transport: StdioTransport,
        name: String,
        var arguments: Optional[JsonValue] = None,
    ) raises -> JsonValue:
        var request = self.session.prompts_get_request(name, arguments^)
        return self._accept(request, transport.send(request))

    def get_prompt(
        mut self,
        mut transport: StreamableHttpTransport,
        name: String,
        var arguments: Optional[JsonValue] = None,
    ) raises -> JsonValue:
        var request = self.session.prompts_get_request(name, arguments^)
        return self._accept(request, transport.send(request))

    def list_resources(
        mut self, mut transport: StdioTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.resources_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "resources")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def list_resources(
        mut self, mut transport: StreamableHttpTransport
    ) raises -> List[JsonValue]:
        var values = List[JsonValue]()
        var cursor = String("")
        while True:
            var request = self.session.resources_list_request(cursor)
            var page = self._accept(request, transport.send(request))
            _append_page(values, page, "resources")
            cursor = _next_cursor(page)
            if cursor == "":
                return values^

    def read_resource(
        mut self, mut transport: StdioTransport, uri: String
    ) raises -> JsonValue:
        var request = self.session.resources_read_request(uri)
        return self._accept(request, transport.send(request))

    def read_resource(
        mut self, mut transport: StreamableHttpTransport, uri: String
    ) raises -> JsonValue:
        var request = self.session.resources_read_request(uri)
        return self._accept(request, transport.send(request))


def _append_page(mut values: List[JsonValue], page: JsonValue, field: String) raises:
    if page.kind != JsonValue.OBJECT or not page.contains(field):
        raise Error("Invalid MCP pagination result")
    var items = page.get(field)
    if items.kind != JsonValue.ARRAY:
        raise Error("MCP page field is not an array")
    for i in range(len(items.array_value)):
        values.append(items.array_value[i].copy())


def _next_cursor(page: JsonValue) raises -> String:
    if page.contains("nextCursor"):
        return page.get("nextCursor").string_value
    return ""
