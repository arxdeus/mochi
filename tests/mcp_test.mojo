from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from mochi.http import HttpResponse, MockTransport
from mochi.json import JsonValue, parse_json
from mochi.mcp import (
    MCP_PROTOCOL_VERSION,
    McpClient,
    McpOAuthState,
    McpSession,
    StdioTransport,
    StreamableHttpTransport,
    discover_mcp_auth_server_with,
    discover_mcp_resource_metadata_with,
    generate_mcp_pkce,
    mcp_auth_server_metadata_urls,
    mcp_endpoint_url_is_secure,
    mcp_oauth_code_exchange_request,
    mcp_pkce_challenge,
    mcp_resource_matches_server,
    mcp_resource_metadata_urls,
    mcp_server_origin,
    mcp_well_known_url,
    parse_www_authenticate,
    register_mcp_oauth_client_with,
)
from mochi.storage import OAuthTokens


def test_initialize_and_initialized() raises:
    var session = McpSession()
    var request = session.initialize_request("fixture", "1.0")
    assert_equal(request.get("jsonrpc").string_value, "2.0")
    assert_equal(request.get("method").string_value, "initialize")
    assert_equal(
        request.get("params").get("protocolVersion").string_value,
        MCP_PROTOCOL_VERSION,
    )
    var result = session.accept_initialize(
        parse_json(
            '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}}}}'
        ),
        1,
    )
    assert_true(session.initialized)
    assert_true(result.contains("capabilities"))
    assert_equal(
        session.initialized_notification().get("method").string_value,
        "notifications/initialized",
    )



def test_json_rpc_errors_and_fixture_exchange() raises:
    var session = McpSession()
    var request = session.tools_list_request()
    var result = session.fixture_exchange(
        request^,
        '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}',
    )
    assert_equal(len(session.fixture_outbox), 1)
    assert_equal(len(result.get("tools").array_value), 0)
    var bad_request = session.tools_list_request()
    with assert_raises():
        _ = session.fixture_exchange(
            bad_request^,
            '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"missing"}}',
        )


def test_paginated_lists() raises:
    var first = parse_json('{"tools":[{"name":"one"}],"nextCursor":"next"}')
    var second = parse_json('{"tools":[{"name":"two"}]}')
    var pages = List[JsonValue]()
    pages.append(first^)
    pages.append(second^)
    var tools = McpSession.collect_tools(pages)
    assert_equal(len(tools), 2)
    assert_equal(tools[0].get("name").string_value, "one")
    assert_equal(tools[1].get("name").string_value, "two")

    var prompt_pages = List[JsonValue]()
    prompt_pages.append(parse_json('{"prompts":[{"name":"review"}]}'))
    assert_equal(
        McpSession.collect_prompts(prompt_pages)[0].get("name").string_value,
        "review",
    )
    var resource_pages = List[JsonValue]()
    resource_pages.append(parse_json('{"resources":[{"uri":"file:///x"}]}'))
    assert_equal(
        McpSession.collect_resources(resource_pages)[0].get("uri").string_value,
        "file:///x",
    )


def test_method_envelopes() raises:
    var session = McpSession()
    var call = session.tools_call_request("echo", parse_json('{"text":"hi"}'))
    assert_equal(call.get("method").string_value, "tools/call")
    assert_equal(call.get("params").get("name").string_value, "echo")
    assert_equal(
        call.get("params").get("arguments").get("text").string_value, "hi"
    )

    var prompt = session.prompts_get_request(
        "review", Optional(parse_json('{"language":"mojo"}'))
    )
    assert_equal(prompt.get("method").string_value, "prompts/get")
    assert_equal(
        prompt.get("params").get("arguments").get("language").string_value,
        "mojo",
    )
    assert_equal(
        session.prompts_list_request("p2")
        .get("params")
        .get("cursor")
        .string_value,
        "p2",
    )

    var resource = session.resources_read_request("file:///tmp/x")
    assert_equal(resource.get("method").string_value, "resources/read")
    assert_equal(
        resource.get("params").get("uri").string_value, "file:///tmp/x"
    )
    assert_equal(
        session.resources_list_request().get("method").string_value,
        "resources/list",
    )


def test_cancellation_notifications() raises:
    var session = McpSession()
    var notification = session.cancellation_notification(42, "stale")
    assert_false(notification.contains("id"))
    assert_equal(
        notification.get("method").string_value, "notifications/cancelled"
    )
    assert_true(session.is_cancelled(42))

    var receiver = McpSession()
    receiver.accept_notification(notification^)
    assert_true(receiver.is_cancelled(42))


