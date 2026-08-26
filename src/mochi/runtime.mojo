"""Live, pure-Mojo OpenAI-compatible multi-turn agent runtime."""

from std.ffi import c_int, external_call

from mochi.domain import (
    ContentBlock,
    DomainMessage,
    DomainProviderEvent,
    Model,
    ModelFamily,
    ModelInfo,
    ModelPricing,
    ModelTier,
    Role,
    StreamResponse,
    ThinkingSupport,
)
from mochi.json import JsonValue, parse_json, serialize_json
from mochi.session import Session, message_to_json
from mochi.mcp import McpClient, McpOAuthState, StdioTransport, StreamableHttpTransport
from mochi.permissions import (
    PermissionAnswer,
    PermissionEffect,
    PermissionManager,
)
from mochi.provider import (
    OpenAICompatibleProvider,
    ProductionProvider,
    ProviderResult,
    builtin_model_catalog,
    find_model_info,
    ProviderSpec,
    RetryState,
)
from mochi.provider_contract import (
    ProviderEventSink,
    ProviderRequest,
    RequestOptions,
    ThinkingConfig,
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
struct PendingPermission(Copyable, Movable):
    var tool_call_id: String
    var tool: String
    var arguments: JsonValue
    var scopes: List[String]


struct RuntimeEventSink(ProviderEventSink, Copyable, Movable):
    var events: List[DomainProviderEvent]

    def __init__(out self):
        self.events = List[DomainProviderEvent]()

    def emit(mut self, event: DomainProviderEvent) raises:
        self.events.append(event.copy())


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
    var provider: ProductionProvider
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
    var options: RequestOptions
    var workflow: Bool
    var permission_answers: List[PermissionAnswer]
    var pending_permissions: List[PendingPermission]
    var queued_inputs: List[String]
    var queued_compactions: Int
    var mcp_stdio_names: List[String]
    var mcp_stdio_clients: List[McpClient]
    var mcp_stdio_transports: List[StdioTransport]
    var mcp_stdio_enabled: List[Bool]
    var mcp_http_names: List[String]
    var mcp_http_clients: List[McpClient]
    var mcp_http_transports: List[StreamableHttpTransport]
    var mcp_http_authenticated: List[Bool]
    var mcp_http_enabled: List[Bool]
    var mcp_http_errors: List[String]
    var plugin_names: List[String]
    var plugin_clients: List[PluginClient]
    var subagent_ids: List[String]
    var subagent_names: List[String]
    var subagent_models: List[String]
    var subagent_messages: List[List[Message]]

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
        var info = find_model_info(model)
        self.provider = ProductionProvider(provider^, info)
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
        self.options = RequestOptions()
        self.workflow = False
        self.permission_answers = List[PermissionAnswer]()
        self.pending_permissions = List[PendingPermission]()
        self.queued_inputs = List[String]()
        self.queued_compactions = 0
        self.mcp_stdio_names = List[String]()
        self.mcp_stdio_clients = List[McpClient]()
        self.mcp_stdio_transports = List[StdioTransport]()
        self.mcp_stdio_enabled = List[Bool]()
        self.mcp_http_names = List[String]()
        self.mcp_http_clients = List[McpClient]()
        self.mcp_http_transports = List[StreamableHttpTransport]()
        self.mcp_http_authenticated = List[Bool]()
        self.mcp_http_enabled = List[Bool]()
        self.mcp_http_errors = List[String]()
        self.plugin_names = List[String]()
        self.plugin_clients = List[PluginClient]()
        self.subagent_ids = List[String]()
        self.subagent_names = List[String]()
        self.subagent_models = List[String]()
        self.subagent_messages = List[List[Message]]()

    def __init__(
        out self,
        var provider: ProductionProvider,
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
        self.options = RequestOptions()
        self.workflow = False
        self.permission_answers = List[PermissionAnswer]()
        self.pending_permissions = List[PendingPermission]()
        self.queued_inputs = List[String]()
        self.queued_compactions = 0
        self.mcp_stdio_names = List[String]()
        self.mcp_stdio_clients = List[McpClient]()
        self.mcp_stdio_transports = List[StdioTransport]()
        self.mcp_stdio_enabled = List[Bool]()
        self.mcp_http_names = List[String]()
        self.mcp_http_clients = List[McpClient]()
        self.mcp_http_transports = List[StreamableHttpTransport]()
        self.mcp_http_authenticated = List[Bool]()
        self.mcp_http_enabled = List[Bool]()
        self.mcp_http_errors = List[String]()
        self.plugin_names = List[String]()
        self.plugin_clients = List[PluginClient]()
        self.subagent_ids = List[String]()
        self.subagent_names = List[String]()
        self.subagent_models = List[String]()
        self.subagent_messages = List[List[Message]]()

    def set_system_prompt(mut self, prompt: String):
        self.system_prompt = prompt

    def restore_modes(mut self, meta: JsonValue):
        if meta.kind != JsonValue.OBJECT:
            return
        try:
            if meta.contains("thinking"):
                var thinking = meta.get("thinking")
                if thinking.kind == JsonValue.STRING:
                    _ = self.set_thinking(thinking.string_value)
                elif thinking.kind == JsonValue.OBJECT and thinking.contains("kind"):
                    var kind = thinking.get("kind").string_value
                    if kind == "budget" and thinking.contains("tokens"):
                        _ = self.set_thinking(String(thinking.get("tokens").int_value))
                    elif kind == "effort" and thinking.contains("level"):
                        _ = self.set_thinking(thinking.get("level").string_value)
                    else:
                        _ = self.set_thinking(kind)
            if meta.contains("fast") and meta.get("fast").kind == JsonValue.BOOL:
                _ = self.set_fast(meta.get("fast").bool_value)
            if meta.contains("workflow") and meta.get("workflow").kind == JsonValue.BOOL:
                self.workflow = meta.get("workflow").bool_value
                self.tools.set_workflow(self.workflow)
        except:
            pass

    def save_modes(self, meta: JsonValue) -> JsonValue:
        var result = meta.copy()
        if result.kind != JsonValue.OBJECT:
            result = JsonValue.object()
        try:
            result.set(
                "thinking", JsonValue.string(self.options.thinking.display())
            )
            result.set("fast", JsonValue.boolean(self.options.fast))
            result.set("workflow", JsonValue.boolean(self.workflow))
        except:
            pass
        return result^

    def set_thinking(mut self, input: String) -> Bool:
        var model = _runtime_model(
            self.model, self.provider.name, self.provider.model_info
        )
        if not model.supports_thinking():
            return False
        var parsed = ThinkingConfig.parse(input, self.options.thinking)
        if not parsed:
            return False
        self.options.thinking = parsed.value().copy()
        return True

    def set_fast(mut self, enabled: Bool) -> Bool:
        var model = _runtime_model(
            self.model, self.provider.name, self.provider.model_info
        )
        if enabled and not model.supports_fast():
            return False
        self.options.fast = enabled
        return True

    def toggle_workflow(mut self) -> Bool:
        self.workflow = not self.workflow
        self.tools.set_workflow(self.workflow)
        return self.workflow

    def set_messages(mut self, messages: List[Message]):
        self.messages = messages.copy()

    def subagent_metadata(self) raises -> JsonValue:
        var result = JsonValue.array()
        for i in range(len(self.subagent_ids)):
            var item = JsonValue.object()
            item.set("tool_use_id", JsonValue.string(self.subagent_ids[i]))
            item.set("name", JsonValue.string(self.subagent_names[i]))
            item.set("model", JsonValue.string(self.subagent_models[i]))
            result.append(item^)
        return result^

    def persist_subagents(mut self, mut session: Session) raises:
        session.subagents = self.subagent_metadata()
        session.subagent_ids.clear()
        session.subagent_messages.clear()
        for i in range(len(self.subagent_ids)):
            for message in self.subagent_messages[i]:
                session.add_subagent_message(
                    self.subagent_ids[i], message_to_json(message)
                )

    def ask_btw(mut self, question: String, session_id: String = "") -> String:
        comptime reminder = "<system-reminder>\nThis is a side question. Answer it directly in a single response.\n- You have NO tools: you cannot read files, run commands, or take any action.\n- One-off response: there are no follow-up turns.\n- Answer ONLY from the existing conversation context.\n- Never say \"Let me...\", \"I'll now...\", or promise any action.\n- If you don't know, say so; do not offer to look it up.\n</system-reminder>"
        var messages = self.messages.copy()
        messages.append(Message("user", reminder + "\n\n" + question))
        var model = _runtime_model(
            self.model, self.provider.name, self.provider.model_info
        )
        try:
            var request = ProviderRequest(
                model^,
                CancellationToken(),
                _domain_messages(messages),
                self.system_prompt,
                JsonValue.array(),
                RequestOptions(),
                Optional(session_id) if session_id != "" else None,
            )
            var sink = RuntimeEventSink()
            var result = _legacy_result(
                self.provider.stream_message(request^, sink)
            )
            return result.message.content
        except error:
            return "Error: " + String(error)

    def answer_next_permission(mut self, answer: PermissionAnswer):
        self.permission_answers.append(answer)

    def take_pending_permission(mut self) -> Optional[PendingPermission]:
        if len(self.pending_permissions) == 0:
            return None
        return Optional(self.pending_permissions.pop(0))

    def resolve_permission(
        mut self, permission: PendingPermission, answer: PermissionAnswer
    ) -> String:
        self.permissions.apply_decision(
            permission.tool, permission.scopes, answer
        )
        var content = String("Permission denied")
        if answer.is_allow():
            try:
                var permission_cancel = CancellationToken()
                content = self._execute_prepared(
                    PreparedTool(
                        permission.tool, permission.arguments.copy()
                    ),
                    permission.tool_call_id,
                    permission_cancel^,
                )
            except error:
                content = "Error: " + String(error)
        for i in range(len(self.messages) - 1, -1, -1):
            if self.messages[i].tool_call_id == permission.tool_call_id:
                self.messages[i].content = content
                break
        return content^

    def queue_input(mut self, input: String):
        self.queued_inputs.append(input)

    def queue_compaction(mut self):
        self.queued_compactions += 1

    def queued_input_count(self) -> Int:
        return len(self.queued_inputs)

    def queued_compaction_count(self) -> Int:
        return self.queued_compactions

    def consume_queued_command(mut self) -> Bool:
        if self.queued_compactions > 0:
            self.queued_compactions -= 1
            return self.compact_if_needed(force=True)
        return self.consume_queued_input()

    def consume_queued_input(mut self) -> Bool:
        if len(self.queued_inputs) == 0:
            return False
        var input = self.queued_inputs.pop(0)
        self.messages.append(
            Message(
                "user",
                "<user-interrupt>\nThe user sent a new message while you were working. Address it and continue.\n\n"
                + input
                + "\n</user-interrupt>",
            )
        )
        return True

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
        self.mcp_stdio_enabled.append(True)

    def attach_mcp_http(
        mut self,
        var name: String,
        var client: McpClient,
        var transport: StreamableHttpTransport,
    ):
        self.mcp_http_authenticated.append(transport.bearer_token != "")
        self.mcp_http_names.append(name^)
        self.mcp_http_clients.append(client^)
        self.mcp_http_transports.append(transport^)
        self.mcp_http_enabled.append(True)
        self.mcp_http_errors.append("")

    def attach_plugin(
        mut self, var name: String, var client: PluginClient
    ):
        self.plugin_names.append(name^)
        self.plugin_clients.append(client^)

    def plugin_command_names(self) raises -> List[String]:
        var result = List[String]()
        for i in range(len(self.plugin_clients)):
            if not self.plugin_clients[i].protocol.registration:
                continue
            var commands = self.plugin_clients[i].protocol.registration.value().commands.copy()
            for item in commands.array_value:
                if item.kind == JsonValue.STRING:
                    result.append(item.string_value)
                elif item.kind == JsonValue.OBJECT and item.contains("name"):
                    result.append(item.get("name").string_value)
        return result^

    def invoke_plugin_command(
        mut self, name: String, arguments: String
    ) raises -> String:
        for i in range(len(self.plugin_clients)):
            if not self.plugin_clients[i].protocol.registration:
                continue
            var commands = self.plugin_clients[i].protocol.registration.value().commands.copy()
            for item in commands.array_value:
                var command = String("")
                if item.kind == JsonValue.STRING:
                    command = item.string_value
                elif item.kind == JsonValue.OBJECT and item.contains("name"):
                    command = item.get("name").string_value
                if command == name:
                    var input = JsonValue.object()
                    input.set("arguments", JsonValue.string(arguments))
                    return serialize_json(
                        self.plugin_clients[i].invoke("command", name, input^)
                    )
        raise Error("unknown extension command: " + name)

    def plugin_prompt_hints(self) -> String:
        var result = String("")
        for i in range(len(self.plugin_clients)):
            if not self.plugin_clients[i].protocol.registration:
                continue
            var hints = self.plugin_clients[i].protocol.registration.value().prompt_hints.copy()
            for hint in hints.array_value:
                if hint.kind == JsonValue.STRING:
                    if result != "":
                        result += "\n"
                    result += hint.string_value
        return result^

    def apply_plugin_prompt_hints(mut self):
        var hints = self.plugin_prompt_hints()
        if hints != "":
            self.system_prompt += "\n\n" + hints

    def reload_plugins(mut self) raises -> Int:
        for i in range(len(self.plugin_names)):
            var old_name = self.plugin_names[i]
            self._remove_remote_endpoint("plugin", old_name)
            self.plugin_clients[i].reload()
            var registration = self.plugin_clients[i].protocol.registration.value().copy()
            self.plugin_names[i] = registration.name
            self.add_remote_tools(
                "plugin", registration.name, registration.tools.copy()
            )
        return len(self.plugin_names)

    def remote_status_lines(self) -> List[String]:
        var lines = List[String]()
        for i in range(len(self.mcp_stdio_names)):
            var status = "disabled"
            if self.mcp_stdio_enabled[i]:
                status = (
                    "running"
                    if self.mcp_stdio_clients[i].session.initialized
                    else "connecting"
                )
            lines.append(
                self.mcp_stdio_names[i] + " · stdio · " + status
            )
        for i in range(len(self.mcp_http_names)):
            var status = "disabled"
            if self.mcp_http_enabled[i]:
                status = "connecting"
            if self.mcp_http_enabled[i] and self.mcp_http_clients[i].session.initialized:
                status = "running"
                if self.mcp_http_authenticated[i]:
                    status += " · authenticated"
            if self.mcp_http_enabled[i] and self.mcp_http_errors[i] != "":
                status = self.mcp_http_errors[i]
            lines.append(
                self.mcp_http_names[i] + " · http · " + status
            )
        for name in self.plugin_names:
            lines.append(name + " · executable extension · running")
        return lines^

    def mcp_picker_items(self) -> String:
        var result = String("")
        for i in range(len(self.mcp_stdio_names)):
            if result != "":
                result += "\n"
            result += ("1:" if self.mcp_stdio_enabled[i] else "0:") + self.mcp_stdio_names[i]
        for i in range(len(self.mcp_http_names)):
            if result != "":
                result += "\n"
            result += ("1:" if self.mcp_http_enabled[i] else "0:") + self.mcp_http_names[i]
        return result^

    def set_mcp_enabled(mut self, name: String, enabled: Bool) -> Bool:
        for i in range(len(self.mcp_stdio_names)):
            if self.mcp_stdio_names[i] == name:
                self.mcp_stdio_enabled[i] = enabled
                return True
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] == name:
                self.mcp_http_enabled[i] = enabled
                return True
        return False

    def mcp_http_url(self, name: String) -> Optional[String]:
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] == name:
                return Optional(self.mcp_http_transports[i].url.copy())
        return None

    def apply_mcp_oauth(mut self, name: String, oauth: McpOAuthState) -> Bool:
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] == name:
                self.mcp_http_transports[i].apply_oauth(oauth)
                self.mcp_http_authenticated[i] = True
                self.mcp_http_errors[i] = ""
                return True
        return False

    def mark_mcp_http_error(mut self, name: String, error: String) -> Bool:
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] == name:
                self.mcp_http_errors[i] = error
                self.mcp_http_clients[i].session.initialized = False
                return True
        return False

    def reconnect_mcp_http(mut self, name: String) raises -> Int:
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] != name or not self.mcp_http_enabled[i]:
                continue
            self._remove_remote_endpoint("mcp", name)
            self.mcp_http_transports[i].session_id = ""
            self.mcp_http_clients[i] = McpClient(name)
            _ = self.mcp_http_clients[i].initialize(self.mcp_http_transports[i])
            var discovered = self.mcp_http_clients[i].list_tools(
                self.mcp_http_transports[i]
            )
            self.add_remote_tools("mcp", name, _json_values(discovered))
            self.mcp_http_errors[i] = ""
            return len(discovered)
        raise Error("MCP HTTP server is missing or disabled: " + name)

    def _remove_remote_endpoint(mut self, protocol: String, endpoint: String):
        self.remote.remove_endpoint(protocol, endpoint)
        self.tools.remove_owner(protocol + ":" + endpoint)
        for i in range(len(self.definitions) - 1, -1, -1):
            var name = self.definitions[i].name
            if not self.remote.is_remote(name) and self.tools.index_of(name) < 0:
                _ = self.definitions.pop(i)

    def clear_mcp_oauth(mut self, name: String) -> Bool:
        for i in range(len(self.mcp_http_names)):
            if self.mcp_http_names[i] == name:
                self.mcp_http_transports[i].clear_bearer_token()
                self.mcp_http_authenticated[i] = False
                self.mcp_http_errors[i] = "needs auth"
                return True
        return False

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
        if self.provider.uses_responses_api():
            return build_responses_request_body(
                self.model, request_messages, self.definitions
            )
        return build_request_body(self.model, request_messages, self.definitions)

    def run(mut self, prompt: String, cancel: CancellationToken) -> RuntimeResult:
        self.messages.append(Message("user", prompt))
        return self._run_turns(cancel.copy())

    def resume(mut self, cancel: CancellationToken) -> RuntimeResult:
        return self._run_turns(cancel.copy())

    def _run_turns(mut self, cancel: CancellationToken) -> RuntimeResult:
        var usage = Usage()
        var final_text = String("")
        var completed_turns = 0
        for turn in range(1, self.max_turns + 1):
            if cancel.is_cancelled():
                return self._result(final_text, usage, completed_turns, "cancelled")
            _ = self.compact_if_needed()
            _ = self.consume_queued_command()
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
                if len(self.pending_permissions) > 0:
                    return self._result(
                        final_text, usage, completed_turns, "permission"
                    )
        return self._result(final_text, usage, completed_turns, "max_turns")

    def _complete_with_retry(
        mut self, cancel: CancellationToken
    ) raises -> ProviderResult:
        var retry = RetryState(self.provider.max_retries)
        while True:
            cancel.check()
            try:
                var request = ProviderRequest(
                    _runtime_model(
                        self.model,
                        self.provider.name,
                        self.provider.model_info,
                    ),
                    cancel.copy(),
                    _domain_messages(self.messages),
                    self.system_prompt,
                    _contract_tools(self.definitions),
                    self.options.clamped(
                        _runtime_model(
                            self.model,
                            self.provider.name,
                            self.provider.model_info,
                        )
                    ),
                )
                var sink = RuntimeEventSink()
                return _legacy_result(
                    self.provider.stream_message(request^, sink)
                )
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
            if decision.effect == PermissionEffect.prompt():
                if len(self.permission_answers) == 0:
                    self.pending_permissions.append(
                          PendingPermission(
                              call.id,
                              prepared.name,
                              prepared.arguments.copy(),
                              decision.scopes.copy(),
                          )

                    )
                    content = "Permission prompt"
                    for scope in decision.scopes:
                        content += ": " + scope
                else:
                    var answer = self.permission_answers.pop(0)
                    self.permissions.apply_decision(
                        prepared.name, decision.scopes, answer
                    )
                    if answer.is_allow():
                        content = self._execute_prepared(prepared, call.id, cancel)
                    else:
                        content = "Permission denied"
                        for scope in decision.scopes:
                            content += ": " + scope
            elif decision.effect == PermissionEffect.deny():
                content = "Permission denied"
                for scope in decision.scopes:
                    content += ": " + scope
            elif cancel.is_cancelled():
                content = "Error: operation cancelled"
            else:
                content = self._execute_prepared(prepared, call.id, cancel)
        except error:
            content = "Error: " + String(error)
        self.append_tool_result(call, ToolResult.success(content))

    def _execute_prepared(
        mut self,
        prepared: PreparedTool,
        tool_call_id: String,
        cancel: CancellationToken,
    ) raises -> String:
        if prepared.name == "task":
            return self._run_subagent(prepared, tool_call_id, cancel)
        if self.remote.is_remote(prepared.name):
            var queued = self.remote.take_queued(prepared.name)
            if queued:
                return queued.value().content
            return self._dispatch_remote(prepared)
        return self.tools.execute(prepared).content

    def _run_subagent(
        mut self,
        prepared: PreparedTool,
        tool_call_id: String,
        cancel: CancellationToken,
    ) raises -> String:
        if not self.workflow:
            raise Error("subagents require workflow mode")
        if len(self.subagent_ids) >= self.tools.max_subagents:
            raise Error("subagent limit exceeded")
        var prompt = prepared.arguments.get("prompt").string_value
        var name = String("task")
        if prepared.arguments.contains("description"):
            name = prepared.arguments.get("description").string_value
        var child_tools = self.tools.copy()
        child_tools.set_workflow(False)
        var child_model = self.model
        if prepared.arguments.contains("model_tier"):
            var requested = prepared.arguments.get("model_tier").string_value
            var target = ModelTier.medium()
            if requested == "weak":
                target = ModelTier.weak()
            elif requested == "strong":
                target = ModelTier.strong()
            elif requested != "medium":
                raise Error("unknown model tier: " + requested)
            var current = self.provider.model_info.tier.value().tag if self.provider.model_info.tier else ModelTier.MEDIUM
            var effective = min(current, target.tag)
            for candidate in builtin_model_catalog():
                if candidate.tier and candidate.tier.value().tag == effective:
                    child_model = candidate.id
                    break
        var child_provider = self.provider.clone_for_child()
        child_provider.set_model_info(find_model_info(child_model))
        var child = Runtime(
            child_provider^,
            child_tools^,
            self.permissions.copy(),
            child_model,
            max_turns=self.max_turns,
            max_context_chars=self.max_context_chars,
            compact_keep=self.compact_keep,
        )
        child.system_prompt = self.system_prompt
        if prepared.arguments.contains("subagent_type"):
            var subagent_type = prepared.arguments.get("subagent_type").string_value
            if subagent_type != "research" and subagent_type != "general":
                raise Error("unknown subagent type: " + subagent_type)
            if subagent_type == "research":
                child.system_prompt += "\nYou are a read-only research subagent. Do not modify files or run mutating commands."
        for definition in self.definitions:
            if definition.name != "task":
                child.definitions.append(definition.copy())
        var structured = prepared.arguments.contains("output_schema")
        if structured:
            prompt += "\n\nReturn only a JSON object matching the requested output schema."
        var result = child.run(prompt, cancel)
        var retries = 0
        while result.stop_reason != "provider_error" and result.stop_reason != "cancelled" and retries < 2:
            if structured:
                try:
                    var output = parse_json(result.text)
                    _validate_json_schema(output, prepared.arguments.get("output_schema"))
                    break
                except:
                    retries += 1
                    result = child.run(
                        "Your result did not match the required JSON schema. Return only a valid matching JSON object.",
                        cancel,
                    )
            elif result.text == "":
                retries += 1
                result = child.run(
                    "You finished without a summary. Reply with a concise summary.",
                    cancel,
                )
            else:
                break
        self.subagent_ids.append(tool_call_id)
        self.subagent_names.append(name^)
        self.subagent_models.append(child_model)
        self.subagent_messages.append(result.messages.copy())
        if result.stop_reason == "provider_error" or result.stop_reason == "cancelled":
            raise Error("sub-agent " + result.stop_reason + ": " + result.text)
        if structured:
            try:
                var output = parse_json(result.text)
                _validate_json_schema(output, prepared.arguments.get("output_schema"))
                return serialize_json(output)
            except error:
                raise Error("subagent result does not match output_schema: " + String(error))
        if result.text == "":
            raise Error("subagent finished without providing a summary")
        return result.text

    def _dispatch_remote(mut self, prepared: PreparedTool) raises -> String:
        var protocol = self.remote.protocol_for(prepared.name)
        var endpoint = self.remote.endpoint_for(prepared.name)
        if protocol == "mcp":
            for i in range(len(self.mcp_stdio_names)):
                if self.mcp_stdio_names[i] == endpoint and self.mcp_stdio_enabled[i]:
                    return serialize_json(
                        self.mcp_stdio_clients[i].call_tool(
                            self.mcp_stdio_transports[i],
                            prepared.name,
                            prepared.arguments.copy(),
                        )
                    )
            for i in range(len(self.mcp_http_names)):
                if self.mcp_http_names[i] == endpoint and self.mcp_http_enabled[i]:
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


