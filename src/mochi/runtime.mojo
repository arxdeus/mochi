"""Live, pure-Mojo OpenAI-compatible multi-turn agent runtime."""

from std.ffi import c_int, external_call

from mochi.json import JsonValue, serialize_json
from mochi.mcp import McpClient, StdioTransport, StreamableHttpTransport
from mochi.permissions import PermissionEffect, PermissionManager
from mochi.provider import (
    OpenAICompatibleProvider,
    ProviderResult,
    ProviderSpec,
    RetryState,
)
from mochi.plugin import PluginClient
from mochi.tools import (
    PreparedTool,
    RemoteToolMetadata,
    RemoteToolRouter,
    ToolRegistry,
    ToolResult,
)
from mochi.types import CancellationToken, Message, ToolCall, Usage


@fieldwise_init
struct ToolDefinition(Copyable, Movable):
    """OpenAI function-tool metadata. `parameters` is a JSON Schema object."""

    var name: String
    var description: String
    var parameters: JsonValue


@fieldwise_init
struct RuntimeResult(Copyable, Movable):
    var text: String
    var messages: List[Message]
    var usage: Usage
    var turns: Int
    var stop_reason: String
    var compactions: Int
    var retries: Int


struct Runtime:
    var provider: OpenAICompatibleProvider
    var tools: ToolRegistry
    var permissions: PermissionManager
    var remote: RemoteToolRouter
    var definitions: List[ToolDefinition]
    var messages: List[Message]
    var model: String
    var max_turns: Int
    var max_context_chars: Int
    var compact_keep: Int
    var compactions: Int
    var retries: Int
    var system_prompt: String
    var mcp_stdio_names: List[String]
    var mcp_stdio_clients: List[McpClient]
    var mcp_stdio_transports: List[StdioTransport]
    var mcp_http_names: List[String]
    var mcp_http_clients: List[McpClient]
    var mcp_http_transports: List[StreamableHttpTransport]
    var plugin_names: List[String]
    var plugin_clients: List[PluginClient]

    def __init__(
        out self,
        var provider: OpenAICompatibleProvider,
        var tools: ToolRegistry,
        var permissions: PermissionManager,
        var model: String,
        max_turns: Int = 50,
        max_context_chars: Int = 100000,
        compact_keep: Int = 12,
    ):
        self.provider = provider^
        self.tools = tools^
        self.permissions = permissions^
        self.remote = RemoteToolRouter()
        self.definitions = List[ToolDefinition]()
        self.messages = List[Message]()
        self.model = model^
        self.max_turns = max_turns
        self.max_context_chars = max_context_chars
        self.compact_keep = compact_keep
        self.compactions = 0
        self.retries = 0
        self.system_prompt = ""
        self.mcp_stdio_names = List[String]()
        self.mcp_stdio_clients = List[McpClient]()
        self.mcp_stdio_transports = List[StdioTransport]()
        self.mcp_http_names = List[String]()
        self.mcp_http_clients = List[McpClient]()
        self.mcp_http_transports = List[StreamableHttpTransport]()
        self.plugin_names = List[String]()
        self.plugin_clients = List[PluginClient]()

    def set_system_prompt(mut self, prompt: String):
        self.system_prompt = prompt

    def set_messages(mut self, messages: List[Message]):
        self.messages = messages.copy()

    def add_tool(mut self, var definition: ToolDefinition) raises:
        if self.tools.index_of(definition.name) < 0:
            raise Error("tool definition is not registered: " + definition.name)
        for existing in self.definitions:
            if existing.name == definition.name:
                raise Error("duplicate tool definition: " + definition.name)
        self.definitions.append(definition^)

    def add_remote_tools(
        mut self, protocol: String, endpoint: String, discovered: JsonValue
    ) raises:
        """Register MCP `tools/list` or plugin registration tool metadata."""
        if discovered.kind != JsonValue.ARRAY:
            raise Error("remote tools metadata must be an array")
        for item in discovered.array_value:
            if item.kind != JsonValue.OBJECT or not item.contains("name"):
                raise Error("remote tool metadata requires a name")
            var name = item.get("name").string_value
            var description = String("")
            if item.contains("description"):
                description = item.get("description").string_value
            var parameters = JsonValue.object()
            if item.contains("inputSchema"):
                parameters = item.get("inputSchema")
            elif item.contains("parameters"):
                parameters = item.get("parameters")
            if parameters.kind != JsonValue.OBJECT:
                raise Error("remote tool schema must be an object: " + name)
            var metadata = RemoteToolMetadata(
                protocol, endpoint, name, description, parameters^
            )
            self.tools.register_remote(metadata)
            self.remote.register(metadata)
            self.add_tool(ToolDefinition(name, description, metadata.parameters.copy()))

    def enqueue_remote_result(
        mut self, var name: String, var result: ToolResult
    ) raises:
        """Supply a fixture or an explicit result produced by a concrete client."""
        self.remote.enqueue_result(name^, result^)

    def remote_protocol(self, name: String) -> String:
        return self.remote.protocol_for(name)

    def remote_endpoint(self, name: String) -> String:
        return self.remote.endpoint_for(name)

    def take_remote_result(mut self, name: String) -> Optional[ToolResult]:
        return self.remote.take_queued(name)

    def append_tool_result(mut self, call: ToolCall, result: ToolResult):
        var message = Message("tool", result.content)
        message.tool_call_id = call.id
        message.name = call.name
        self.messages.append(message^)

    def attach_mcp_stdio(
        mut self,
        var name: String,
        var client: McpClient,
        var transport: StdioTransport,
    ):
        self.mcp_stdio_names.append(name^)
        self.mcp_stdio_clients.append(client^)
        self.mcp_stdio_transports.append(transport^)

    def attach_mcp_http(
        mut self,
        var name: String,
        var client: McpClient,
        var transport: StreamableHttpTransport,
    ):
        self.mcp_http_names.append(name^)
        self.mcp_http_clients.append(client^)
        self.mcp_http_transports.append(transport^)

    def attach_plugin(
        mut self, var name: String, var client: PluginClient
    ):
        self.plugin_names.append(name^)
        self.plugin_clients.append(client^)

    def shutdown_remotes(mut self):
        for i in range(len(self.mcp_stdio_transports)):
            self.mcp_stdio_transports[i].cancel()
        for i in range(len(self.mcp_http_transports)):
            try:
                self.mcp_http_transports[i].delete_session()
            except:
                pass
        for i in range(len(self.plugin_clients)):
            try:
                self.plugin_clients[i].shutdown()
            except:
                self.plugin_clients[i].cancel()

    def request_body(self) raises -> JsonValue:
        var request_messages = self.messages.copy()
        if self.system_prompt != "":
            request_messages.insert(0, Message("system", self.system_prompt))
        if self.provider.spec.responses_api:
            return build_responses_request_body(
                self.model, request_messages, self.definitions
            )
        return build_request_body(self.model, request_messages, self.definitions)

    def run(mut self, prompt: String, cancel: CancellationToken) -> RuntimeResult:
        self.messages.append(Message("user", prompt))
        var usage = Usage()
        var final_text = String("")
        var completed_turns = 0
        for turn in range(1, self.max_turns + 1):
            if cancel.is_cancelled():
                return self._result(final_text, usage, completed_turns, "cancelled")
            _ = self.compact_if_needed()
            var response: ProviderResult
            try:
                response = self._complete_with_retry(cancel)
            except error:
                if cancel.is_cancelled():
                    return self._result(final_text, usage, completed_turns, "cancelled")
                return self._provider_error(String(error), usage, completed_turns)
            usage.add(response.usage)
            completed_turns = turn
            self.messages.append(response.message.copy())
            if len(response.message.tool_calls) == 0:
                final_text = response.message.content
                var reason = response.stop_reason
                if reason == "" or reason == "stop":
                    reason = "end_turn"
                return self._result(final_text, usage, completed_turns, reason)
            for call in response.message.tool_calls:
                if cancel.is_cancelled():
                    return self._result(final_text, usage, completed_turns, "cancelled")
                self.dispatch(call, cancel)
        return self._result(final_text, usage, completed_turns, "max_turns")

    def _complete_with_retry(
        mut self, cancel: CancellationToken
    ) raises -> ProviderResult:
        var retry = RetryState(self.provider.max_retries())
        while True:
            cancel.check()
            try:
                return self.provider.complete_json(self.request_body())
            except error:
                var status = self.provider.last_http_status()
                var auth_failure = status == 401 or status == 403
                var retryable = status == 0 or RetryState.retryable_status(status)
                if auth_failure:
                    retryable = self.provider.recover_auth()
                if not retryable or not retry.can_retry():
                    raise error
                var delay = retry.next_delay_ms()
                self.retries += 1
                cancel.check()
                _sleep_ms(delay)

    def dispatch(mut self, call: ToolCall, cancel: CancellationToken):
        var content: String
        try:
            var prepared = self.tools.prepare(call.name, call.arguments)
            var decision = self.tools.authorize(prepared, self.permissions)
            if decision.effect != PermissionEffect.allow():
                var label = (
                    "denied"
                    if decision.effect == PermissionEffect.deny()
                    else "prompt"
                )
                content = "Permission " + label
                for scope in decision.scopes:
                    content += ": " + scope
            elif cancel.is_cancelled():
                content = "Error: operation cancelled"
            elif self.remote.is_remote(prepared.name):
                var queued = self.remote.take_queued(prepared.name)
                if queued:
                    content = queued.value().content
                else:
                    content = self._dispatch_remote(prepared)
            else:
                content = self.tools.execute(prepared).content
        except error:
            content = "Error: " + String(error)
        self.append_tool_result(call, ToolResult.success(content))

    def _dispatch_remote(mut self, prepared: PreparedTool) raises -> String:
        var protocol = self.remote.protocol_for(prepared.name)
        var endpoint = self.remote.endpoint_for(prepared.name)
        if protocol == "mcp":
            for i in range(len(self.mcp_stdio_names)):
                if self.mcp_stdio_names[i] == endpoint:
                    return serialize_json(
                        self.mcp_stdio_clients[i].call_tool(
                            self.mcp_stdio_transports[i],
                            prepared.name,
                            prepared.arguments.copy(),
                        )
                    )
            for i in range(len(self.mcp_http_names)):
                if self.mcp_http_names[i] == endpoint:
                    return serialize_json(
                        self.mcp_http_clients[i].call_tool(
                            self.mcp_http_transports[i],
                            prepared.name,
                            prepared.arguments.copy(),
                        )
                    )
        elif protocol == "plugin":
            for i in range(len(self.plugin_names)):
                if self.plugin_names[i] == endpoint:
                    return serialize_json(
                        self.plugin_clients[i].invoke(
                            "tool", prepared.name, prepared.arguments.copy()
                        )
                    )
        raise Error(
            "remote endpoint is not attached: " + protocol + ":" + endpoint
        )

    def context_chars(self) -> Int:
        var total = 0
        for message in self.messages:
            total += message.role.byte_length() + message.content.byte_length()
            for call in message.tool_calls:
                total += (
                    call.id.byte_length()
                    + call.name.byte_length()
                    + call.arguments.byte_length()
                )
        return total

    def compact_if_needed(mut self, force: Bool = False) -> Bool:
        if not force and self.context_chars() <= self.max_context_chars:
            return False
        if len(self.messages) <= self.compact_keep:
            return False
        var cut = len(self.messages) - self.compact_keep
        var summary = String("Compacted conversation summary:\n")
        for i in range(cut):
            if self.messages[i].content:
                summary += (
                    self.messages[i].role
                    + ": "
                    + _truncate(self.messages[i].content, 500)
                    + "\n"
                )
        summary = _tail(summary, 8000)
        var compacted = List[Message]()
        compacted.append(Message("system", summary^))
        for i in range(cut, len(self.messages)):
            compacted.append(self.messages[i].copy())
        self.messages = compacted^
        self.compactions += 1
        return True

    def _provider_error(
        mut self, error: String, usage: Usage, turns: Int
    ) -> RuntimeResult:
        var message = "Error: " + error
        self.messages.append(Message("assistant", message))
        return self._result(message^, usage, turns, "provider_error")

    def _result(
        self, text: String, usage: Usage, turns: Int, reason: String
    ) -> RuntimeResult:
        return RuntimeResult(
            text,
            self.messages.copy(),
            usage.copy(),
            turns,
            reason,
            self.compactions,
            self.retries,
        )


