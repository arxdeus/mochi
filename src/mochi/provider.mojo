"""Provider-neutral state and an OpenAI-compatible provider implementation."""

from std.ffi import c_int, c_long, external_call
from std.os import getenv, makedirs, remove
from std.time import sleep

from mochi.domain import (
    ContentBlock,
    DomainMessage,
    DomainProviderEvent,
    MochiError,
    Model,
    ModelInfo,
    StopReason,
    StreamResponse,
    TokenUsage,
)
from mochi.http import FlokiTransport, HttpHeader, HttpRequest, HttpResponse, HttpTransport
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.provider_contract import (
    Provider,
    ProviderEventSink,
    ProviderRequest,
    provider_error_text,
)
from mochi.types import CancellationToken, Message, ProviderEvent, ToolCall, Usage


comptime OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
comptime OPENAI_DEVICE_CODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
comptime OPENAI_DEVICE_TOKEN_URL = "https://auth.openai.com/api/accounts/deviceauth/token"
comptime OPENAI_OAUTH_TOKEN_URL = "https://auth.openai.com/oauth/token"
comptime OPENAI_DEVICE_AUTH_URL = "https://auth.openai.com/codex/device"
comptime OPENAI_REDIRECT_URI = "https://auth.openai.com/deviceauth/callback"
comptime OPENAI_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses"


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
    var responses_api: Bool
    var account_id: String

    def __init__(out self, name: String, base_url: String):
        self.name = name
        self.base_url = base_url
        self.api_keys = List[String]()
        self.headers = List[HttpHeader]()
        self.auth_header = "Authorization"
        self.auth_prefix = "Bearer "
        self.max_retries = 3
        self.timeout_ms = 120000
        self.responses_api = False
        self.account_id = ""

    def add_api_key(mut self, key: String):
        self.api_keys.append(key)

    def add_header(mut self, name: String, value: String):
        self.headers.append(HttpHeader(name, value))

    def chat_url(self) -> String:
        if self.responses_api:
            return OPENAI_RESPONSES_URL
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


@fieldwise_init
struct OpenAIOAuthCredentials(Copyable, Movable):
    var access_token: String
    var refresh_token: String
    var expires_at_ms: Int
    var account_id: String

    def expired(self, now_ms: Int, margin_ms: Int = 30000) -> Bool:
        return self.expires_at_ms > 0 and now_ms + margin_ms >= self.expires_at_ms

    def oauth_state(self) -> OAuthState:
        var state = OAuthState()
        state.access_token = self.access_token
        state.refresh_token = self.refresh_token
        state.expires_at_ms = self.expires_at_ms
        state.token_url = OPENAI_OAUTH_TOKEN_URL
        state.client_id = OPENAI_CLIENT_ID
        return state^


def openai_oauth_credentials_path() raises -> String:
    var root = getenv("XDG_CONFIG_HOME", "")
    if root == "":
        root = getenv("HOME", "")
        if root == "":
            raise Error("HOME and XDG_CONFIG_HOME are unset")
        root += "/.config"
    return root + "/mochi/openai_oauth.json"


def load_openai_oauth_credentials(path: String = "") raises -> OpenAIOAuthCredentials:
    var resolved = path
    if resolved == "":
        resolved = openai_oauth_credentials_path()
    var root = parse_json(open(resolved, "r").read())
    var credentials = OpenAIOAuthCredentials(
        _string_or(root, "access_token", ""),
        _string_or(root, "refresh_token", ""),
        _int_or(root, "expires_at_ms", 0),
        _string_or(root, "account_id", ""),
    )
    if credentials.access_token == "":
        raise Error("cached OpenAI OAuth credentials have no access token")
    if credentials.account_id == "":
        credentials.account_id = extract_chatgpt_account_id(credentials.access_token)
    return credentials^


