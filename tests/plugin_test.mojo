from mochi.json import JsonValue, parse_json
from mochi.plugin import (
    ERROR_INVOKE,
    ERROR_INVALID_PARAMS,
    METHOD_HANDSHAKE,
    METHOD_INVOKE,
    METHOD_REGISTER,
    METHOD_SHUTDOWN,
    PLUGIN_PROTOCOL_VERSION,
    PluginClient,
    PluginExecutable,
    PluginProtocol,
    PluginRegistration,
    PluginTransport,
    RpcMessage,
    error_result,
    handshake_result,
    invoke_result,
    normalize_plugin_command_name,
    plugin_command_key,
    registration_result,
    shutdown_result,
)
from std.ffi import c_int, c_long, external_call
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)


def test_json_rpc_lines_and_protocol_constants() raises:
    var protocol = PluginProtocol()
    var line = protocol.handshake("test-host")
    assert_true(line.endswith("\n"))
    var request = RpcMessage.parse(line)
    assert_equal(request.method, METHOD_HANDSHAKE)
    assert_equal(request.id, 1)
    assert_equal(
        request.payload.get("version").int_value, PLUGIN_PROTOCOL_VERSION
    )
    assert_equal(request.payload.get("host").string_value, "test-host")


def test_handshake_registration_invoke_shutdown_state_flow() raises:
    var protocol = PluginProtocol()
    var handshake = RpcMessage.parse(protocol.handshake())
    protocol.accept_handshake(handshake_result(handshake.id, "example"))

    var register = RpcMessage.parse(protocol.registration_request())
    assert_equal(register.method, METHOD_REGISTER)
    var metadata = PluginRegistration("example", "1.2.3")
    metadata.tools.append(
        parse_json('{"name":"search","description":"Search","schema":{}}')
    )
    metadata.commands.append(parse_json('{"name":"/hello"}'))
    metadata.events.append(JsonValue.string("session.started"))
    metadata.prompt_hints.append(JsonValue.string("Be concise"))
    metadata.keymaps.append(parse_json('{"key":"ctrl+k","command":"hello"}'))
    protocol.accept_registration(registration_result(register.id, metadata))
    assert_true(protocol.is_ready())
    assert_true(protocol.registration)
    assert_equal(protocol.registration.value().name, "example")
    assert_equal(len(protocol.registration.value().tools.array_value), 1)
    assert_equal(len(protocol.registration.value().commands.array_value), 1)
    assert_equal(len(protocol.registration.value().events.array_value), 1)
    assert_equal(len(protocol.registration.value().prompt_hints.array_value), 1)
    assert_equal(len(protocol.registration.value().keymaps.array_value), 1)

    var arguments = parse_json('{"query":"mojo"}')
    var invoke = RpcMessage.parse(protocol.invoke("tool", "search", arguments^))
    assert_equal(invoke.method, METHOD_INVOKE)
    assert_equal(invoke.payload.get("kind").string_value, "tool")
    assert_equal(invoke.payload.get("name").string_value, "search")
    var answer = parse_json('{"content":"found"}')
    var result = protocol.accept_invoke(invoke_result(invoke.id, answer^))
    assert_equal(result.get("content").string_value, "found")
    assert_true(protocol.is_ready())

    var shutdown = RpcMessage.parse(protocol.shutdown())
    assert_equal(shutdown.method, METHOD_SHUTDOWN)
    protocol.accept_shutdown(shutdown_result(shutdown.id))
    assert_equal(protocol.state, PluginProtocol.CLOSED)


def test_invalid_order_version_id_and_remote_error() raises:
    var protocol = PluginProtocol()
    with assert_raises():
        _ = protocol.registration_request()

    var handshake = RpcMessage.parse(protocol.handshake())
    var wrong_version = parse_json(handshake_result(handshake.id))
    var wrong_result = wrong_version.get("result")
    wrong_result.set("version", JsonValue.integer(99))
    wrong_version.set("result", wrong_result^)
    with assert_raises():
        protocol.accept_handshake(wrong_version.serialize())
    assert_equal(protocol.state, PluginProtocol.FAILED)

    protocol = PluginProtocol()
    handshake = RpcMessage.parse(protocol.handshake())
    with assert_raises():
        protocol.accept_handshake(handshake_result(handshake.id + 1))
    assert_equal(protocol.state, PluginProtocol.FAILED)

    protocol = PluginProtocol()
    handshake = RpcMessage.parse(protocol.handshake())
    with assert_raises():
        protocol.accept_handshake(
            error_result(handshake.id, ERROR_INVALID_PARAMS, "bad handshake")
        )
    assert_equal(protocol.state, PluginProtocol.FAILED)