def test_stdio_fixture_transport() raises:
    var transport = StdioTransport()
    transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":7,"result":{"ok":true}}'
    )
    var response = transport.send(
        parse_json('{"jsonrpc":"2.0","id":7,"method":"ping"}')
    )
    assert_true(response.get("result").get("ok").bool_value)
    assert_equal(len(transport.fixture_writes), 1)


def test_mcp_oauth_discovery_primitives() raises:
    var auth = parse_www_authenticate(
        'Bearer realm="example", resource_metadata="https://rs.example.com/meta", scope="read write"'
    )
    assert_true(auth)
    assert_equal(auth.value().resource_metadata, "https://rs.example.com/meta")
    assert_equal(auth.value().scope, "read write")
    assert_false(parse_www_authenticate('Basic realm="example"'))

    assert_equal(mcp_server_origin("https://example.com/api/v1/"), "https://example.com")
    assert_equal(
        mcp_well_known_url("https://example.com/api/v1", "oauth-authorization-server"),
        "https://example.com/.well-known/oauth-authorization-server/api/v1",
    )
    var resource_urls = mcp_resource_metadata_urls("https://example.com/mcp")
    assert_equal(len(resource_urls), 2)
    assert_equal(
        resource_urls[0],
        "https://example.com/.well-known/oauth-protected-resource/mcp",
    )
    assert_equal(
        resource_urls[1],
        "https://example.com/.well-known/oauth-protected-resource",
    )
    var auth_urls = mcp_auth_server_metadata_urls("https://auth.example/tenant")
    assert_equal(len(auth_urls), 4)
    assert_equal(
        auth_urls[0],
        "https://auth.example/.well-known/oauth-authorization-server/tenant",
    )
    assert_equal(
        auth_urls[3], "https://auth.example/.well-known/openid-configuration"
    )

    assert_true(mcp_endpoint_url_is_secure("https://example.com/token"))
    assert_true(mcp_endpoint_url_is_secure("http://localhost:8080/token"))
    assert_true(mcp_endpoint_url_is_secure("http://127.0.0.1:8080/token"))
    assert_false(mcp_endpoint_url_is_secure("http://example.com/token"))
    assert_true(
        mcp_resource_matches_server("HTTPS://EXAMPLE.com/mcp/", "https://example.com/mcp")
    )
    assert_true(
        mcp_resource_matches_server("https://example.com", "https://example.com/mcp")
    )
    assert_false(
        mcp_resource_matches_server("https://example.com/MCP", "https://example.com/mcp")
    )


def test_mcp_oauth_injected_discovery() raises:
    var resource_transport = MockTransport()
    resource_transport.enqueue(HttpResponse(404, "missing"))
    resource_transport.enqueue(
        HttpResponse(
            200,
            '{"resource":"https://mcp.example","authorization_servers":["https://auth.example/tenant"],"scopes_supported":["read"]}',
        )
    )
    var resource = discover_mcp_resource_metadata_with(
        resource_transport, "https://mcp.example/mcp"
    )
    assert_equal(resource.resource, "https://mcp.example")
    assert_equal(resource.authorization_servers[0], "https://auth.example/tenant")
    assert_equal(len(resource_transport.requests), 2)
    assert_equal(
        resource_transport.requests[0].url,
        "https://mcp.example/.well-known/oauth-protected-resource/mcp",
    )
    assert_equal(
        resource_transport.requests[1].url,
        "https://mcp.example/.well-known/oauth-protected-resource",
    )

    var auth_transport = MockTransport()
    auth_transport.enqueue(HttpResponse(404, "missing"))
    auth_transport.enqueue(
        HttpResponse(
            200,
            '{"authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","registration_endpoint":"https://auth.example/register","code_challenge_methods_supported":["S256"]}',
        )
    )
    var metadata = discover_mcp_auth_server_with(
        auth_transport, "https://auth.example/tenant"
    )
    assert_equal(metadata.token_endpoint, "https://auth.example/token")
    assert_equal(metadata.code_challenge_methods_supported[0], "S256")
    assert_equal(len(auth_transport.requests), 2)

    var insecure = MockTransport()
    insecure.enqueue(
        HttpResponse(
            200,
            '{"authorization_endpoint":"http://auth.example/authorize","token_endpoint":"http://auth.example/token"}',
        )
    )
    insecure.enqueue(HttpResponse(404, "missing"))
    insecure.enqueue(HttpResponse(404, "missing"))
    insecure.enqueue(HttpResponse(404, "missing"))
    with assert_raises():
        _ = discover_mcp_auth_server_with(insecure, "https://auth.example/tenant")


