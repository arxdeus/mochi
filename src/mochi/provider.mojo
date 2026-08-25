"""Provider-neutral state and an OpenAI-compatible provider implementation."""

from mochi.http import FlokiTransport, HttpHeader, HttpRequest, HttpResponse, HttpTransport
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.types import Message, ProviderEvent, ToolCall, Usage


@fieldwise_init
struct ProviderSpec(Copyable, Movable):
    var name: String
    var base_url: String
    var api_keys: List[String]
    var headers: List[HttpHeader]
    var auth_header: String
    var auth_prefix: String
    var max_retries: Int
    var timeout_ms: Int

    def __init__(out self, name: String, base_url: String):
        self.name = name
        self.base_url = base_url
        self.api_keys = List[String]()
        self.headers = List[HttpHeader]()
        self.auth_header = "Authorization"
        self.auth_prefix = "Bearer "
        self.max_retries = 3
        self.timeout_ms = 120000

    def add_api_key(mut self, key: String):
        self.api_keys.append(key)

    def add_header(mut self, name: String, value: String):
        self.headers.append(HttpHeader(name, value))

    def chat_url(self) -> String:
        if self.base_url.endswith("/"):
            return self.base_url + "chat/completions"
        return self.base_url + "/chat/completions"


struct ProviderRegistry(Copyable, Movable):
    var specs: List[ProviderSpec]

    def __init__(out self):
        self.specs = List[ProviderSpec]()

    def register(mut self, var spec: ProviderSpec) raises:
        if spec.name == "" or self.contains(spec.name):
            raise Error("provider already registered: " + spec.name)
        self.specs.append(spec^)

    def contains(self, name: String) -> Bool:
        for spec in self.specs:
            if spec.name == name:
                return True
        return False

    def get(self, name: String) raises -> ProviderSpec:
        for spec in self.specs:
            if spec.name == name:
                return spec.copy()
        raise Error("unknown provider: " + name)

    def names(self) -> List[String]:
        var result = List[String]()
        for spec in self.specs:
            result.append(spec.name)
        return result^


struct ApiKeyState(Copyable, Movable):
    var keys: List[String]
    var index: Int

    def __init__(out self, var keys: List[String]):
        self.keys = keys^
        self.index = 0

    def current(self) -> String:
        if len(self.keys) == 0:
            return ""
        return self.keys[self.index]

    def rotate(mut self) -> Bool:
        if len(self.keys) < 2:
            return False
        self.index = (self.index + 1) % len(self.keys)
        return True


struct RetryState(Copyable, Movable):
    var attempt: Int
    var max_retries: Int
    var base_delay_ms: Int
    var max_delay_ms: Int

    def __init__(out self, max_retries: Int = 3):
        self.attempt = 0
        self.max_retries = max_retries
        self.base_delay_ms = 500
        self.max_delay_ms = 30000

    def can_retry(self) -> Bool:
        return self.attempt < self.max_retries

    def next_delay_ms(mut self, retry_after_ms: Int = 0) -> Int:
        var delay: Int
        if retry_after_ms > 0:
            delay = min(retry_after_ms, 60000)
        else:
            delay = self.base_delay_ms
            for _ in range(self.attempt):
                delay = min(delay * 2, self.max_delay_ms)
            # Deterministic jitter keeps state tests and request scheduling reproducible.
            delay = min(
                delay + ((self.attempt * 73 + 41) % 250), self.max_delay_ms
            )
        self.attempt += 1
        return delay

    def reset(mut self):
        self.attempt = 0

    @staticmethod
    def retryable_status(status: Int) -> Bool:
        return (
            status == 408
            or status == 409
            or status == 425
            or status == 429
            or status == 500
            or status == 502
            or status == 503
            or status == 504
        )


