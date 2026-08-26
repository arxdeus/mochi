from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mochi.domain import (
    DomainMessage,
    DomainProviderEvent,
    Model,
    ModelFamily,
    ModelInfo,
    ModelPricing,
    ModelTier,
    ThinkingSupport,
)
from mochi.http import HttpRequest, HttpResponse, MockTransport
from mochi.json import JsonValue, parse_json
from mochi.provider_contract import ProviderEventSink, ProviderRequest
from mochi.types import CancellationToken, ProviderEvent
from mochi.provider import (
    AnthropicProviderAdapterWithTransport,
    AnthropicProviderSpec,
    AnthropicStreamParser,
    GeminiProviderAdapterWithTransport,
    GeminiProviderSpec,
    GeminiStreamParser,
    ApiKeyState,
    OAuthState,
    OpenAICompatibleProvider,
    OpenAIProviderAdapterWithTransport,
    OpenAIOAuthCredentials,
    OpenAIStreamParser,
    ProviderRegistry,
    ProviderSpec,
    RetryState,
    SSEParser,
    ToolCallAssembler,
    ToolCallDelta,
    builtin_model_catalog,
    copilot_discovered_endpoint,
    copilot_discovery_request,
    copilot_graphql_url,
    copilot_guess_endpoint,
    copilot_model_endpoint,
    copilot_models_request,
    copilot_parse_models,
    copilot_provider_spec,
    find_model_info,
    builtin_provider_registry,
    extract_chatgpt_account_id,
    form_encode,
    openai_device_login_with,
    refresh_openai_oauth_with,
)


def test_provider_registry_and_spec() raises:
    var registry = ProviderRegistry()
    var spec = ProviderSpec("custom", "https://example.invalid/v1")
    spec.add_api_key("key-a")
    registry.register(spec.copy())
    assert_true(registry.contains("custom"))
    assert_equal(
        registry.get("custom").chat_url(),
        "https://example.invalid/v1/chat/completions",
    )
    assert_equal(len(registry.names()), 1)
    with assert_raises():
        registry.register(ProviderSpec("custom", "https://other.invalid"))
    with assert_raises():
        _ = registry.get("missing")


def test_builtin_provider_and_model_catalog() raises:
    var registry = builtin_provider_registry()
    assert_true(registry.contains("openai"))
    assert_true(registry.contains("copilot"))
    assert_true(registry.contains("openrouter"))
    assert_true(registry.contains("deepseek"))
    assert_true(registry.contains("ollama"))
    assert_equal(
        registry.get("openrouter").chat_url(),
        "https://openrouter.ai/api/v1/chat/completions",
    )
    var models = builtin_model_catalog()
    assert_true(len(models) >= 12)
    assert_equal(models[0].id, "gpt-5.6-sol")
    assert_equal(models[0].context_window.value(), 372000)
    assert_equal(models[0].max_output_tokens.value(), 128000)
    assert_equal(models[0].pricing.value().input, 5.0)
    assert_equal(models[0].pricing.value().output, 30.0)
    assert_equal(models[0].pricing.value().cache_write, 6.25)
    assert_equal(models[0].pricing.value().cache_read, 0.5)
    assert_true(models[0].supports_thinking.value())
    assert_true(models[0].supports_vision.value())
    assert_equal(find_model_info("gemini-2.5-pro").context_window.value(), 1048576)
    assert_equal(find_model_info("custom-model").id, "custom-model")


def test_copilot_auth_discovery_and_headers() raises:
    assert_equal(copilot_graphql_url(), "https://api.github.com/graphql")
    assert_equal(
        copilot_graphql_url("github.example.test"),
        "https://github.example.test/api/graphql",
    )
    var discovery = copilot_discovery_request("secret")
    assert_equal(discovery.method, "POST")
    assert_true("copilotEndpoints" in discovery.body)
    assert_equal(discovery.headers[0].value, "Bearer secret")
    assert_equal(
        copilot_discovered_endpoint(
            HttpResponse(
                200,
                '{"data":{"viewer":{"copilotEndpoints":{"api":"https://copilot.example.test"}}}}',
            )
        ),
        "https://copilot.example.test",
    )
    assert_equal(
        copilot_discovered_endpoint(HttpResponse(500, "failed")),
        "https://api.githubcopilot.com",
    )
    assert_equal(
        copilot_discovered_endpoint(HttpResponse(200, "{}")),
        "https://api.githubcopilot.com",
    )
    var provider = OpenAICompatibleProvider(
        copilot_provider_spec("https://api.githubcopilot.com", "secret")
    )
    var request = provider.build_request(JsonValue.object())
    assert_equal(request.url, "https://api.githubcopilot.com/chat/completions")
    assert_equal(request.headers[len(request.headers) - 1].value, "Bearer secret")
    var names = String("")
    for header in request.headers:
        names += header.name + "\n"
    assert_true("Editor-Version" in names)
    assert_true("X-GitHub-Api-Version" in names)
    assert_true("X-Initiator" in names)
    assert_true("X-Interaction-Type" in names)
    assert_true("OpenAI-Intent" in names)