def _validate_json_schema(value: JsonValue, schema: JsonValue) raises:
    if schema.kind != JsonValue.OBJECT:
        raise Error("output_schema must be an object")
    var kind = String("")
    if schema.contains("type"):
        kind = schema.get("type").string_value
    if kind == "object" and value.kind != JsonValue.OBJECT:
        raise Error("expected object")
    if kind == "array" and value.kind != JsonValue.ARRAY:
        raise Error("expected array")
    if kind == "string" and value.kind != JsonValue.STRING:
        raise Error("expected string")
    if kind == "integer" and value.kind != JsonValue.INT:
        raise Error("expected integer")
    if kind == "boolean" and value.kind != JsonValue.BOOL:
        raise Error("expected boolean")
    if schema.contains("required"):
        if value.kind != JsonValue.OBJECT:
            raise Error("required fields need an object")
        for required in schema.get("required").array_value:
            if not value.contains(required.string_value):
                raise Error("missing required field: " + required.string_value)
    if schema.contains("properties") and value.kind == JsonValue.OBJECT:
        var properties = schema.get("properties")
        for i in range(len(properties.object_keys)):
            var key = properties.object_keys[i]
            if value.contains(key):
                _validate_json_schema(
                    value.get(key), properties.object_values[i]
                )
    if schema.contains("items") and value.kind == JsonValue.ARRAY:
        var items = schema.get("items")
        for item in value.array_value:
            _validate_json_schema(item, items)