def test_transport_codec_and_client_orchestration() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "fixture"))
    var metadata = PluginRegistration("fixture", "1.0.0")
    transport.enqueue_fixture_response(registration_result(2, metadata))
    transport.enqueue_fixture_response(
        invoke_result(3, parse_json('{"content":"echo"}'))
    )
    transport.enqueue_fixture_response(shutdown_result(4))

    var client = PluginClient(transport^)
    client.connect("codec-test")
    assert_true(client.is_ready())
    assert_equal(len(client.transport.fixture_writes), 2)
    assert_true(client.transport.fixture_writes[0].endswith("\n"))
    var handshake = RpcMessage.parse(client.transport.fixture_writes[0])
    assert_equal(handshake.method, METHOD_HANDSHAKE)
    assert_equal(handshake.payload.get("host").string_value, "codec-test")
    var registration = RpcMessage.parse(client.transport.fixture_writes[1])
    assert_equal(registration.method, METHOD_REGISTER)

    var result = client.invoke("tool", "echo", JsonValue.object())
    assert_equal(result.get("content").string_value, "echo")
    var invoke = RpcMessage.parse(client.transport.fixture_writes[2])
    assert_equal(invoke.method, METHOD_INVOKE)
    assert_equal(invoke.payload.get("name").string_value, "echo")

    client.shutdown()
    assert_equal(client.protocol.state, PluginProtocol.CLOSED)
    var shutdown = RpcMessage.parse(client.transport.fixture_writes[3])
    assert_equal(shutdown.method, METHOD_SHUTDOWN)


def test_client_reconnects_after_shutdown() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "first"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("first", "1.0.0"))
    )
    transport.enqueue_fixture_response(shutdown_result(3))
    transport.enqueue_fixture_response(handshake_result(1, "second"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("second", "2.0.0"))
    )
    var client = PluginClient(transport^)
    client.connect()
    client.shutdown()
    client.reconnect()
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "second")


def _shell_plugin_executable(
    plugin_name: String, exit_negotiated_leader: Bool = False
) raises -> PluginExecutable:
    var registration = PluginRegistration(plugin_name, "1.0.0")
    var handshake = String(handshake_result(1, plugin_name).strip())
    var registered = String(registration_result(2, registration).strip())
    var protocol = (
        "IFS= read -r request; printf '%s\\n' '"
        + handshake
        + "'; IFS= read -r request; printf '%s\\n' '"
        + registered
        + "'"
    )
    if exit_negotiated_leader:
        # The background protocol writer keeps the pipes alive, but the owned
        # process leader is already gone by the time registration is accepted.
        protocol = "(sleep 0.1; " + protocol + ") & exit 0"
    else:
        protocol += "; cat >/dev/null"
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument(protocol^)
    return executable^


def test_real_executable_reconnect_uses_live_shadow() raises:
    var client = PluginClient.launch(_shell_plugin_executable("live"))
    var first_pid = client.transport.pid
    client.reconnect()
    assert_true(client.is_ready())
    assert_true(client.transport.pid > 0)
    assert_true(client.transport.pid != first_pid)
    assert_equal(client.protocol.registration.value().name, "live")
    client.cancel()


def test_client_reload_reconnects_fixture_registration() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "first"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("first", "1.0.0"))
    )
    transport.enqueue_fixture_response(handshake_result(1, "second"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("second", "2.0.0"))
    )
    var client = PluginClient(transport^)
    client.connect()
    client.reload()
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "second")