def test_copilot_model_discovery_and_routing() raises:
    var request = copilot_models_request("https://copilot.example.test/", "secret")
    assert_equal(request.method, "GET")
    assert_equal(request.url, "https://copilot.example.test/models")
    var models = copilot_parse_models(
        '{"data":['
        + '{"id":"disabled","model_picker_enabled":false,"capabilities":{"type":"chat"}},'
        + '{"id":"other","model_picker_enabled":true,"capabilities":{"type":"embeddings"}},'
        + '{"id":"claude-sonnet","model_picker_enabled":true,"model_picker_category":"powerful","supported_endpoints":["/chat/completions","/responses","/v1/messages"],"capabilities":{"type":"chat","limits":{"max_context_window_tokens":200000,"max_output_tokens":64000},"supports":{"vision":true,"adaptive_thinking":true}}},'
        + '{"id":"gpt","model_picker_enabled":true,"supported_endpoints":["/responses"],"capabilities":{"type":"chat","supports":{"reasoning_effort":["low","high"]}}}'
        + ']}'
    )
    assert_equal(len(models), 2)
    assert_equal(models[0].id, "claude-sonnet")
    assert_equal(models[0].context_window.value(), 200000)
    assert_equal(models[0].max_output_tokens.value(), 64000)
    assert_true(models[0].supports_thinking.value())
    assert_true(models[0].supports_vision.value())
    assert_equal(models[0].tier.value().tag, ModelTier.STRONG)
    assert_equal(models[1].id, "gpt")
    var messages = parse_json('{"supported_endpoints":["/responses","/v1/messages"]}')
    assert_equal(copilot_model_endpoint(messages), "messages")
    assert_equal(copilot_model_endpoint(parse_json('{}')), "chat")
    assert_equal(copilot_guess_endpoint("claude-sonnet-4.6"), "messages")
    assert_equal(copilot_guess_endpoint("gpt-5.6-terra"), "responses")
    assert_equal(copilot_guess_endpoint("gpt-4.1"), "chat")
    var responses = copilot_provider_spec(
        "https://api.githubcopilot.com", "secret"
    )
    responses.responses_api = True
    assert_equal(
        responses.chat_url(), "https://api.githubcopilot.com/responses"
    )


def test_sse_incremental_multiline_and_finish() raises:
    var parser = SSEParser()
    var first = parser.feed("event: message\r\ndata: one\r\nda")
    assert_equal(len(first), 0)
    var second = parser.feed("ta: two\r\n\r\n: ignored\ndata: tail")
    assert_equal(len(second), 1)
    assert_equal(second[0], "one\ntwo")
    var tail = parser.finish()
    assert_equal(len(tail), 1)
    assert_equal(tail[0], "tail")


def test_sse_arbitrary_single_byte_boundaries() raises:
    var stream = "data: one\r\ndata: two\r\n\r\ndata: tail\n\n"
    var parser = SSEParser()
    var payloads = List[String]()
    for i in range(stream.byte_length()):
        var parsed = parser.feed(String(stream[byte=i]))
        for payload in parsed:
            payloads.append(payload.copy())
    var tail = parser.finish()
    for payload in tail:
        payloads.append(payload.copy())
    assert_equal(len(payloads), 2)
    assert_equal(payloads[0], "one\ntwo")
    assert_equal(payloads[1], "tail")