struct OAuthState(Copyable, Movable):
    var access_token: String
    var refresh_token: String
    var expires_at_ms: Int
    var token_url: String
    var client_id: String
    var client_secret: String
    var scope: String

    def __init__(out self):
        self.access_token = ""
        self.refresh_token = ""
        self.expires_at_ms = 0
        self.token_url = ""
        self.client_id = ""
        self.client_secret = ""
        self.scope = ""

    def expired(self, now_ms: Int, margin_ms: Int = 30000) -> Bool:
        return (
            self.expires_at_ms > 0 and now_ms + margin_ms >= self.expires_at_ms
        )

    def can_refresh(self) -> Bool:
        return self.token_url != "" and self.refresh_token != ""

    def refresh_request(self) raises -> HttpRequest:
        if not self.can_refresh():
            raise Error("OAuth refresh is not configured")
        var request = HttpRequest("POST", self.token_url)
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        request.body = "grant_type=refresh_token&refresh_token=" + form_encode(
            self.refresh_token
        )
        if self.client_id != "":
            request.body += "&client_id=" + form_encode(self.client_id)
        if self.client_secret != "":
            request.body += "&client_secret=" + form_encode(self.client_secret)
        if self.scope != "":
            request.body += "&scope=" + form_encode(self.scope)
        return request^

    def apply_refresh_response(mut self, body: String, now_ms: Int) raises:
        var value = parse_json(body)
        self.access_token = _string_or(value, "access_token", "")
        if self.access_token == "":
            raise Error("OAuth response has no access_token")
        var refreshed = _string_or(value, "refresh_token", "")
        if refreshed != "":
            self.refresh_token = refreshed
        var expires_in = _int_or(value, "expires_in", 0)
        if expires_in > 0:
            self.expires_at_ms = now_ms + expires_in * 1000


struct SSEParser(Copyable, Movable):
    """Incremental SSE parser supporting arbitrary transport chunk boundaries.
    """

    var pending: String
    var data_lines: List[String]

    def __init__(out self):
        self.pending = ""
        self.data_lines = List[String]()

    def feed(mut self, chunk: String) -> List[String]:
        self.pending += chunk
        var output = List[String]()
        while True:
            var newline = _find_byte(self.pending, UInt8(10))
            if newline < 0:
                break
            var line = _byte_prefix(self.pending, newline)
            self.pending = _byte_suffix(self.pending, newline + 1)
            if line.endswith("\r"):
                line = _byte_prefix(line, line.byte_length() - 1)
            self._accept_line(line^, output)
        return output^

    def finish(mut self) -> List[String]:
        var output = List[String]()
        if self.pending != "":
            var line = self.pending^
            self.pending = ""
            if line.endswith("\r"):
                line = _byte_prefix(line, line.byte_length() - 1)
            self._accept_line(line^, output)
        self._dispatch(output)
        return output^

    def _accept_line(mut self, var line: String, mut output: List[String]):
        if line == "":
            self._dispatch(output)
        elif line.startswith("data:"):
            var value = _byte_suffix(line, 5)
            if value.startswith(" "):
                value = _byte_suffix(value, 1)
            self.data_lines.append(value^)

    def _dispatch(mut self, mut output: List[String]):
        if len(self.data_lines) == 0:
            return
        var data = String("")
        for i in range(len(self.data_lines)):
            if i > 0:
                data += "\n"
            data += self.data_lines[i]
        output.append(data^)
        self.data_lines.clear()


@fieldwise_init
struct ToolCallDelta(Copyable, Movable):
    var index: Int
    var id: String
    var name: String
    var arguments: String


struct ToolCallAssembler(Copyable, Movable):
    var calls: List[ToolCall]

    def __init__(out self):
        self.calls = List[ToolCall]()

    def add(mut self, delta: ToolCallDelta):
        while len(self.calls) <= delta.index:
            self.calls.append(ToolCall("", "", ""))
        self.calls[delta.index].id += delta.id
        self.calls[delta.index].name += delta.name
        self.calls[delta.index].arguments += delta.arguments

    def completed(self) -> List[ToolCall]:
        return self.calls.copy()