def build_request_body(
    model: String, messages: List[Message], definitions: List[ToolDefinition]
) raises -> JsonValue:
    """Build one OpenAI Chat Completions request from domain messages/tools."""
    var body = JsonValue.object()
    body.set("model", JsonValue.string(model))
    body.set("stream", JsonValue.boolean(True))
    var raw_messages = JsonValue.array()
    for message in messages:
        raw_messages.append(message_json(message))
    body.set("messages", raw_messages^)
    if len(definitions) > 0:
        var raw_tools = JsonValue.array()
        for definition in definitions:
            var function = JsonValue.object()
            function.set("name", JsonValue.string(definition.name))
            function.set("description", JsonValue.string(definition.description))
            function.set("parameters", definition.parameters.copy())
            var tool = JsonValue.object()
            tool.set("type", JsonValue.string("function"))
            tool.set("function", function^)
            raw_tools.append(tool^)
        body.set("tools", raw_tools^)
        body.set("tool_choice", JsonValue.string("auto"))
    return body^


def build_responses_request_body(
    model: String, messages: List[Message], definitions: List[ToolDefinition]
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
            var kind = "input_text"
            if message.role == "assistant":
                kind = "output_text"
            part.set("type", JsonValue.string(kind))
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
    if len(definitions) > 0:
        var tools = JsonValue.array()
        for definition in definitions:
            var tool = JsonValue.object()
            tool.set("type", JsonValue.string("function"))
            tool.set("name", JsonValue.string(definition.name))
            tool.set("description", JsonValue.string(definition.description))
            tool.set("parameters", definition.parameters.copy())
            tool.set("strict", JsonValue.boolean(False))
            tools.append(tool^)
        body.set("tools", tools^)
    return body^


def message_json(message: Message) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("role", JsonValue.string(message.role))
    value.set("content", JsonValue.string(message.content))
    if message.name != "":
        value.set("name", JsonValue.string(message.name))
    if message.tool_call_id != "":
        value.set("tool_call_id", JsonValue.string(message.tool_call_id))
    if len(message.tool_calls) > 0:
        var calls = JsonValue.array()
        for call in message.tool_calls:
            var function = JsonValue.object()
            function.set("name", JsonValue.string(call.name))
            function.set("arguments", JsonValue.string(call.arguments))
            var raw_call = JsonValue.object()
            raw_call.set("id", JsonValue.string(call.id))
            raw_call.set("type", JsonValue.string("function"))
            raw_call.set("function", function^)
            calls.append(raw_call^)
        value.set("tool_calls", calls^)
    return value^


def apply_scripted_response(
    mut messages: List[Message], mut usage: Usage, body: String
) raises -> String:
    """Apply an SSE response without transport; useful for deterministic tests."""
    var spec = ProviderSpec("scripted", "https://invalid.local")
    var provider = OpenAICompatibleProvider(spec^)
    var result = provider.parse_response_body(body)
    usage.add(result.usage)
    messages.append(result.message.copy())
    return result.stop_reason


def _sleep_ms(milliseconds: Int):
    if milliseconds > 0:
        _ = external_call["usleep", c_int](UInt32(milliseconds * 1000))


def _truncate(value: String, limit: Int) -> String:
    if value.byte_length() <= limit:
        return value
    var result = String("")
    for i in range(limit):
        result += String(value[byte=i])
    return result^


def _tail(value: String, limit: Int) -> String:
    if value.byte_length() <= limit:
        return value
    var result = String("")
    for i in range(value.byte_length() - limit, value.byte_length()):
        result += String(value[byte=i])
    return result^
