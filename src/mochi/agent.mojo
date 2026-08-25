"""Provider-neutral pure Mojo agent state machine."""

from mochi.permissions import PermissionEffect, PermissionManager
from mochi.tools import ToolRegistry
from mochi.types import CancellationToken, Message, ProviderEvent, ToolCall, Usage


struct ScriptedProvider(Copyable, Movable):
    """Deterministic transport adapter: each turn is a stream of events."""

    var turns: List[List[ProviderEvent]]
    var position: Int

    def __init__(out self):
        self.turns = List[List[ProviderEvent]]()
        self.position = 0

    def add_turn(mut self, var events: List[ProviderEvent]):
        self.turns.append(events^)

    def next(mut self) raises -> List[ProviderEvent]:
        if self.position >= len(self.turns):
            raise Error("scripted provider exhausted")
        var events = self.turns[self.position].copy()
        self.position += 1
        return events^


@fieldwise_init
struct AgentResult(Copyable, Movable):
    var text: String
    var messages: List[Message]
    var usage: Usage
    var turns: Int
    var stop_reason: String
    var compactions: Int


struct _TurnAccumulator(Copyable, Movable):
    var text: String
    var calls: List[ToolCall]
    var usage: Usage
    var stop_reason: String

    def __init__(out self):
        self.text = ""
        self.calls = List[ToolCall]()
        self.usage = Usage()
        self.stop_reason = ""

    def add_call_delta(mut self, delta: ToolCall):
        """Merge partial calls by id; name and arguments are streamed fragments."""
        for i in range(len(self.calls)):
            if self.calls[i].id == delta.id:
                self.calls[i].name += delta.name
                self.calls[i].arguments += delta.arguments
                return
        self.calls.append(delta.copy())

    def consume(mut self, event: ProviderEvent):
        if event.kind == "text_delta":
            self.text += event.text
        elif event.kind == "tool_call_delta" and event.tool_call:
            self.add_call_delta(event.tool_call.value())
        elif event.kind == "usage":
            self.usage.add(event.usage)
        elif event.kind == "done":
            self.stop_reason = event.stop_reason


struct Agent(Copyable, Movable):
    var provider: ScriptedProvider
    var tools: ToolRegistry
    var permissions: PermissionManager
    var messages: List[Message]
    var max_turns: Int
    var max_context_chars: Int
    var compact_keep: Int
    var compactions: Int

    def __init__(
        out self,
        var provider: ScriptedProvider,
        var tools: ToolRegistry,
        var permissions: PermissionManager,
        max_turns: Int = 50,
        max_context_chars: Int = 100000,
        compact_keep: Int = 12,
    ):
        self.provider = provider^
        self.tools = tools^
        self.permissions = permissions^
        self.messages = List[Message]()
        self.max_turns = max_turns
        self.max_context_chars = max_context_chars
        self.compact_keep = compact_keep
        self.compactions = 0

    def run(mut self, prompt: String, cancel: CancellationToken) -> AgentResult:
        self.messages.append(Message("user", prompt))
        var usage = Usage()
        var final_text = String("")
        var completed_turns = 0
        for turn in range(1, self.max_turns + 1):
            if cancel.is_cancelled():
                return self._result(final_text, usage, completed_turns, "cancelled")
            _ = self.compact_if_needed()
            var events: List[ProviderEvent]
            try:
                events = self.provider.next()
            except error:
                self.messages.append(Message("assistant", "Error: " + String(error)))
                return self._result(final_text, usage, completed_turns, "provider_error")
            var accumulator = _TurnAccumulator()
            for event in events:
                if cancel.is_cancelled():
                    return self._result(final_text, usage, completed_turns, "cancelled")
                accumulator.consume(event)
            usage.add(accumulator.usage)
            completed_turns = turn
            var assistant = Message("assistant", accumulator.text)
            for call in accumulator.calls:
                assistant.add_tool_call(call.copy())
            self.messages.append(assistant^)
            if len(accumulator.calls) == 0:
                final_text = accumulator.text
                var reason = accumulator.stop_reason
                if reason == "stop":
                    reason = "end_turn"
                if reason == "":
                    reason = "end_turn"
                return self._result(final_text, usage, completed_turns, reason)
            for call in accumulator.calls:
                if cancel.is_cancelled():
                    return self._result(final_text, usage, completed_turns, "cancelled")
                self._execute_call(call, cancel)
        return self._result(final_text, usage, completed_turns, "max_turns")

    def _execute_call(mut self, call: ToolCall, cancel: CancellationToken):
        var content: String
        try:
            var prepared = self.tools.prepare(call.name, call.arguments)
            var decision = self.tools.authorize(prepared, self.permissions)
            if decision.effect != PermissionEffect.allow():
                var label = "denied" if decision.effect == PermissionEffect.deny() else "prompt"
                content = "Permission " + label
                for scope in decision.scopes:
                    content += ": " + scope
            else:
                if cancel.is_cancelled():
                    content = "Error: operation cancelled"
                else:
                    var result = self.tools.execute(prepared)
                    content = result.content
        except error:
            content = "Error: " + String(error)
        var message = Message("tool", content)
        message.tool_call_id = call.id
        message.name = call.name
        self.messages.append(message^)

    def context_chars(self) -> Int:
        var total = 0
        for message in self.messages:
            total += message.role.byte_length() + message.content.byte_length()
            for call in message.tool_calls:
                total += call.id.byte_length() + call.name.byte_length() + call.arguments.byte_length()
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
                summary += self.messages[i].role + ": " + _truncate(self.messages[i].content, 500) + "\n"
        summary = _tail(summary, 8000)
        var compacted = List[Message]()
        compacted.append(Message("system", summary^))
        for i in range(cut, len(self.messages)):
            compacted.append(self.messages[i].copy())
        self.messages = compacted^
        self.compactions += 1
        return True

    def _result(self, text: String, usage: Usage, turns: Int, reason: String) -> AgentResult:
        return AgentResult(text, self.messages.copy(), usage.copy(), turns, reason, self.compactions)


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