def test_anthropic_sse_text_tool_usage_thinking_and_stop() raises:
    var parser = AnthropicStreamParser()
    var stream = (
        'data: {"type":"message_start","message":{"usage":{"input_tokens":7}}}\n\n'
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think"}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}\n\n'
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n\n'
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}\n\n'
        'data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"bash"}}\n\n'
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}\n\n'
        'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\\"echo hi\\"}"}}\n\n'
        'data: {"type":"content_block_stop","index":2}\n\n'
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}\n\n'
        'data: {"type":"message_stop"}\n\n'
    )
    var events = List[ProviderEvent]()
    for i in range(stream.byte_length()):
        for event in parser.feed(String(stream[byte=i])):
            events.append(event.copy())
    for event in parser.finish():
        events.append(event.copy())
    var message = parser.message()
    assert_equal(message.content, "Hello")
    assert_equal(len(message.tool_calls), 1)
    assert_equal(message.tool_calls[0].id, "tu_1")
    assert_equal(message.tool_calls[0].name, "bash")
    assert_equal(message.tool_calls[0].arguments, '{"command":"echo hi"}')
    assert_equal(parser.blocks[0].text, "think")
    assert_equal(parser.blocks[0].signature.value(), "sig")
    assert_equal(parser.usage.input_tokens, 7)
    assert_equal(parser.usage.output_tokens, 5)
    assert_equal(parser.stop_reason, "tool_use")
    assert_true(events[len(events) - 1].kind == "done")


def test_anthropic_malformed_tool_input_falls_back_to_object() raises:
    var parser = AnthropicStreamParser()
    _ = parser.feed(
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu","name":"read"}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{broken"}}\n\n'
        'data: {"type":"content_block_stop","index":0}\n\n'
    )
    assert_equal(parser.message().tool_calls[0].arguments, "{}")


def test_gemini_sse_text_thinking_tools_usage_and_stop() raises:
    var parser = GeminiStreamParser()
    var stream = (
        'data: {"candidates":[{"content":{"parts":[{"text":"reason ","thought":true},{"text":"more","thought":true,"thoughtSignature":"sig"},{"text":"Hello"},{"functionCall":{"name":"bash","args":{"cmd":"ls"}},"thoughtSignature":"tool-sig"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":10,"cachedContentTokenCount":3}}\n\n'
    )
    var events = parser.feed(stream)
    for event in parser.finish():
        events.append(event.copy())
    var message = parser.message()
    assert_equal(message.content, "Hello")
    assert_equal(len(message.tool_calls), 1)
    assert_equal(message.tool_calls[0].name, "bash")
    assert_equal(message.tool_calls[0].arguments, '{"cmd":"ls"}')
    assert_equal(parser.blocks[0].text, "reason more")
    assert_equal(parser.blocks[0].signature.value(), "sig")
    assert_equal(parser.blocks[2].signature.value(), "tool-sig")
    assert_equal(parser.usage.input_tokens, 5)
    assert_equal(parser.usage.output_tokens, 10)
    assert_equal(parser.cache_read_tokens, 3)
    assert_equal(parser.stop_reason, "tool_calls")
    assert_true(events[len(events) - 1].kind == "done")


def test_gemini_coalesces_text_and_unique_parallel_tool_ids() raises:
    var parser = GeminiStreamParser()
    _ = parser.feed(
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello, "}]}}]}\n\n'
        'data: {"candidates":[{"content":{"parts":[{"text":"world."},{"functionCall":{"name":"bash","args":{}}},{"functionCall":{"name":"bash","args":{}}}]},"finishReason":"MAX_TOKENS"}]}\n\n'
    )
    assert_equal(parser.message().content, "Hello, world.")
    assert_equal(len(parser.message().tool_calls), 2)
    assert_true(
        parser.message().tool_calls[0].id != parser.message().tool_calls[1].id
    )
    assert_equal(parser.stop_reason, "tool_calls")


def test_openai_sse_and_partial_tool_assembly() raises:
    var parser = OpenAIStreamParser()
    var chunk1 = (
        "data:"
        ' {"choices":[{"delta":{"content":"hel","tool_calls":[{"index":0,"id":"call_","function":{"name":"wea","arguments":"{\\"city\\":"}}]}}]}\n\n'
    )
    var chunk2 = (
        "data:"
        ' {"choices":[{"delta":{"content":"lo","tool_calls":[{"index":0,"id":"1","function":{"name":"ther","arguments":"\\"Paris\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":7,"completion_tokens":3}}\n\ndata:'
        " [DONE]\n\n"
    )
    var events = parser.feed(chunk1)
    var more = parser.feed(chunk2)
    for event in more:
        events.append(event.copy())
    assert_true(len(events) >= 5)
    var calls = parser.tools.completed()
    assert_equal(len(calls), 1)
    assert_equal(calls[0].id, "call_1")
    assert_equal(calls[0].name, "weather")
    assert_equal(calls[0].arguments, '{"city":"Paris"}')
    assert_equal(parser.usage.input_tokens, 7)
    assert_equal(parser.usage.output_tokens, 3)
    assert_equal(parser.stop_reason, "tool_calls")


