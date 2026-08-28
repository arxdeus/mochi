"""Minimal native Mojo plugin for Mochi.

Build with ``mojo build -I src examples/hello_plugin.mojo -o hello-plugin`` and
launch Mochi with ``--plugin ./hello-plugin``.
"""

from mochi.json import JsonValue, parse_json
from mochi.plugin import PluginRegistration
from mochi.plugin_sdk import PluginHandler, run_stdio


struct HelloPlugin(Movable, PluginHandler):
    def __init__(out self):
        pass

    def registration(self) raises -> PluginRegistration:
        var registration = PluginRegistration("hello", "1.0.0")
        registration.tools.append(
            parse_json(
                '{"name":"echo","description":"Echo JSON arguments",'
                '"schema":{"type":"object"}}'
            )
        )
        registration.commands.append(parse_json('{"name":"/hello"}'))
        registration.prompt_hints.append(
            JsonValue.string("A native Mojo hello plugin is available.")
        )
        return registration^

    def invoke(
        mut self, kind: String, name: String, var arguments: JsonValue
    ) raises -> JsonValue:
        if kind == "tool" and name == "echo":
            var result = JsonValue.object()
            result.set("llm_output", JsonValue.string(arguments.serialize()))
            result.set("is_error", JsonValue.boolean(False))
            return result^
        if kind == "command" and name == "/hello":
            var result = JsonValue.object()
            result.set("llm_output", JsonValue.string("Hello from Mojo"))
            result.set("is_error", JsonValue.boolean(False))
            return result^
        raise Error("unknown plugin target: " + kind + ":" + name)

    def shutdown(mut self) raises:
        pass


def main() raises:
    run_stdio(HelloPlugin())
