"""Real subprocess check for examples/hello_plugin.mojo.

Build this file and pass the separately built example executable as argv[1].
It intentionally does not end in ``_test.mojo`` because the normal test loop
does not build example binaries first.
"""

from mochi.json import JsonValue, parse_json
from mochi.plugin import PluginClient, PluginExecutable
from std.sys import argv
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def main() raises:
    var arguments = argv()
    if len(arguments) != 2:
        raise Error("usage: plugin_sdk_e2e PATH_TO_HELLO_PLUGIN")

    var client = PluginClient.launch(
        PluginExecutable(String(arguments[1])), "plugin-sdk-e2e"
    )
    assert_true(client.is_ready())
    assert_equal(client.protocol.registration.value().name, "hello")
    assert_equal(client.protocol.registration.value().version, "1.0.0")

    var command_result = client.invoke("command", "/hello", JsonValue.object())
    assert_equal(
        command_result.get("llm_output").string_value, "Hello from Mojo"
    )
    assert_false(command_result.get("is_error").bool_value)

    with assert_raises():
        _ = client.invoke("tool", "missing", JsonValue.object())
    assert_true(client.is_ready())

    var tool_result = client.invoke(
        "tool", "echo", parse_json('{"text":"привет"}')
    )
    assert_equal(
        tool_result.get("llm_output").string_value, '{"text":"привет"}'
    )
    assert_false(tool_result.get("is_error").bool_value)

    client.shutdown()
    assert_false(client.is_ready())