def test_mcp_oauth_pkce() raises:
    assert_equal(
        mcp_pkce_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    )
    var first = generate_mcp_pkce()
    var second = generate_mcp_pkce()
    assert_equal(first.verifier.byte_length(), 43)
    assert_equal(first.challenge.byte_length(), 43)
    assert_true(first.verifier != second.verifier)
    assert_true(first.challenge != second.challenge)


def test_mcp_oauth_registration_and_code_exchange() raises:
    var registration_transport = MockTransport()
    registration_transport.enqueue(
        HttpResponse(
            201,
            '{"client_id":"dynamic-client","client_secret":"secret","client_secret_expires_at":1234}',
        )
    )
    var registration = register_mcp_oauth_client_with(
        registration_transport,
        "https://auth.example/register",
        "http://127.0.0.1:8765/callback",
    )
    assert_equal(registration.client_id, "dynamic-client")
    assert_equal(registration.client_secret, "secret")
    assert_equal(registration.client_secret_expires_at, 1234)
    var body = parse_json(registration_transport.requests[0].body)
    assert_equal(body.get("client_name").string_value, "Maki")
    assert_equal(
        body.get("redirect_uris").array_value[0].string_value,
        "http://127.0.0.1:8765/callback",
    )
    assert_equal(body.get("token_endpoint_auth_method").string_value, "none")

    var request = mcp_oauth_code_exchange_request(
        "https://auth.example/token",
        "code value",
        "http://127.0.0.1:8765/callback",
        "verifier",
        "dynamic-client",
        "secret",
        "https://mcp.example/mcp",
    )
    assert_equal(request.method, "POST")
    assert_true("grant_type=authorization_code" in request.body)
    assert_true("code=code%20value" in request.body)
    assert_true("code_verifier=verifier" in request.body)
    assert_true("client_secret=secret" in request.body)
    assert_true("resource=https%3A%2F%2Fmcp.example%2Fmcp" in request.body)


def test_mcp_oauth_refresh_contract() raises:
    var oauth = McpOAuthState(
        OAuthTokens("old", "refresh token", 100, None),
        "https://auth.example/token",
        "client",
        "secret",
        "https://mcp.example/mcp",
    )
    assert_true(oauth.expired(100))
    assert_true(oauth.can_refresh())
    var request = oauth.refresh_request()
    assert_equal(request.method, "POST")
    assert_true("refresh_token=refresh%20token" in request.body)
    assert_true("client_secret=secret" in request.body)
    oauth.apply_refresh_response(
        '{"access_token":"new","refresh_token":"next","expires_in":60}',
        1000,
    )
    assert_equal(oauth.authorization_header(), "Bearer new")
    assert_equal(oauth.tokens.refresh, "next")
    assert_equal(oauth.tokens.expires, 61000)

    var refreshed = McpOAuthState(
        OAuthTokens("old", "refresh", 100, None),
        "https://auth.example/token",
        "client",
        "",
        "",
    )
    var refresh_transport = MockTransport()
    refresh_transport.enqueue(
        HttpResponse(200, '{"access_token":"fresh","expires_in":120}')
    )
    var http = StreamableHttpTransport("https://mcp.example/mcp")
    http.refresh_oauth_with(refreshed, refresh_transport, 2000)
    assert_equal(http.bearer_token, "fresh")
    assert_equal(refreshed.tokens.expires, 122000)


def test_streamable_http_fixture_json_and_sse() raises:
    var transport = StreamableHttpTransport("http://fixture.invalid/mcp")
    assert_equal(transport.content_type(), "application/json")
    assert_equal(
        transport.accept_header(), "application/json, text/event-stream"
    )
    transport.fixture_response(
        200,
        "application/json",
        '{"jsonrpc":"2.0","id":1,"result":{"ok":true}}',
        "session-1",
    )
    assert_true(transport.consume_fixture(1).get("result").get("ok").bool_value)
    assert_equal(transport.session_header(), "session-1")

    transport.fixture_response(
        200,
        "text/event-stream",
        (
            "event: message\ndata:"
            ' {"jsonrpc":"2.0","id":2,"result":{"value":"sse"}}\n\n'
        ),
    )
    assert_equal(
        transport.consume_fixture(2).get("result").get("value").string_value,
        "sse",
    )