def _runtime_model(id: String, provider: String, info: ModelInfo) -> Model:
    var tier = info.tier.value().copy() if info.tier else ModelTier.medium()
    var thinking = ThinkingSupport.no()
    if info.supports_thinking and info.supports_thinking.value():
        thinking = ThinkingSupport.yes()
    var pricing = info.pricing.value().copy() if info.pricing else ModelPricing()
    var context_window = info.context_window.value() if info.context_window else 100000
    return Model(
        id,
        provider,
        tier^,
        ModelFamily.generic(),
        thinking^,
        info.supports_vision,
        pricing^,
        info.max_output_tokens,
        context_window,
    )


def _domain_messages(messages: List[Message]) raises -> List[DomainMessage]:
    var result = List[DomainMessage]()
    for legacy in messages:
        var message = (
            DomainMessage.assistant(legacy.content)
            if legacy.role == "assistant"
            else DomainMessage.user(legacy.content)
        )
        if legacy.role == "tool":
            message = DomainMessage(Role.user())
            message.add_block(
                ContentBlock.tool_result(legacy.tool_call_id, legacy.content)
            )
        for call in legacy.tool_calls:
            var input = JsonValue.object()
            if call.arguments != "":
                input = parse_json(call.arguments)
            message.add_block(ContentBlock.tool_use(call.id, call.name, input^))
        result.append(message^)
    return result^