struct OpenAIStreamParser(Copyable, Movable):
    var sse: SSEParser
    var tools: ToolCallAssembler
    var usage: Usage
    var stop_reason: String

    def __init__(out self):
        self.sse = SSEParser()
        self.tools = ToolCallAssembler()
        self.usage = Usage()
        self.stop_reason = ""

    def feed(mut self, chunk: String) raises -> List[ProviderEvent]:
        return self._parse_payloads(self.sse.feed(chunk))

    def finish(mut self) raises -> List[ProviderEvent]:
        return self._parse_payloads(self.sse.finish())

    def _parse_payloads(
        mut self, payloads: List[String]
    ) raises -> List[ProviderEvent]:
        var events = List[ProviderEvent]()
        for payload in payloads:
            if payload == "[DONE]":
                if self.stop_reason == "":
                    self.stop_reason = "stop"
                events.append(ProviderEvent.done(self.stop_reason))
                continue
            var root = parse_json(payload)
            if root.contains("usage") and not root.get("usage").is_null():
                var raw_usage = root.get("usage")
                self.usage = Usage(
                    _int_or(
                        raw_usage,
                        "prompt_tokens",
                        _int_or(raw_usage, "input_tokens", 0),
                    ),
                    _int_or(
                        raw_usage,
                        "completion_tokens",
                        _int_or(raw_usage, "output_tokens", 0),
                    ),
                )
                events.append(ProviderEvent.usage_event(self.usage))
            if not root.contains("choices"):
                continue
            var choices = root.get("choices")
            if choices.kind != JsonValue.ARRAY:
                raise Error("OpenAI choices is not an array")
            for choice in choices.array_value:
                if choice.contains("delta"):
                    var delta = choice.get("delta")
                    var content = _string_or(delta, "content", "")
                    if content != "":
                        events.append(ProviderEvent.text_delta(content))
                    if delta.contains("tool_calls"):
                        var raw_calls = delta.get("tool_calls")
                        for raw_call in raw_calls.array_value:
                            var function = JsonValue.object()
                            if raw_call.contains("function"):
                                function = raw_call.get("function")
                            var part = ToolCallDelta(
                                _int_or(raw_call, "index", 0),
                                _string_or(raw_call, "id", ""),
                                _string_or(function, "name", ""),
                                _string_or(function, "arguments", ""),
                            )
                            self.tools.add(part)
                            events.append(
                                ProviderEvent.tool_call_delta(
                                    ToolCall(part.id, part.name, part.arguments)
                                )
                            )
                var reason = _string_or(choice, "finish_reason", "")
                if reason != "":
                    self.stop_reason = reason
                    events.append(ProviderEvent.done(reason))
        return events^


struct ProviderResult(Copyable, Movable):
    var message: Message
    var usage: Usage
    var stop_reason: String

    def __init__(out self):
        self.message = Message("assistant", "")
        self.usage = Usage()
        self.stop_reason = "stop"


struct _ProviderStreamState(Movable):
    var parser: OpenAIStreamParser
    var result: ProviderResult
    var error: String

    def __init__(out self):
        self.parser = OpenAIStreamParser()
        self.result = ProviderResult()
        self.error = ""

    def accept(mut self, chunk: String) raises:
        var events = self.parser.feed(chunk)
        self._accept_events(events)

    def finish(mut self) raises:
        var events = self.parser.finish()
        self._accept_events(events)
        for call in self.parser.tools.completed():
            self.result.message.add_tool_call(call.copy())

    def _accept_events(mut self, events: List[ProviderEvent]):
        for event in events:
            if event.kind == "text_delta":
                self.result.message.content += event.text
            elif event.kind == "usage":
                self.result.usage = event.usage.copy()
            elif event.kind == "done":
                self.result.stop_reason = event.stop_reason


def _accept_provider_chunk(
    chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]
):
    var state = userdata.unsafe_bitcast[_ProviderStreamState]()
    try:
        state[].accept(chunk)
    except error:
        state[].error = String(error)