def test_provider_parses_transport_chunks_incrementally() raises:
    var stream = (
        'data: {"choices":[{"delta":{"content":"hello"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":2}}\n\n'
        "data: [DONE]\n\n"
    )
    var chunks = List[String]()
    for i in range(stream.byte_length()):
        chunks.append(String(stream[byte=i]))
    var provider = OpenAICompatibleProvider(
        ProviderSpec("offline", "https://example.invalid/v1")
    )
    var result = provider.parse_response_chunks(chunks)
    assert_equal(result.message.content, "hello world")
    assert_equal(result.usage.input_tokens, 2)
    assert_equal(result.usage.output_tokens, 2)
    assert_equal(result.stop_reason, "stop")


def test_provider_injected_transport_streams_during_perform() raises:
    var transport = MockTransport()
    var response = HttpResponse(200, "complete buffered body")
    var chunks: List[String] = [
        'data: {"choices":[{"delta":{"content":"live"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":" stream"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
    ]
    transport.enqueue_stream(response, chunks)
    var provider = OpenAICompatibleProvider(
        ProviderSpec("offline", "https://example.invalid/v1")
    )
    var result = provider.complete_json_with(transport, parse_json("{}"))
    assert_equal(result.message.content, "live stream")
    assert_equal(len(transport.requests), 1)
    assert_equal(transport.requests[0].method, "POST")


def test_http_response_headers_and_request_methods() raises:
    var response = HttpResponse()
    response.add_header_line("HTTP/1.1 200 OK\r\n")
    response.add_header_line("Content-Type: text/event-stream; charset=utf-8\r\n")
    response.add_header_line("mCp-SeSsIoN-Id: session-42\r\n")
    response.add_header_line("X-Test: first\r\n")
    response.add_header_line("x-test: second\r\n")
    response.add_header_line("\r\n")
    assert_equal(
        response.content_type(), "text/event-stream; charset=utf-8"
    )
    assert_equal(response.mcp_session_id(), "session-42")
    assert_equal(response.header("X-TEST"), "second")
    assert_equal(len(response.headers), 4)

    var get_request = HttpRequest("GET", "https://example.invalid")
    var post_request = HttpRequest("POST", "https://example.invalid")
    var delete_request = HttpRequest("DELETE", "https://example.invalid")
    var patch_request = HttpRequest("PATCH", "https://example.invalid")
    assert_equal(get_request.method, "GET")
    assert_equal(post_request.method, "POST")
    assert_equal(delete_request.method, "DELETE")
    assert_equal(patch_request.method, "PATCH")


def test_tool_calls_can_arrive_out_of_order() raises:
    var assembler = ToolCallAssembler()
    assembler.add(ToolCallDelta(1, "b", "second", "{}"))
    assembler.add(ToolCallDelta(0, "a", "fir", "{"))
    assembler.add(ToolCallDelta(0, "", "st", "}"))
    var calls = assembler.completed()
    assert_equal(len(calls), 2)
    assert_equal(calls[0].name, "first")
    assert_equal(calls[0].arguments, "{}")
    assert_equal(calls[1].id, "b")


def test_retry_and_key_rotation() raises:
    var keys: List[String] = ["a", "b", "c"]
    var key_state = ApiKeyState(keys^)
    assert_equal(key_state.current(), "a")
    assert_true(key_state.rotate())
    assert_equal(key_state.current(), "b")
    assert_true(key_state.rotate())
    assert_equal(key_state.current(), "c")

    var retry = RetryState(3)
    assert_true(retry.can_retry())
    assert_equal(retry.next_delay_ms(), 541)
    assert_equal(retry.next_delay_ms(), 1114)
    assert_equal(retry.next_delay_ms(90000), 60000)
    assert_false(retry.can_retry())
    assert_true(RetryState.retryable_status(429))
    assert_false(RetryState.retryable_status(400))


