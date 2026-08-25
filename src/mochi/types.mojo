"""Core, provider-neutral domain types for Mochi."""


@fieldwise_init
struct ToolCall(Copyable, Movable):
    """A model request to invoke a named tool."""

    var id: String
    var name: String
    var arguments: String


@fieldwise_init
struct Message(Copyable, Movable):
    """A conversation message with optional tool-call metadata."""

    var role: String
    var content: String
    var tool_calls: List[ToolCall]
    var tool_call_id: String
    var name: String

    def __init__(out self, role: String, content: String):
        self.role = role
        self.content = content
        self.tool_calls = List[ToolCall]()
        self.tool_call_id = ""
        self.name = ""

    def add_tool_call(mut self, var call: ToolCall):
        self.tool_calls.append(call^)


@fieldwise_init
struct Usage(Copyable, Movable):
    """Token counts accumulated across provider turns."""

    var input_tokens: Int
    var output_tokens: Int

    def __init__(out self):
        self.input_tokens = 0
        self.output_tokens = 0

    def total_tokens(self) -> Int:
        return self.input_tokens + self.output_tokens

    def add(mut self, other: Self):
        self.input_tokens += other.input_tokens
        self.output_tokens += other.output_tokens


@fieldwise_init
struct ProviderEvent(Copyable, Movable):
    """A streaming provider event without a dependency on a JSON value type."""

    var kind: String
    var text: String
    var tool_call: Optional[ToolCall]
    var usage: Usage
    var stop_reason: String

    @staticmethod
    def text_delta(text: String) -> Self:
        return Self("text_delta", text, None, Usage(), "")

    @staticmethod
    def tool_call_delta(var call: ToolCall) -> Self:
        return Self("tool_call_delta", "", Optional(call^), Usage(), "")

    @staticmethod
    def usage_event(usage: Usage) -> Self:
        return Self("usage", "", None, usage.copy(), "")

    @staticmethod
    def done(reason: String) -> Self:
        return Self("done", "", None, Usage(), reason)


struct CancellationToken(Copyable, Movable):
    """A lightweight cooperative cancellation flag."""

    var _cancelled: Bool

    def __init__(out self):
        self._cancelled = False

    def cancel(mut self):
        self._cancelled = True

    def is_cancelled(self) -> Bool:
        return self._cancelled

    def check(self) raises:
        if self._cancelled:
            raise Error("operation cancelled")