struct OpenAICompatibleProvider:
    var spec: ProviderSpec
    var keys: ApiKeyState
    var oauth: OAuthState
    var has_oauth: Bool
    var last_usage: Usage
    var last_status: Int

    def __init__(out self, var spec: ProviderSpec):
        self.keys = ApiKeyState(spec.api_keys.copy())
        self.spec = spec^
        self.oauth = OAuthState()
        self.has_oauth = False
        self.last_usage = Usage()
        self.last_status = 0

    def set_oauth(mut self, oauth: OAuthState):
        self.oauth = oauth.copy()
        self.has_oauth = True

    def rotate_key(mut self) -> Bool:
        return self.keys.rotate()

    def auth_token(self) -> String:
        if self.has_oauth:
            return self.oauth.access_token
        return self.keys.current()

    def build_request(self, body: JsonValue) -> HttpRequest:
        var request = HttpRequest("POST", self.spec.chat_url())
        request.timeout_ms = self.spec.timeout_ms
        request.body = serialize_json(body)
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "text/event-stream")
        for header in self.spec.headers:
            request.add_header(header.name, header.value)
        var token = self.auth_token()
        if token != "":
            request.add_header(
                self.spec.auth_header, self.spec.auth_prefix + token
            )
        return request^

    def refresh_oauth(mut self, now_ms: Int) raises -> Bool:
        var transport = FlokiTransport()
        return self.refresh_oauth_with(transport, now_ms)

    def refresh_oauth_with[T: HttpTransport](
        mut self, mut transport: T, now_ms: Int
    ) raises -> Bool:
        if not self.has_oauth or not self.oauth.can_refresh():
            return False
        var response = transport.perform(self.oauth.refresh_request())
        if response.status < 200 or response.status >= 300:
            raise Error("OAuth refresh HTTP " + String(response.status))
        self.oauth.apply_refresh_response(response.body, now_ms)
        return True

    def complete_json(mut self, body: JsonValue) raises -> ProviderResult:
        var transport = FlokiTransport()
        return self.complete_json_with(transport, body)

    def complete_json_with[T: HttpTransport](
        mut self, mut transport: T, body: JsonValue
    ) raises -> ProviderResult:
        self.last_status = 0
        var state = _ProviderStreamState()
        var response = transport.perform_stream(
            self.build_request(body),
            _accept_provider_chunk,
            Pointer(to=state).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
        )
        self.last_status = response.status
        if state.error != "":
            raise Error("provider stream parse failed: " + state.error)
        if response.status < 200 or response.status >= 300:
            raise Error(
                "provider HTTP "
                + String(response.status)
                + ": "
                + response.body
            )
        state.finish()
        self.last_usage = state.result.usage.copy()
        return state.result.copy()

    def parse_response_body(mut self, body: String) raises -> ProviderResult:
        """Parse one scripted OpenAI-compatible SSE response body."""
        var chunks: List[String] = [body]
        return self.parse_response_chunks(chunks)

    def parse_response_chunks(
        mut self, chunks: List[String]
    ) raises -> ProviderResult:
        """Feed transport chunks incrementally into the OpenAI SSE parser."""
        var parser = OpenAIStreamParser()
        var events = List[ProviderEvent]()
        for chunk in chunks:
            var parsed = parser.feed(chunk)
            for event in parsed:
                events.append(event.copy())
        var tail = parser.finish()
        for event in tail:
            events.append(event.copy())
        var result = ProviderResult()
        for event in events:
            if event.kind == "text_delta":
                result.message.content += event.text
            elif event.kind == "usage":
                result.usage = event.usage.copy()
            elif event.kind == "done":
                result.stop_reason = event.stop_reason
        for call in parser.tools.completed():
            result.message.add_tool_call(call.copy())
        self.last_usage = result.usage.copy()
        return result^

    def fetch_usage(self) -> Usage:
        return self.last_usage.copy()

    def last_http_status(self) -> Int:
        return self.last_status

    def max_retries(self) -> Int:
        return self.spec.max_retries

    def recover_auth(mut self, now_ms: Int = 0) raises -> Bool:
        """Refresh OAuth when configured, otherwise rotate an API key."""
        var transport = FlokiTransport()
        return self.recover_auth_with(transport, now_ms)

    def recover_auth_with[T: HttpTransport](
        mut self, mut transport: T, now_ms: Int = 0
    ) raises -> Bool:
        if self.has_oauth and self.oauth.can_refresh():
            return self.refresh_oauth_with(transport, now_ms)
        if not self.has_oauth:
            return self.rotate_key()
        return False


def form_encode(value: String) -> String:
    comptime hex = "0123456789ABCDEF"
    var output = String("")
    for cp in value.codepoints():
        var byte = Int(cp.to_u32())
        if (
            (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or (byte >= 48 and byte <= 57)
            or byte == 45
            or byte == 46
            or byte == 95
            or byte == 126
        ):
            output += String(cp)
        elif byte == 32:
            output += "+"
        elif byte <= 255:
            output += "%"
            output += String(hex[byte=(byte >> 4) & 15])
            output += String(hex[byte=byte & 15])
    return output^


def _string_or(value: JsonValue, key: String, fallback: String) -> String:
    if not value.contains(key):
        return fallback
    try:
        var field = value.get(key)
        if field.kind == JsonValue.STRING:
            return field.string_value
    except:
        pass
    return fallback


def _int_or(value: JsonValue, key: String, fallback: Int) -> Int:
    if not value.contains(key):
        return fallback
    try:
        var field = value.get(key)
        if field.kind == JsonValue.INT:
            return field.int_value
    except:
        pass
    return fallback


def _find_byte(value: String, needle: UInt8) -> Int:
    for i in range(value.byte_length()):
        if UInt8(ord(value[byte=i])) == needle:
            return i
    return -1


def _byte_prefix(value: String, count: Int) -> String:
    var output = String("")
    for i in range(count):
        output += String(value[byte=i])
    return output^


def _byte_suffix(value: String, start: Int) -> String:
    var output = String("")
    for i in range(start, value.byte_length()):
        output += String(value[byte=i])
    return output^