def test_http_send_notify_delete_fixtures() raises:
    var transport = StreamableHttpTransport("http://fixture.invalid/mcp")
    transport.fixture_response(
        200,
        "application/json",
        '{"jsonrpc":"2.0","id":9,"result":{"ok":true}}',
        "fixture-session",
    )
    var response = transport.send(
        parse_json('{"jsonrpc":"2.0","id":9,"method":"ping"}')
    )
    assert_true(response.get("result").get("ok").bool_value)
    assert_equal(transport.session_header(), "fixture-session")
    transport.notify(
        parse_json('{"jsonrpc":"2.0","method":"notifications/initialized"}')
    )
    transport.delete_session()
    assert_equal(transport.session_header(), "")


def test_http_injected_transport_updates_session() raises:
    var http = StreamableHttpTransport("https://fixture.invalid/mcp")
    var transport = MockTransport()
    var response = HttpResponse(
        200, '{"jsonrpc":"2.0","id":9,"result":{"ok":true}}'
    )
    response.add_header("Content-Type", "application/json")
    response.add_header("Mcp-Session-Id", "injected-session")
    transport.enqueue(response)
    var result = http.send_with(
        transport, parse_json('{"jsonrpc":"2.0","id":9,"method":"ping"}')
    )
    assert_true(result.get("result").get("ok").bool_value)
    assert_equal(http.session_header(), "injected-session")
    assert_equal(len(transport.requests), 1)

    http.set_bearer_token("secret")
    var authenticated = MockTransport()
    authenticated.enqueue(
        HttpResponse(200, '{"jsonrpc":"2.0","id":10,"result":{}}')
    )
    _ = http.send_with(
        authenticated, parse_json('{"jsonrpc":"2.0","id":10,"method":"ping"}')
    )
    var authorization = String("")
    for header in authenticated.requests[0].headers:
        if header.name == "Authorization":
            authorization = header.value
    assert_equal(authorization, "Bearer secret")
    http.clear_bearer_token()


def test_http_401_refreshes_and_retries_once() raises:
    var http = StreamableHttpTransport("https://mcp.example/mcp")
    var oauth = McpOAuthState(
        OAuthTokens("expired", "refresh", 100, None),
        "https://auth.example/token",
        "client",
        "",
        "https://mcp.example/mcp",
    )
    var transport = MockTransport()
    transport.enqueue(HttpResponse(401, "unauthorized"))
    transport.enqueue(
        HttpResponse(200, '{"access_token":"fresh","expires_in":120}')
    )
    transport.enqueue(
        HttpResponse(200, '{"jsonrpc":"2.0","id":11,"result":{"ok":true}}')
    )
    var result = http.send_with_oauth(
        transport,
        parse_json('{"jsonrpc":"2.0","id":11,"method":"ping"}'),
        oauth,
        2000,
    )
    assert_true(result.get("result").get("ok").bool_value)
    assert_equal(len(transport.requests), 3)
    assert_equal(transport.requests[1].url, "https://auth.example/token")
    var retry_authorization = String("")
    for header in transport.requests[2].headers:
        if header.name == "Authorization":
            retry_authorization = header.value
    assert_equal(retry_authorization, "Bearer fresh")
    assert_equal(oauth.tokens.access, "fresh")

    var rejected = MockTransport()
    rejected.enqueue(HttpResponse(401, "unauthorized"))
    rejected.enqueue(HttpResponse(401, "still unauthorized"))
    rejected.enqueue(HttpResponse(200, '{"access_token":"unused"}'))
    with assert_raises():
        _ = http.send_with_oauth(
            rejected,
            parse_json('{"jsonrpc":"2.0","id":12,"method":"ping"}'),
            oauth,
            3000,
        )
    assert_equal(len(rejected.requests), 2)


def test_high_level_stdio_client() raises:
    var transport = StdioTransport()
    transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}'
    )
    transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo"}],"nextCursor":"more"}}'
    )
    transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"other"}]}}'
    )
    transport.enqueue_fixture_response(
        '{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":"hi"}]}}'
    )
    var client = McpClient("fixture")
    _ = client.initialize(transport)
    var tools = client.list_tools(transport)
    assert_equal(len(tools), 2)
    assert_equal(tools[1].get("name").string_value, "other")
    var result = client.call_tool(transport, "echo", parse_json('{"x":1}'))
    assert_equal(
        result.get("content").array_value[0].get("text").string_value, "hi"
    )
    assert_equal(len(transport.fixture_writes), 5)


def test_high_level_http_client_fixture() raises:
    var transport = StreamableHttpTransport("http://fixture.invalid/mcp")
    transport.fixture_response(
        200,
        "application/json",
        '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}',
        "session-2",
    )
    var client = McpClient("fixture")
    _ = client.initialize(transport)
    assert_true(client.session.initialized)
    assert_equal(transport.session_header(), "session-2")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