def test_failed_shadow_reload_preserves_live_client() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "live"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("live", "1.0.0"))
    )
    transport.enqueue_fixture_response(
        invoke_result(3, parse_json('{"content":"still live"}'))
    )
    var client = PluginClient(transport^)
    client.connect()
    client.executable = Optional(PluginExecutable("/bin/false"))
    with assert_raises():
        client.reload()
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "live")
    var result = client.invoke("tool", "echo", JsonValue.object())
    assert_equal(result.get("content").string_value, "still live")


def test_exited_registered_shadow_preserves_live_client() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "live"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("live", "1.0.0"))
    )
    transport.enqueue_fixture_response(
        invoke_result(3, parse_json('{"content":"last good"}'))
    )
    var client = PluginClient(transport^)
    client.connect()
    client.executable = Optional(
        _shell_plugin_executable("dead-candidate", exit_negotiated_leader=True)
    )
    with assert_raises():
        client.reload()
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "live")
    var result = client.invoke("tool", "echo", JsonValue.object())
    assert_equal(result.get("content").string_value, "last good")


def test_invoke_error_is_recoverable_for_the_same_process() raises:
    var transport = PluginTransport()
    transport.enqueue_fixture_response(handshake_result(1, "recoverable"))
    transport.enqueue_fixture_response(
        registration_result(2, PluginRegistration("recoverable", "1.0.0"))
    )
    transport.enqueue_fixture_response(
        error_result(3, ERROR_INVOKE, "scripted failure")
    )
    transport.enqueue_fixture_response(
        invoke_result(4, parse_json('{"content":"recovered"}'))
    )
    var client = PluginClient(transport^)
    client.connect()
    with assert_raises():
        _ = client.invoke("tool", "fail_once", JsonValue.object())
    assert_true(client.is_ready())
    var recovered = client.invoke("tool", "echo", JsonValue.object())
    assert_equal(recovered.get("content").string_value, "recovered")


def test_transport_cancel_terminates_owned_child() raises:
    var executable = PluginExecutable("sh")
    executable.add_argument("-c")
    executable.add_argument("sleep 30")
    var transport = PluginTransport.spawn(executable)
    assert_true(transport.pid > 0)
    transport.cancel()
    assert_equal(Int(transport.pid), -1)
    assert_equal(Int(transport.write_fd), -1)
    assert_equal(Int(transport.read_fd), -1)


def test_spawn_closes_inherited_sentinel_fd() raises:
    var null_path = String("/dev/null")
    var source_fd = external_call["open", c_int](
        null_path.as_c_string_slice(), c_int(0)
    )
    assert_true(source_fd >= 0)
    # F_DUPFD = 0 on supported POSIX hosts. A high descriptor avoids a shell
    # implementation legitimately reusing the just-closed low descriptor.
    var sentinel_fd = external_call["fcntl", c_int](
        source_fd, c_int(0), c_int(200)
    )
    _ = external_call["close", c_int](source_fd)
    assert_true(sentinel_fd >= 200)
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument(
        "if [ -e /proc/self/fd/"
        + String(sentinel_fd)
        + " ] || [ -e /dev/fd/"
        + String(sentinel_fd)
        + " ]; then printf 'inherited\\n'; else printf 'closed\\n'; fi; cat"
        " >/dev/null"
    )
    var transport = PluginTransport.spawn(executable)
    var observed = transport.send_line("{}")
    _ = external_call["close", c_int](sentinel_fd)
    transport.cancel()
    assert_equal(observed, "closed")
    assert_equal(len(transport.fixture_writes), 0)


def test_transport_scan_offset_resets_after_buffered_frames() raises:
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument("printf '\\nsecond\\n'; cat >/dev/null")
    var transport = PluginTransport.spawn(executable)
    transport.read_buffer.append(UInt8(97))
    transport.read_buffer.append(UInt8(98))
    transport.read_buffer.append(UInt8(99))
    transport.read_scan_offset = 3
    var deadline = external_call["mochi_deadline_after_millis", c_long, c_long](
        c_long(1000)
    )
    assert_equal(transport.read_line(deadline), "abc")
    assert_equal(transport.read_scan_offset, 0)
    assert_equal(transport.read_line(deadline), "second")
    assert_equal(transport.read_scan_offset, 0)
    transport.cancel()