def test_oauth_state_and_refresh_request() raises:
    var oauth = OAuthState()
    oauth.access_token = "old"
    oauth.refresh_token = "r t&"
    oauth.token_url = "https://auth.example.invalid/token"
    oauth.client_id = "client"
    oauth.scope = "chat tools"
    oauth.expires_at_ms = 100000
    assert_false(oauth.expired(60000))
    assert_true(oauth.expired(71000))
    var request = oauth.refresh_request()
    assert_equal(request.method, "POST")
    assert_true("refresh_token=r+t%26" in request.body)
    assert_true("scope=chat+tools" in request.body)
    oauth.apply_refresh_response(
        '{"access_token":"new","refresh_token":"new-r","expires_in":3600}', 5000
    )
    assert_equal(oauth.access_token, "new")
    assert_equal(oauth.refresh_token, "new-r")
    assert_equal(oauth.expires_at_ms, 3605000)
    assert_equal(form_encode("a b+c"), "a+b%2Bc")


def test_provider_auth_precedence_and_usage() raises:
    var spec = ProviderSpec("custom", "https://example.invalid/v1/")
    spec.add_api_key("key-a")
    spec.add_api_key("key-b")
    var provider = OpenAICompatibleProvider(spec.copy())
    assert_equal(provider.auth_token(), "key-a")
    assert_true(provider.rotate_key())
    assert_equal(provider.auth_token(), "key-b")
    var oauth = OAuthState()
    oauth.access_token = "oauth-token"
    provider.set_oauth(oauth)
    assert_equal(provider.auth_token(), "oauth-token")
    assert_equal(provider.fetch_usage().total_tokens(), 0)


def test_openai_oauth_device_refresh_and_responses_transport() raises:
    var transport = MockTransport()
    transport.enqueue(HttpResponse(200, '{"device_auth_id":"device","user_code":"ABCD","interval":"1"}'))
    transport.enqueue(HttpResponse(403, "pending"))
    transport.enqueue(HttpResponse(404, "pending"))
    transport.enqueue(HttpResponse(200, '{"authorization_code":"code","code_verifier":"verify"}'))
    transport.enqueue(HttpResponse(200, '{"access_token":"access","refresh_token":"refresh","expires_in":3600,"id_token":"e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEyMyJ9.sig"}'))
    var path = "/tmp/mochi-openai-oauth-test.json"
    var credentials = openai_device_login_with(transport, 1000, path, False)
    assert_equal(credentials.account_id, "acct_123")
    assert_equal(len(transport.requests), 5)
    assert_equal(transport.requests[0].url, "https://auth.openai.com/api/accounts/deviceauth/usercode")
    assert_equal(transport.requests[4].url, "https://auth.openai.com/oauth/token")
    assert_true("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback" in transport.requests[4].body)

    var refresh_transport = MockTransport()
    refresh_transport.enqueue(HttpResponse(200, '{"access_token":"new-access","refresh_token":"new-refresh","expires_in":60}'))
    credentials = refresh_openai_oauth_with(refresh_transport, credentials, 5000)
    assert_equal(credentials.access_token, "new-access")
    assert_equal(credentials.expires_at_ms, 65000)
    assert_true("client_id=app_EMoamEEZ73f0CkXaXp7hrann" in refresh_transport.requests[0].body)

    var spec = ProviderSpec("openai-oauth", "")
    spec.responses_api = True
    spec.account_id = "acct_123"
    var provider = OpenAICompatibleProvider(spec^)
    provider.set_oauth(credentials.oauth_state())
    var stream_transport = MockTransport()
    var chunks: List[String] = [
        'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hello"}\n\n',
        'event: response.completed\ndata: {"type":"response.completed","response":{"usage":{"input_tokens":4,"output_tokens":1}}}\n\n',
    ]
    stream_transport.enqueue_stream(HttpResponse(200, ""), chunks)
    var result = provider.complete_json_with(stream_transport, parse_json('{"stream":true}'))
    assert_equal(result.message.content, "hello")
    assert_equal(result.usage.input_tokens, 4)
    var request = stream_transport.requests[0].copy()
    assert_equal(request.url, "https://chatgpt.com/backend-api/codex/responses")
    assert_equal(request.headers[2].name, "chatgpt-account-id")
    assert_equal(request.headers[2].value, "acct_123")
    assert_equal(request.headers[3].name, "originator")
    assert_equal(request.headers[4].value, "responses=v1")
    assert_equal(request.headers[5].value, "Bearer new-access")


