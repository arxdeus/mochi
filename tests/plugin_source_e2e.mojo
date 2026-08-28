"""Compile a real Mojo source plugin through the cache, then invoke it.

Usage: plugin_source_e2e SOURCE CACHE_DIR MOJO_COMPILER SDK_INCLUDE
"""

from mochi.json import parse_json
from mochi.plugin import PluginClient
from mochi.plugin_source import (
    PluginBuildOptions,
    prepare_plugin,
    rebuild_source_plugin,
)
from std.os import makedirs
from std.sys import argv
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def main() raises:
    var arguments = argv()
    if len(arguments) != 5:
        raise Error(
            "usage: plugin_source_e2e SOURCE CACHE_DIR MOJO_COMPILER SDK_INCLUDE"
        )
    var source = String(arguments[1])
    var work = String(arguments[2]) + "/work"
    makedirs(work, exist_ok=True)
    var source_copy = work + "/plugin.mojo"
    with open(source_copy, "w") as file:
        file.write(open(source, "r").read())
    var options = PluginBuildOptions(
        String(arguments[2]), String(arguments[3]), "0.1.0"
    )
    options.add_compiler_argument("-I")
    options.add_compiler_argument(String(arguments[4]))

    var first = prepare_plugin(source_copy, options)
    assert_true(first.source)
    assert_false(first.source.value().cache_hit)
    var second = prepare_plugin(source_copy, options)
    assert_true(second.source.value().cache_hit)
    assert_equal(first.executable.path, second.executable.path)

    var client = PluginClient.launch(second.executable.copy(), "source-e2e")
    var registration = client.protocol.registration.value().copy()
    second.source.value().validate_registration(
        registration.name, registration.version
    )
    assert_equal(registration.name, "hello")
    var result = client.invoke(
        "tool", "echo", parse_json('{"text":"привет из source cache"}')
    )
    assert_equal(
        result.get("llm_output").string_value,
        '{"text":"привет из source cache"}',
    )
    assert_false(result.get("is_error").bool_value)

    # A broken rebuild never touches the already connected generation.
    var broken = PluginBuildOptions(
        String(arguments[2]) + "/broken", "/bin/false", "0.1.0"
    )
    with assert_raises():
        _ = rebuild_source_plugin(second.source.value().copy(), broken)
    var still_live = client.invoke(
        "tool", "echo", parse_json('{"text":"last good"}')
    )
    assert_equal(
        still_live.get("llm_output").string_value, '{"text":"last good"}'
    )
    var generation_one = open(source_copy, "r").read()
    var generation_two = generation_one.replace(
        "Hello from Mojo", "Hello from Mojo generation two"
    )
    with open(source_copy, "w") as file:
        file.write(generation_two)
    var third = rebuild_source_plugin(second.source.value().copy(), options)
    assert_false(third.source.value().cache_hit)
    assert_true(
        third.source.value().build_hash
        != second.source.value().build_hash
    )
    var candidate = PluginClient.launch(third.executable.copy(), "source-e2e")
    var upgraded = candidate.invoke("command", "/hello", parse_json("{}"))
    assert_equal(
        upgraded.get("llm_output").string_value,
        "Hello from Mojo generation two",
    )
    candidate.shutdown()
    client.shutdown()