def test_silent_process_is_killed_at_request_deadline() raises:
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument("sleep 5")
    var transport = PluginTransport.spawn(executable)
    transport.request_timeout_seconds = 1
    var client = PluginClient(transport^)
    with assert_raises():
        client.connect()
    assert_false(client.is_ready())
    assert_equal(Int(client.transport.pid), -1)


def test_closed_plugin_stdin_raises_without_sigpipe_terminating_host() raises:
    var executable = PluginExecutable("/bin/sh")
    executable.add_argument("-c")
    executable.add_argument("exec 0<&-; sleep 2")
    var transport = PluginTransport.spawn(executable)
    _ = external_call["sleep", UInt32](UInt32(1))
    with assert_raises():
        _ = transport.send_line("{}")
    transport.cancel()
    assert_equal(Int(transport.pid), -1)


def test_transport_codec_rejects_unconnected_send() raises:
    var transport = PluginTransport()
    with assert_raises():
        _ = transport.send_line('{"jsonrpc":"2.0"}')
    assert_equal(len(transport.fixture_writes), 0)


def test_malformed_messages_and_registration() raises:
    with assert_raises():
        _ = RpcMessage.parse("not json")
    with assert_raises():
        _ = RpcMessage.parse('{"jsonrpc":"1.0","id":1,"result":null}')
    with assert_raises():
        _ = RpcMessage.parse(
            '{"jsonrpc":"2.0","id":1,"result":null,"error":{}}'
        )

    var protocol = PluginProtocol()
    var handshake = RpcMessage.parse(protocol.handshake())
    protocol.accept_handshake(handshake_result(handshake.id))
    var register = RpcMessage.parse(protocol.registration_request())
    with assert_raises():
        protocol.accept_registration(
            invoke_result(register.id, JsonValue.object())
        )

    protocol = PluginProtocol()
    handshake = RpcMessage.parse(protocol.handshake())
    protocol.accept_handshake(handshake_result(handshake.id))
    register = RpcMessage.parse(protocol.registration_request())
    var invalid = PluginRegistration("bad", "1.0.0")
    invalid.tools.append(
        parse_json('{"name":"not-valid","description":"bad","inputSchema":{}}')
    )
    with assert_raises():
        protocol.accept_registration(registration_result(register.id, invalid))

    invalid = PluginRegistration("bad", "1.0.0")
    invalid.commands.append(parse_json('{"name":""}'))
    with assert_raises():
        _ = invalid.to_json()

    var normalized = PluginRegistration("normalized", "1.0.0")
    normalized.commands.append(parse_json('{"name":"hello"}'))
    assert_equal(
        normalized.to_json()
        .get("commands")
        .array_value[0]
        .get("name")
        .string_value,
        "/hello",
    )


def test_plugin_command_identity_and_token_validation() raises:
    assert_equal(normalize_plugin_command_name("hello"), "/hello")
    assert_equal(
        normalize_plugin_command_name("/Project:Review"),
        "/Project:Review",
    )
    assert_equal(plugin_command_key("MIXED"), "/mixed")
    for invalid in [
        "",
        "/",
        "//hello",
        " hello",
        "hello ",
        "hello world",
        "hello\tworld",
        "hello\nworld",
    ]:
        with assert_raises():
            _ = normalize_plugin_command_name(invalid)
    with assert_raises():
        _ = normalize_plugin_command_name(
            parse_json('"hel\\u0000lo"').string_value
        )
    with assert_raises():
        _ = normalize_plugin_command_name(
            parse_json('"hel\\u007flo"').string_value
        )
    with assert_raises():
        _ = normalize_plugin_command_name(
            parse_json('"hel\\u00a0lo"').string_value
        )

    var duplicate = PluginRegistration("duplicate", "1.0.0")
    duplicate.commands.append(JsonValue.string("/Hello"))
    duplicate.commands.append(JsonValue.string("hello"))
    with assert_raises():
        _ = duplicate.to_json()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