def save_openai_oauth_credentials(credentials: OpenAIOAuthCredentials, path: String = "") raises:
    var resolved = path
    if resolved == "":
        resolved = openai_oauth_credentials_path()
    var separator = _last_byte(resolved, UInt8(47))
    if separator > 0:
        makedirs(_byte_prefix(resolved, separator), exist_ok=True)
    var root = JsonValue.object()
    root.set("access_token", JsonValue.string(credentials.access_token))
    root.set("refresh_token", JsonValue.string(credentials.refresh_token))
    root.set("expires_at_ms", JsonValue.integer(credentials.expires_at_ms))
    root.set("account_id", JsonValue.string(credentials.account_id))
    var temporary = resolved + ".tmp"
    try:
        with open(temporary, "w") as file:
            file.write(serialize_json(root))
        var status = external_call["chmod", c_int](
            temporary.as_c_string_slice(), UInt32(0o600)
        )
        if status != 0:
            raise Error("unable to protect OpenAI OAuth credentials")
        status = external_call["rename", c_int](
            temporary.as_c_string_slice(), resolved.as_c_string_slice()
        )
        if status != 0:
            raise Error("unable to save OpenAI OAuth credentials")
    except error:
        try:
            remove(temporary)
        except:
            pass
        raise error


def extract_chatgpt_account_id(token: String) -> String:
    var parts = token.split(".")
    if len(parts) != 3:
        return ""
    try:
        var claims = parse_json(base64url_decode(String(parts[1])))
        var direct = _string_or(claims, "chatgpt_account_id", "")
        if direct != "":
            return direct^
        if claims.contains("https://api.openai.com/auth"):
            var auth = claims.get("https://api.openai.com/auth")
            var namespaced = _string_or(auth, "chatgpt_account_id", "")
            if namespaced != "":
                return namespaced^
        if claims.contains("organizations"):
            var organizations = claims.get("organizations")
            if organizations.kind == JsonValue.ARRAY and len(organizations.array_value) > 0:
                return _string_or(organizations.array_value[0], "id", "")
    except:
        pass
    return ""


def base64url_decode(value: String) raises -> String:
    var output = String("")
    var accumulator = 0
    var bits = 0
    for i in range(value.byte_length()):
        var byte = Int(UInt8(ord(value[byte=i])))
        if byte == 61:
            break
        var digit = _base64_digit(byte)
        if digit < 0:
            raise Error("invalid base64url payload")
        accumulator = (accumulator << 6) | digit
        bits += 6
        if bits >= 8:
            bits -= 8
            output += chr((accumulator >> bits) & 255)
    return output^


def refresh_openai_oauth_with[T: HttpTransport](
    mut transport: T, credentials: OpenAIOAuthCredentials, now_ms: Int
) raises -> OpenAIOAuthCredentials:
    var state = credentials.oauth_state()
    var response = transport.perform(state.refresh_request())
    if response.status < 200 or response.status >= 300:
        raise Error("OpenAI OAuth refresh HTTP " + String(response.status))
    var value = parse_json(response.body)
    var access = _string_or(value, "access_token", "")
    if access == "":
        raise Error("OpenAI OAuth refresh has no access_token")
    var refresh = _string_or(value, "refresh_token", credentials.refresh_token)
    var account = extract_chatgpt_account_id(_string_or(value, "id_token", access))
    if account == "":
        account = extract_chatgpt_account_id(access)
    if account == "":
        account = credentials.account_id
    return OpenAIOAuthCredentials(
        access,
        refresh,
        now_ms + _int_or(value, "expires_in", 3600) * 1000,
        account,
    )