def test_openai_jwt_account_id() raises:
    assert_equal(
        extract_chatgpt_account_id("e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEyMyJ9.sig"),
        "acct_123",
    )
    assert_equal(
        extract_chatgpt_account_id("e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF80NTYifX0.sig"),
        "acct_456",
    )
    assert_equal(extract_chatgpt_account_id("invalid"), "")


def test_openai_responses_tool_done_and_incomplete() raises:
    var spec = ProviderSpec("openai-oauth", "")
    spec.responses_api = True
    var provider = OpenAICompatibleProvider(spec^)
    var body = (
        'data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call","name":"read"}}\n\n'
        'data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":{"path":"README.md"}}\n\n'
        'data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call","name":"read","arguments":{"path":"README.md"}}}\n\n'
        'data: {"type":"response.incomplete","response":{"usage":{"input_tokens":2,"output_tokens":3}}}\n\n'
    )
    var result = provider.parse_response_body(body)
    assert_equal(result.stop_reason, "length")
    assert_equal(len(result.message.tool_calls), 1)
    assert_equal(result.message.tool_calls[0].arguments, '{"path":"README.md"}')


struct ContractEventLog(ProviderEventSink, Copyable, Movable):
    var events: List[DomainProviderEvent]

    def __init__(out self):
        self.events = List[DomainProviderEvent]()

    def emit(mut self, event: DomainProviderEvent) raises:
        self.events.append(event.copy())


def test_anthropic_provider_contract_adapter() raises:
    var transport = MockTransport()
    var chunks: List[String] = [
        'data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}\n\n',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}\n\n',
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu","name":"read"}}\n\ndata: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"README.md\\"}"}}\n\ndata: {"type":"content_block_stop","index":1}\n\n',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}\n\ndata: {"type":"message_stop"}\n\n',
    ]
    transport.enqueue_stream(HttpResponse(200, ""), chunks)
    var adapter = AnthropicProviderAdapterWithTransport(
        AnthropicProviderSpec("https://api.anthropic.com", "secret"),
        transport^,
        find_model_info("claude-opus-4-6"),
    )
    var model = Model(
        "claude-opus-4-6",
        "anthropic",
        ModelTier.strong(),
        ModelFamily.claude(),
        ThinkingSupport.yes(),
        Optional(True),
        ModelPricing(),
        Optional(128000),
        200000,
    )
    var messages: List[DomainMessage] = [DomainMessage.user("inspect")]
    var tools = parse_json('[{"type":"function","function":{"name":"read","description":"Read","parameters":{"type":"object"}}}]')
    var request = ProviderRequest(
        model^,
        CancellationToken(),
        messages^,
        "system",
        tools^,
    )
    var sink = ContractEventLog()
    var result = adapter.stream_message(request^, sink)
    assert_equal(result.message.content[0].text, "hello")
    assert_true(result.message.content[1].is_tool_use())
    assert_equal(result.message.content[1].input.get("path").string_value, "README.md")
    assert_equal(result.usage.input, 4)
    assert_equal(result.usage.output, 3)
    assert_true(result.stop_reason.value().is_tool_use())
    assert_equal(len(adapter.transport.requests), 1)
    var sent = adapter.transport.requests[0].copy()
    assert_equal(sent.url, "https://api.anthropic.com/v1/messages")
    assert_equal(sent.headers[2].name, "anthropic-version")
    assert_equal(sent.headers[3].name, "x-api-key")
    var body = parse_json(sent.body)
    assert_equal(body.get("model").string_value, "claude-opus-4-6")
    assert_equal(body.get("system").array_value[0].get("text").string_value, "system")
    assert_equal(body.get("tools").array_value[0].get("name").string_value, "read")