def _json_values(values: List[JsonValue]) raises -> JsonValue:
    var result = JsonValue.array()
    for value in values:
        result.append(value.copy())
    return result^


def _contract_tools(definitions: List[ToolDefinition]) raises -> JsonValue:
    var tools = JsonValue.array()
    for definition in definitions:
        var function = JsonValue.object()
        function.set("name", JsonValue.string(definition.name))
        function.set("description", JsonValue.string(definition.description))
        function.set("parameters", definition.parameters.copy())
        var tool = JsonValue.object()
        tool.set("type", JsonValue.string("function"))
        tool.set("function", function^)
        tools.append(tool^)
    return tools^


def _legacy_result(response: StreamResponse) raises -> ProviderResult:
    var message = Message("assistant", "")
    for block in response.message.content:
        if block.is_text():
            message.content += block.text
        elif block.is_tool_use():
            message.tool_calls.append(
                ToolCall(block.id, block.name, serialize_json(block.input))
            )
    var usage = Usage()
    usage.input_tokens = response.usage.input_tokens()
    usage.output_tokens = response.usage.output
    var reason = String("")
    if response.stop_reason:
        var stop = response.stop_reason.value().copy()
        if stop.is_tool_use():
            reason = "tool_calls"
        elif stop.is_max_tokens():
            reason = "length"
        else:
            reason = "stop"
    var result = ProviderResult()
    result.message = message^
    result.usage = usage^
    result.stop_reason = reason
    return result^


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