def openai_device_login_with[T: HttpTransport](
    mut transport: T, now_ms: Int, path: String = "", poll_delay: Bool = True
) raises -> OpenAIOAuthCredentials:
    var code_request = HttpRequest("POST", OPENAI_DEVICE_CODE_URL)
    code_request.add_header("Content-Type", "application/json")
    code_request.body = '{"client_id":"' + OPENAI_CLIENT_ID + '"}'
    var code_response = transport.perform(code_request)
    if code_response.status != 200:
        raise Error("OpenAI device code HTTP " + String(code_response.status))
    var device = parse_json(code_response.body)
    var device_id = _string_or(device, "device_auth_id", "")
    var user_code = _string_or(device, "user_code", "")
    if device_id == "" or user_code == "":
        raise Error("OpenAI device code response is incomplete")
    var interval = max(_int_string_or(device, "interval", 5), 1)
    var max_polls = max(1, 300 // (interval + 3))
    print("Open this URL in your browser:\n\n ", OPENAI_DEVICE_AUTH_URL)
    print("Enter code:", user_code)
    print("Waiting for authorization...")
    var token_response = HttpResponse()
    var polls = 0
    while polls < max_polls:
        polls += 1
        if poll_delay:
            sleep(Float64(interval + 3))
        var poll = HttpRequest("POST", OPENAI_DEVICE_TOKEN_URL)
        poll.add_header("Content-Type", "application/json")
        poll.body = (
            '{"device_auth_id":"' + device_id + '","user_code":"' + user_code + '"}'
        )
        token_response = transport.perform(poll)
        if token_response.status == 200:
            break
        if token_response.status != 403 and token_response.status != 404:
            raise Error("OpenAI device token HTTP " + String(token_response.status))
    if token_response.status != 200:
        raise Error("OpenAI device authorization timed out")
    var device_token = parse_json(token_response.body)
    var authorization_code = _string_or(device_token, "authorization_code", "")
    var code_verifier = _string_or(device_token, "code_verifier", "")
    if authorization_code == "" or code_verifier == "":
        raise Error("OpenAI device authorization response is incomplete")
    var exchange = HttpRequest("POST", OPENAI_OAUTH_TOKEN_URL)
    exchange.add_header("Content-Type", "application/x-www-form-urlencoded")
    exchange.body = (
        "grant_type=authorization_code&code="
        + form_encode(authorization_code)
        + "&redirect_uri=" + form_encode(OPENAI_REDIRECT_URI)
        + "&client_id=" + form_encode(OPENAI_CLIENT_ID)
        + "&code_verifier=" + form_encode(code_verifier)
    )
    var response = transport.perform(exchange)
    if response.status != 200:
        raise Error("OpenAI token exchange HTTP " + String(response.status))
    var value = parse_json(response.body)
    var access = _string_or(value, "access_token", "")
    var refresh = _string_or(value, "refresh_token", "")
    if access == "" or refresh == "":
        raise Error("OpenAI token exchange returned incomplete credentials")
    var account = extract_chatgpt_account_id(_string_or(value, "id_token", access))
    if account == "":
        account = extract_chatgpt_account_id(access)
    var credentials = OpenAIOAuthCredentials(
        access, refresh, now_ms + _int_or(value, "expires_in", 3600) * 1000, account
    )
    save_openai_oauth_credentials(credentials, path)
    return credentials^


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
            var event_type = _string_or(root, "type", "")
            if event_type == "response.output_text.delta":
                var content = _string_or(root, "delta", "")
                if content != "":
                    events.append(ProviderEvent.text_delta(content))
                continue
            if event_type == "response.output_item.added":
                var item = root.get("item")
                if _string_or(item, "type", "") == "function_call":
                    var part = ToolCallDelta(
                        _int_or(root, "output_index", len(self.tools.calls)),
                        _string_or(item, "call_id", ""),
                        _string_or(item, "name", ""),
                        "",
                    )
                    self.tools.add(part)
                continue
            if event_type == "response.function_call_arguments.delta":
                var index = _int_or(root, "output_index", len(self.tools.calls) - 1)
                if index >= 0:
                    var arguments = String("")
                    if root.contains("delta"):
                        var delta = root.get("delta")
                        if delta.kind == JsonValue.STRING:
                            arguments = delta.string_value
                        elif delta.kind == JsonValue.OBJECT:
                            arguments = serialize_json(delta)
                    self.tools.add(ToolCallDelta(index, "", "", arguments^))
                continue
            if event_type == "response.output_item.done":
                var item = root.get("item")
                if _string_or(item, "type", "") == "function_call":
                    var index = _int_or(root, "output_index", len(self.tools.calls) - 1)
                    if index >= 0:
                        while len(self.tools.calls) <= index:
                            self.tools.calls.append(ToolCall("", "", ""))
                        var arguments = _string_or(item, "arguments", "")
                        if arguments == "" and item.contains("arguments"):
                            var raw_arguments = item.get("arguments")
                            if raw_arguments.kind == JsonValue.OBJECT:
                                arguments = serialize_json(raw_arguments)
                        var call_id = _string_or(item, "call_id", "")
                        var name = _string_or(item, "name", "")
                        if call_id != "":
                            self.tools.calls[index].id = call_id
                        if name != "":
                            self.tools.calls[index].name = name
                        if arguments != "":
                            self.tools.calls[index].arguments = arguments^
                continue
            if event_type == "response.completed" or event_type == "response.incomplete":
                var response = root.get("response")
                if response.contains("usage"):
                    var response_usage = response.get("usage")
                    self.usage = Usage(
                        _int_or(response_usage, "input_tokens", 0),
                        _int_or(response_usage, "output_tokens", 0),
                    )
                    events.append(ProviderEvent.usage_event(self.usage))
                self.stop_reason = "stop"
                if event_type == "response.incomplete":
                    self.stop_reason = "length"
                elif len(self.tools.calls) > 0:
                    self.stop_reason = "tool_calls"
                events.append(ProviderEvent.done(self.stop_reason))
                continue
            if event_type == "error" or event_type == "response.failed":
                var message = String("response generation failed")
                if root.contains("response"):
                    var failed = root.get("response")
                    if failed.contains("error"):
                        message = _string_or(failed.get("error"), "message", message)
                elif root.contains("message"):
                    message = _string_or(root, "message", message)
                raise Error("OpenAI Responses stream error: " + message)
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
    var fixture_error: String

    def __init__(out self, var spec: ProviderSpec):
        self.keys = ApiKeyState(spec.api_keys.copy())
        self.spec = spec^
        self.oauth = OAuthState()
        self.has_oauth = False
        self.last_usage = Usage()
        self.last_status = 0
        self.fixture_error = ""

    def set_oauth(mut self, oauth: OAuthState):
        self.oauth = oauth.copy()
        self.has_oauth = True

    def fail_with(mut self, error: String):
        self.fixture_error = error

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
        if self.spec.responses_api:
            request.add_header("chatgpt-account-id", self.spec.account_id)
            request.add_header("originator", "mochi")
            request.add_header("OpenAI-Beta", "responses=v1")
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
        if self.spec.responses_api:
            var account = extract_chatgpt_account_id(self.oauth.access_token)
            if account != "":
                self.spec.account_id = account^
            save_openai_oauth_credentials(
                OpenAIOAuthCredentials(
                    self.oauth.access_token,
                    self.oauth.refresh_token,
                    self.oauth.expires_at_ms,
                    self.spec.account_id,
                )
            )
        return True

    def complete_json(mut self, body: JsonValue) raises -> ProviderResult:
        if self.fixture_error != "":
            raise Error(self.fixture_error)
        var transport = FlokiTransport()
        return self.complete_json_with(transport, body)

    def complete_json_with[T: HttpTransport](
        mut self, mut transport: T, body: JsonValue
    ) raises -> ProviderResult:
        return self.complete_json_with_cancel(
            transport, body, CancellationToken()
        )

    def complete_json_with_cancel[T: HttpTransport](
        mut self,
        mut transport: T,
        body: JsonValue,
        cancel: CancellationToken,
    ) raises -> ProviderResult:
        self.last_status = 0
        var state = _ProviderStreamState()
        var response = transport.perform_stream_cancellable(
            self.build_request(body),
            _accept_provider_chunk,
            Pointer(to=state).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
            cancel.copy(),
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
        var refresh_time = now_ms
        if refresh_time == 0:
            refresh_time = _epoch_ms()
        var transport = FlokiTransport()
        return self.recover_auth_with(transport, refresh_time)

    def recover_auth_with[T: HttpTransport](
        mut self, mut transport: T, now_ms: Int = 0
    ) raises -> Bool:
        if self.has_oauth and self.oauth.can_refresh():
            return self.refresh_oauth_with(transport, now_ms)
        if not self.has_oauth:
            return self.rotate_key()
        return False


struct OpenAIProviderAdapter(Provider, Movable):
    var inner: OpenAICompatibleProvider
    var model_info: ModelInfo
    var last_error: Optional[MochiError]

    def __init__(out self, var inner: OpenAICompatibleProvider, model: ModelInfo):
        self.inner = inner^
        self.model_info = model.copy()
        self.last_error = None

    def list_models(mut self) raises -> List[ModelInfo]:
        return [self.model_info.copy()]

    def stream_message[S: ProviderEventSink](
        mut self, request: ProviderRequest, mut sink: S
    ) raises -> StreamResponse:
        self.last_error = None
        if request.cancel.is_cancelled():
            return self._fail(MochiError.cancelled())
        var messages = _legacy_messages(request.messages, request.system)
        var body: JsonValue
        if self.inner.spec.responses_api:
            body = _responses_body(request.model.id, messages, request.tools)
        else:
            body = _chat_body(request.model.id, messages, request.tools)
        var transport = FlokiTransport()
        var result: ProviderResult
        try:
            result = self.inner.complete_json_with_cancel(
                transport, body, request.cancel.copy()
            )
        except error:
            if request.cancel.is_cancelled():
                return self._fail(MochiError.cancelled())
            if self.inner.last_http_status() != 0:
                return self._fail(
                    MochiError.api(self.inner.last_http_status(), String(error))
                )
            return self._fail(MochiError.http(String(error)))
        if result.message.content != "":
            sink.emit(DomainProviderEvent.text_delta(result.message.content))
        for call in result.message.tool_calls:
            sink.emit(DomainProviderEvent.tool_use_start(call.id, call.name))
        return _stream_response(result)

    def _fail(mut self, error: MochiError) raises -> StreamResponse:
        self.last_error = Optional(error.copy())
        raise Error(provider_error_text(error))


struct OpenAIProviderAdapterWithTransport[
    T: HttpTransport & Movable & Deinitable
](Provider, Movable):
    var inner: OpenAICompatibleProvider
    var transport: Self.T
    var model_info: ModelInfo
    var last_error: Optional[MochiError]

    def __init__(
        out self,
        var inner: OpenAICompatibleProvider,
        var transport: Self.T,
        model: ModelInfo,
    ):
        self.inner = inner^
        self.transport = transport^
        self.model_info = model.copy()
        self.last_error = None

    def list_models(mut self) raises -> List[ModelInfo]:
        return [self.model_info.copy()]

    def stream_message[S: ProviderEventSink](
        mut self, request: ProviderRequest, mut sink: S
    ) raises -> StreamResponse:
        self.last_error = None
        if request.cancel.is_cancelled():
            return self._fail(MochiError.cancelled())
        var messages = _legacy_messages(request.messages, request.system)
        var body: JsonValue
        if self.inner.spec.responses_api:
            body = _responses_body(request.model.id, messages, request.tools)
        else:
            body = _chat_body(request.model.id, messages, request.tools)
        var result: ProviderResult
        try:
            result = self.inner.complete_json_with_cancel(
                self.transport, body, request.cancel.copy()
            )
        except error:
            if request.cancel.is_cancelled():
                return self._fail(MochiError.cancelled())
            if self.inner.last_http_status() != 0:
                return self._fail(
                    MochiError.api(self.inner.last_http_status(), String(error))
                )
            return self._fail(MochiError.http(String(error)))
        if result.message.content != "":
            sink.emit(DomainProviderEvent.text_delta(result.message.content))
        for call in result.message.tool_calls:
            sink.emit(DomainProviderEvent.tool_use_start(call.id, call.name))
        return _stream_response(result)

    def _fail(mut self, error: MochiError) raises -> StreamResponse:
        self.last_error = Optional(error.copy())
        raise Error(provider_error_text(error))


def _legacy_messages(
    messages: List[DomainMessage], system: String
) raises -> List[Message]:
    var result = List[Message]()
    if system != "":
        result.append(Message("system", system))
    for message in messages:
        var role = "assistant" if message.role.is_assistant() else "user"
        var legacy = Message(role, "")
        for block in message.content:
            if block.is_text():
                legacy.content += block.text
            elif block.is_tool_use():
                legacy.tool_calls.append(
                    ToolCall(block.id, block.name, block.input.serialize())
                )
            elif block.is_tool_result():
                if legacy.content != "" or len(legacy.tool_calls) > 0:
                    result.append(legacy.copy())
                legacy = Message("tool", block.text)
                legacy.tool_call_id = block.id
            elif block.is_image():
                raise Error("OpenAI compatibility adapter does not support image input")
        result.append(legacy^)
    return result^


def _chat_body(model: String, messages: List[Message], tools: JsonValue) raises -> JsonValue:
    var body = JsonValue.object()
    body.set("model", JsonValue.string(model))
    body.set("stream", JsonValue.boolean(True))
    var raw_messages = JsonValue.array()
    for message in messages:
        var value = JsonValue.object()
        value.set("role", JsonValue.string(message.role))
        value.set("content", JsonValue.string(message.content))
        if message.tool_call_id != "":
            value.set("tool_call_id", JsonValue.string(message.tool_call_id))
        if len(message.tool_calls) > 0:
            var calls = JsonValue.array()
            for call in message.tool_calls:
                var function = JsonValue.object()
                function.set("name", JsonValue.string(call.name))
                function.set("arguments", JsonValue.string(call.arguments))
                var item = JsonValue.object()
                item.set("id", JsonValue.string(call.id))
                item.set("type", JsonValue.string("function"))
                item.set("function", function^)
                calls.append(item^)
            value.set("tool_calls", calls^)
        raw_messages.append(value^)
    body.set("messages", raw_messages^)
    if tools.kind == JsonValue.ARRAY and len(tools.array_value) > 0:
        body.set("tools", tools.copy())
        body.set("tool_choice", JsonValue.string("auto"))
    return body^


def _responses_body(
    model: String, messages: List[Message], tools: JsonValue
) raises -> JsonValue:
    var body = JsonValue.object()
    body.set("model", JsonValue.string(model))
    body.set("stream", JsonValue.boolean(True))
    body.set("store", JsonValue.boolean(False))
    var input = JsonValue.array()
    for message in messages:
        if message.role == "tool":
            var output = JsonValue.object()
            output.set("type", JsonValue.string("function_call_output"))
            output.set("call_id", JsonValue.string(message.tool_call_id))
            output.set("output", JsonValue.string(message.content))
            input.append(output^)
            continue
        if message.content != "":
            var item = JsonValue.object()
            item.set("type", JsonValue.string("message"))
            item.set("role", JsonValue.string(message.role))
            var content = JsonValue.array()
            var part = JsonValue.object()
            part.set(
                "type",
                JsonValue.string(
                    "output_text" if message.role == "assistant" else "input_text"
                ),
            )
            part.set("text", JsonValue.string(message.content))
            content.append(part^)
            item.set("content", content^)
            input.append(item^)
        for call in message.tool_calls:
            var raw_call = JsonValue.object()
            raw_call.set("type", JsonValue.string("function_call"))
            raw_call.set("call_id", JsonValue.string(call.id))
            raw_call.set("name", JsonValue.string(call.name))
            raw_call.set("arguments", JsonValue.string(call.arguments))
            input.append(raw_call^)
    body.set("input", input^)
    if tools.kind == JsonValue.ARRAY and len(tools.array_value) > 0:
        body.set("tools", tools.copy())
    return body^


def _stream_response(result: ProviderResult) raises -> StreamResponse:
    var message = DomainMessage.assistant(result.message.content)
    for call in result.message.tool_calls:
        var input = JsonValue.object()
        if call.arguments != "":
            input = parse_json(call.arguments)
            if input.kind != JsonValue.OBJECT:
                raise Error("provider tool arguments must be an object")
        message.add_block(ContentBlock.tool_use(call.id, call.name, input^))
    var usage = TokenUsage(
        result.usage.input_tokens, result.usage.output_tokens, 0, 0
    )
    return StreamResponse(
        message^,
        usage^,
        Optional(StopReason.from_openai(result.stop_reason)),
    )


def _epoch_ms() -> Int:
    var seconds: c_long = 0
    _ = external_call["time", c_long](Pointer(to=seconds))
    return Int(seconds) * 1000


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


def _int_string_or(value: JsonValue, key: String, fallback: Int) -> Int:
    if not value.contains(key):
        return fallback
    try:
        var field = value.get(key)
        if field.kind == JsonValue.INT:
            return field.int_value
        if field.kind == JsonValue.STRING:
            var parsed = 0
            for cp in field.string_value.codepoints():
                var digit = Int(cp.to_u32()) - 48
                if digit < 0 or digit > 9:
                    return fallback
                parsed = parsed * 10 + digit
            return parsed
    except:
        pass
    return fallback


def _base64_digit(byte: Int) -> Int:
    if byte >= 65 and byte <= 90:
        return byte - 65
    if byte >= 97 and byte <= 122:
        return byte - 71
    if byte >= 48 and byte <= 57:
        return byte + 4
    if byte == 45 or byte == 43:
        return 62
    if byte == 95 or byte == 47:
        return 63
    return -1


def _last_byte(value: String, needle: UInt8) -> Int:
    var result = -1
    for i in range(value.byte_length()):
        if UInt8(ord(value[byte=i])) == needle:
            result = i
    return result


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