def test_gemini_provider_contract_adapter() raises:
    var transport = MockTransport()
    var chunks: List[String] = [
        'data: {"candidates":[{"content":{"parts":[{"text":"hello"},{"functionCall":{"name":"read","args":{"path":"README.md"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":3,"cachedContentTokenCount":2}}\n\n'
    ]
    transport.enqueue_stream(HttpResponse(200, ""), chunks)
    var adapter = GeminiProviderAdapterWithTransport(
        GeminiProviderSpec("https://generativelanguage.googleapis.com/v1beta", "secret"),
        transport^,
        find_model_info("gemini-2.5-pro"),
    )
    var model = Model(
        "gemini-2.5-pro",
        "google",
        ModelTier.strong(),
        ModelFamily.gemini(),
        ThinkingSupport.yes(),
        Optional(True),
        ModelPricing(),
        Optional(65536),
        1048576,
    )
    var messages: List[DomainMessage] = [DomainMessage.user("inspect")]
    var tools = parse_json('[{"type":"function","function":{"name":"read","description":"Read","parameters":{"type":"object"}}}]')
    var request = ProviderRequest(
        model^,
        CancellationToken(),
        messages^,
        "system",
        tools^,
    )
    var sink = ContractEventLog()
    var result = adapter.stream_message(request^, sink)
    assert_equal(result.message.content[0].text, "hello")
    assert_true(result.message.content[1].is_tool_use())
    assert_equal(result.message.content[1].input.get("path").string_value, "README.md")
    assert_equal(result.usage.input, 4)
    assert_equal(result.usage.output, 3)
    assert_equal(result.usage.cache_read, 2)
    assert_true(result.stop_reason.value().is_tool_use())
    var sent = adapter.transport.requests[0].copy()
    assert_true("gemini-2.5-pro:streamGenerateContent?alt=sse" in sent.url)
    assert_equal(sent.headers[2].name, "x-goog-api-key")
    var body = parse_json(sent.body)
    assert_equal(body.get("contents").array_value[0].get("role").string_value, "user")
    assert_equal(body.get("systemInstruction").get("parts").array_value[0].get("text").string_value, "system")
    assert_equal(body.get("tools").array_value[0].get("functionDeclarations").array_value[0].get("name").string_value, "read")


def test_openai_provider_contract_adapter() raises:
    var transport = MockTransport()
    var chunks: List[String] = [
        'data: {"choices":[{"delta":{"content":"hello","tool_calls":[{"index":0,"id":"call-1","function":{"name":"read","arguments":"{\\"path\\":\\"README.md\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}\n\n',
        "data: [DONE]\n\n",
    ]
    transport.enqueue_stream(HttpResponse(200, ""), chunks)
    var provider = OpenAICompatibleProvider(
        ProviderSpec("openai", "https://example.invalid/v1")
    )
    var adapter = OpenAIProviderAdapterWithTransport(
        provider^, transport^, ModelInfo.id_only("gpt-test")
    )
    var model = Model(
        "gpt-test",
        "openai",
        ModelTier.medium(),
        ModelFamily.gpt(),
        ThinkingSupport.no(),
        None,
        ModelPricing(),
        Optional(4096),
        32000,
    )
    var messages: List[DomainMessage] = [DomainMessage.user("hi")]
    var request = ProviderRequest(
        model^, CancellationToken(), messages^, system="system"
    )
    var sink = ContractEventLog()
    var result = adapter.stream_message(request, sink)
    assert_equal(result.message.content[0].text, "hello")
    assert_true(result.message.has_tool_calls())
    assert_equal(result.usage.input, 4)
    assert_equal(result.usage.output, 2)
    assert_true(result.stop_reason.value().is_tool_use())
    assert_equal(len(sink.events), 2)
    assert_true(sink.events[0].is_text_delta())
    assert_true(sink.events[1].is_tool_use_start())
    assert_equal(len(adapter.transport.requests), 1)
    var wire = parse_json(adapter.transport.requests[0].body)
    assert_equal(wire.get("model").string_value, "gpt-test")
    assert_equal(
        wire.get("messages").array_value[0].get("role").string_value,
        "system",
    )


def test_openai_provider_contract_pre_cancel() raises:
    var transport = MockTransport()
    var adapter = OpenAIProviderAdapterWithTransport(
        OpenAICompatibleProvider(
            ProviderSpec("openai", "https://example.invalid/v1")
        ),
        transport^,
        ModelInfo.id_only("gpt-test"),
    )
    var model = Model(
        "gpt-test",
        "openai",
        ModelTier.medium(),
        ModelFamily.gpt(),
        ThinkingSupport.no(),
        None,
        ModelPricing(),
        None,
        32000,
    )
    var cancel = CancellationToken()
    cancel.cancel()
    var sink = ContractEventLog()
    with assert_raises():
        _ = adapter.stream_message(
            ProviderRequest(model^, cancel.copy()), sink
        )
    assert_equal(len(adapter.transport.requests), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
