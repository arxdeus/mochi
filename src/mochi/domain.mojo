"""Canonical provider-neutral domain contracts."""

from mochi.json import JsonValue


struct ImageMediaType(Copyable, Movable):
    comptime PNG = 0
    comptime JPEG = 1
    comptime GIF = 2
    comptime WEBP = 3

    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def png() -> Self:
        return Self(Self.PNG)

    @staticmethod
    def jpeg() -> Self:
        return Self(Self.JPEG)

    @staticmethod
    def gif() -> Self:
        return Self(Self.GIF)

    @staticmethod
    def webp() -> Self:
        return Self(Self.WEBP)

    def mime(self) -> String:
        if self.tag == Self.PNG:
            return "image/png"
        if self.tag == Self.JPEG:
            return "image/jpeg"
        if self.tag == Self.GIF:
            return "image/gif"
        return "image/webp"

    @staticmethod
    def from_mime(mime: String) -> Optional[Self]:
        if mime == "image/png":
            return Self.png()
        if mime == "image/jpeg":
            return Self.jpeg()
        if mime == "image/gif":
            return Self.gif()
        if mime == "image/webp":
            return Self.webp()
        return None


@fieldwise_init
struct ImageSource(Copyable, Movable):
    var media_type: ImageMediaType
    var data: String

    def to_data_url(self) -> String:
        return "data:" + self.media_type.mime() + ";base64," + self.data


struct ContentBlock(Copyable, Movable):
    comptime TEXT = 0
    comptime THINKING = 1
    comptime REDACTED_THINKING = 2
    comptime TOOL_USE = 3
    comptime TOOL_RESULT = 4
    comptime IMAGE = 5

    var tag: Int
    var text: String
    var signature: Optional[String]
    var id: String
    var name: String
    var input: JsonValue
    var is_error: Bool
    var image_source: Optional[ImageSource]

    def __init__(out self, tag: Int):
        self.tag = tag
        self.text = ""
        self.signature = None
        self.id = ""
        self.name = ""
        self.input = JsonValue.null()
        self.is_error = False
        self.image_source = None

    @staticmethod
    def text_block(text: String) -> Self:
        var block = Self(Self.TEXT)
        block.text = text
        return block^

    @staticmethod
    def thinking(text: String, var signature: Optional[String] = None) -> Self:
        var block = Self(Self.THINKING)
        block.text = text
        block.signature = signature^
        return block^

    @staticmethod
    def redacted_thinking(data: String) -> Self:
        var block = Self(Self.REDACTED_THINKING)
        block.text = data
        return block^

    @staticmethod
    def tool_use(
        id: String,
        name: String,
        var input: JsonValue,
        var thought_signature: Optional[String] = None,
    ) -> Self:
        var block = Self(Self.TOOL_USE)
        block.id = id
        block.name = name
        block.input = input^
        block.signature = thought_signature^
        return block^

    @staticmethod
    def tool_result(
        tool_use_id: String, content: String, is_error: Bool = False
    ) -> Self:
        var block = Self(Self.TOOL_RESULT)
        block.id = tool_use_id
        block.text = content
        block.is_error = is_error
        return block^

    @staticmethod
    def image(var source: ImageSource) -> Self:
        var block = Self(Self.IMAGE)
        block.image_source = Optional(source^)
        return block^

    def is_text(self) -> Bool:
        return self.tag == Self.TEXT

    def is_thinking(self) -> Bool:
        return self.tag == Self.THINKING or self.tag == Self.REDACTED_THINKING

    def is_tool_use(self) -> Bool:
        return self.tag == Self.TOOL_USE

    def is_tool_result(self) -> Bool:
        return self.tag == Self.TOOL_RESULT

    def is_image(self) -> Bool:
        return self.tag == Self.IMAGE


struct Role(Copyable, Movable):
    comptime USER = 0
    comptime ASSISTANT = 1
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def user() -> Self:
        return Self(Self.USER)

    @staticmethod
    def assistant() -> Self:
        return Self(Self.ASSISTANT)

    def is_user(self) -> Bool:
        return self.tag == Self.USER

    def is_assistant(self) -> Bool:
        return self.tag == Self.ASSISTANT


struct MessageKind(Copyable, Movable):
    comptime TURN = 0
    comptime OBSERVATION = 1
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def turn() -> Self:
        return Self(Self.TURN)

    @staticmethod
    def observation() -> Self:
        return Self(Self.OBSERVATION)

    def is_turn(self) -> Bool:
        return self.tag == Self.TURN

    def is_observation(self) -> Bool:
        return self.tag == Self.OBSERVATION


@fieldwise_init
struct DomainMessage(Copyable, Movable):
    var role: Role
    var content: List[ContentBlock]
    var display_text: Optional[String]
    var kind: MessageKind

    def __init__(out self, role: Role):
        self.role = role.copy()
        self.content = List[ContentBlock]()
        self.display_text = None
        self.kind = MessageKind.turn()

    @staticmethod
    def user(text: String) -> Self:
        var message = Self(Role.user())
        message.content.append(ContentBlock.text_block(text))
        return message^

    @staticmethod
    def assistant(text: String) -> Self:
        var message = Self(Role.assistant())
        message.content.append(ContentBlock.text_block(text))
        return message^

    @staticmethod
    def observation(text: String) -> Self:
        var message = Self.user(text)
        message.kind = MessageKind.observation()
        return message^

    def add_block(mut self, var block: ContentBlock):
        self.content.append(block^)

    def has_tool_calls(self) -> Bool:
        for block in self.content:
            if block.is_tool_use():
                return True
        return False

    def is_observation(self) -> Bool:
        return self.kind.is_observation()


@fieldwise_init
struct TokenUsage(Copyable, Movable):
    var input: Int
    var output: Int
    var cache_creation: Int
    var cache_read: Int

    def __init__(out self):
        self.input = 0
        self.output = 0
        self.cache_creation = 0
        self.cache_read = 0

    def add(mut self, other: Self):
        self.input += other.input
        self.output += other.output
        self.cache_creation += other.cache_creation
        self.cache_read += other.cache_read

    def input_tokens(self) -> Int:
        return self.input + self.cache_creation + self.cache_read

    def total_tokens(self) -> Int:
        return self.input_tokens() + self.output


struct StopReason(Copyable, Movable):
    comptime END_TURN = 0
    comptime TOOL_USE = 1
    comptime MAX_TOKENS = 2
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def end_turn() -> Self:
        return Self(Self.END_TURN)

    @staticmethod
    def tool_use() -> Self:
        return Self(Self.TOOL_USE)

    @staticmethod
    def max_tokens() -> Self:
        return Self(Self.MAX_TOKENS)

    def is_end_turn(self) -> Bool:
        return self.tag == Self.END_TURN

    def is_tool_use(self) -> Bool:
        return self.tag == Self.TOOL_USE

    def is_max_tokens(self) -> Bool:
        return self.tag == Self.MAX_TOKENS

    @staticmethod
    def from_anthropic(value: String) -> Self:
        if value == "tool_use":
            return Self.tool_use()
        if value == "max_tokens":
            return Self.max_tokens()
        return Self.end_turn()

    @staticmethod
    def from_openai(value: String) -> Self:
        if value == "tool_calls":
            return Self.tool_use()
        if value == "length":
            return Self.max_tokens()
        return Self.end_turn()

    @staticmethod
    def from_google(value: String) -> Self:
        if value == "MAX_TOKENS":
            return Self.max_tokens()
        return Self.end_turn()


struct DomainProviderEvent(Copyable, Movable):
    comptime TEXT_DELTA = 0
    comptime THINKING_DELTA = 1
    comptime TOOL_USE_START = 2
    comptime PROMPT_PROGRESS = 3

    var tag: Int
    var text: String
    var id: String
    var name: String
    var processed: Int
    var total: Int
    var cache: Int

    def __init__(out self, tag: Int):
        self.tag = tag
        self.text = ""
        self.id = ""
        self.name = ""
        self.processed = 0
        self.total = 0
        self.cache = 0

    @staticmethod
    def text_delta(text: String) -> Self:
        var event = Self(Self.TEXT_DELTA)
        event.text = text
        return event^

    @staticmethod
    def thinking_delta(text: String) -> Self:
        var event = Self(Self.THINKING_DELTA)
        event.text = text
        return event^

    @staticmethod
    def tool_use_start(id: String, name: String) -> Self:
        var event = Self(Self.TOOL_USE_START)
        event.id = id
        event.name = name
        return event^

    @staticmethod
    def prompt_progress(processed: Int, total: Int, cache: Int) -> Self:
        var event = Self(Self.PROMPT_PROGRESS)
        event.processed = processed
        event.total = total
        event.cache = cache
        return event^

    def is_text_delta(self) -> Bool:
        return self.tag == Self.TEXT_DELTA

    def is_thinking_delta(self) -> Bool:
        return self.tag == Self.THINKING_DELTA

    def is_tool_use_start(self) -> Bool:
        return self.tag == Self.TOOL_USE_START

    def is_prompt_progress(self) -> Bool:
        return self.tag == Self.PROMPT_PROGRESS


@fieldwise_init
struct StreamResponse(Copyable, Movable):
    var message: DomainMessage
    var usage: TokenUsage
    var stop_reason: Optional[StopReason]


struct ModelTier(Copyable, Movable):
    comptime WEAK = 0
    comptime MEDIUM = 1
    comptime STRONG = 2
    comptime COMPACTION = 3
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def weak() -> Self:
        return Self(Self.WEAK)

    @staticmethod
    def medium() -> Self:
        return Self(Self.MEDIUM)

    @staticmethod
    def strong() -> Self:
        return Self(Self.STRONG)

    @staticmethod
    def compaction() -> Self:
        return Self(Self.COMPACTION)

    def name(self) -> String:
        if self.tag == Self.WEAK:
            return "weak"
        if self.tag == Self.MEDIUM:
            return "medium"
        if self.tag == Self.STRONG:
            return "strong"
        return "compaction"


struct ModelFamily(Copyable, Movable):
    comptime CLAUDE = 0
    comptime GENERIC = 1
    comptime GEMINI = 2
    comptime GLM = 3
    comptime GPT = 4
    comptime SYNTHETIC = 5
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def claude() -> Self:
        return Self(Self.CLAUDE)

    @staticmethod
    def generic() -> Self:
        return Self(Self.GENERIC)

    @staticmethod
    def gemini() -> Self:
        return Self(Self.GEMINI)

    @staticmethod
    def glm() -> Self:
        return Self(Self.GLM)

    @staticmethod
    def gpt() -> Self:
        return Self(Self.GPT)

    @staticmethod
    def synthetic() -> Self:
        return Self(Self.SYNTHETIC)

    def supports_tool_examples(self) -> Bool:
        return (
            self.tag == Self.CLAUDE
            or self.tag == Self.GPT
            or self.tag == Self.SYNTHETIC
        )

    def supports_vision(self) -> Bool:
        return (
            self.tag == Self.CLAUDE
            or self.tag == Self.GPT
            or self.tag == Self.GEMINI
        )


struct ThinkingSupport(Copyable, Movable):
    comptime NO = 0
    comptime YES = 1
    comptime REQUIRED = 2
    var tag: Int

    def __init__(out self, tag: Int):
        self.tag = tag

    @staticmethod
    def no() -> Self:
        return Self(Self.NO)

    @staticmethod
    def yes() -> Self:
        return Self(Self.YES)

    @staticmethod
    def required() -> Self:
        return Self(Self.REQUIRED)

    def supports(self) -> Bool:
        return self.tag != Self.NO

    def requires(self) -> Bool:
        return self.tag == Self.REQUIRED

    @staticmethod
    def from_flags(
        var supports: Optional[Bool], requires: Bool
    ) -> Optional[Self]:
        if requires:
            return Self.required()
        if supports:
            if supports.value():
                return Self.yes()
            return Self.no()
        return None


@fieldwise_init
struct ModelPricing(Copyable, Movable):
    var input: Float64
    var output: Float64
    var cache_write: Float64
    var cache_read: Float64

    def __init__(out self):
        self.input = 0.0
        self.output = 0.0
        self.cache_write = 0.0
        self.cache_read = 0.0

    def is_zero(self) -> Bool:
        return (
            self.input == 0.0
            and self.output == 0.0
            and self.cache_write == 0.0
            and self.cache_read == 0.0
        )

    def cost(self, usage: TokenUsage) -> Float64:
        return (
            Float64(usage.input) * self.input
            + Float64(usage.output) * self.output
            + Float64(usage.cache_creation) * self.cache_write
            + Float64(usage.cache_read) * self.cache_read
        ) / 1000000.0


@fieldwise_init
struct ModelInfo(Copyable, Movable):
    var id: String
    var context_window: Optional[Int]
    var max_output_tokens: Optional[Int]
    var pricing: Optional[ModelPricing]
    var supports_thinking: Optional[Bool]
    var supports_vision: Optional[Bool]
    var tier: Optional[ModelTier]

    @staticmethod
    def id_only(id: String) -> Self:
        return Self(id, None, None, None, None, None, None)


@fieldwise_init
struct Model(Copyable, Movable):
    var id: String
    var provider: String
    var tier: ModelTier
    var family: ModelFamily
    var thinking: ThinkingSupport
    var supports_vision_override: Optional[Bool]
    var pricing: ModelPricing
    var max_output_tokens: Optional[Int]
    var context_window: Int

    def spec(self) -> String:
        return self.provider + "/" + self.id

    def supports_thinking(self) -> Bool:
        return self.thinking.supports()

    def requires_thinking(self) -> Bool:
        return self.thinking.requires()

    def supports_fast(self) -> Bool:
        return self.provider == "anthropic" and self.id.startswith(
            "claude-opus-4-6"
        )

    def supports_vision(self) -> Bool:
        if self.supports_vision_override:
            return self.supports_vision_override.value()
        return self.family.supports_vision()

    def supports_tool_examples(self) -> Bool:
        return self.family.supports_tool_examples()

    def list_cost(self, usage: TokenUsage) -> Optional[Float64]:
        if self.pricing.is_zero():
            return None
        return self.pricing.cost(usage)


struct MochiError(Copyable, Movable):
    comptime API = 0
    comptime CONFIG = 1
    comptime TOOL = 2
    comptime IO = 3
    comptime HTTP = 4
    comptime JSON = 5
    comptime CANCELLED = 6
    comptime TIMEOUT = 7
    comptime INTERNAL = 8

    var tag: Int
    var message: String
    var status: Int
    var tool: String

    def __init__(out self, tag: Int, message: String = ""):
        self.tag = tag
        self.message = message
        self.status = 0
        self.tool = ""

    @staticmethod
    def api(status: Int, message: String) -> Self:
        var error = Self(Self.API, message)
        error.status = status
        return error^

    @staticmethod
    def config(message: String) -> Self:
        return Self(Self.CONFIG, message)

    @staticmethod
    def tool_error(tool: String, message: String) -> Self:
        var error = Self(Self.TOOL, message)
        error.tool = tool
        return error^

    @staticmethod
    def io(message: String) -> Self:
        return Self(Self.IO, message)

    @staticmethod
    def http(message: String) -> Self:
        return Self(Self.HTTP, message)

    @staticmethod
    def json(message: String) -> Self:
        return Self(Self.JSON, message)

    @staticmethod
    def cancelled() -> Self:
        return Self(Self.CANCELLED, "cancelled")

    @staticmethod
    def timeout(message: String = "stream timed out") -> Self:
        return Self(Self.TIMEOUT, message)

    @staticmethod
    def internal(message: String) -> Self:
        return Self(Self.INTERNAL, message)

    def is_auth_error(self) -> Bool:
        return self.tag == Self.API and self.status == 401

    def is_context_overflow(self) -> Bool:
        if self.tag != Self.API:
            return False
        if self.status == 413:
            return True
        if self.status != 400:
            return False
        var lower = self.message.lower()
        var scope = (
            "context" in lower
            or "token" in lower
            or "prompt" in lower
            or "input" in lower
        )
        var overflow = (
            "exceeds" in lower
            or "exceeded" in lower
            or "too long" in lower
            or "too many" in lower
            or "maximum" in lower
        )
        return scope and overflow

    def is_retryable(self) -> Bool:
        if self.is_context_overflow():
            return False
        if self.tag == Self.API:
            return self.status == 429 or self.status >= 500
        return (
            self.tag == Self.IO
            or self.tag == Self.HTTP
            or self.tag == Self.TIMEOUT
        )

    def should_rotate_key(self) -> Bool:
        return self.tag == Self.API and (
            self.status == 401 or self.status == 403 or self.status == 429
        )


def domain_message_to_json(message: DomainMessage) raises -> JsonValue:
    var value = JsonValue.object()
    value.set(
        "role", JsonValue.string("assistant" if message.role.is_assistant() else "user")
    )
    value.set(
        "kind", JsonValue.string("observation" if message.is_observation() else "turn")
    )
    var blocks = JsonValue.array()
    for block in message.content:
        var item = JsonValue.object()
        item.set("tag", JsonValue.integer(block.tag))
        item.set("text", JsonValue.string(block.text))
        item.set("id", JsonValue.string(block.id))
        item.set("name", JsonValue.string(block.name))
        item.set("input", block.input.copy())
        item.set("is_error", JsonValue.boolean(block.is_error))
        if block.signature:
            item.set("signature", JsonValue.string(block.signature.value()))
        blocks.append(item^)
    value.set("content", blocks^)
    if message.display_text:
        value.set("display_text", JsonValue.string(message.display_text.value()))
    return value^


def token_usage_to_json(usage: TokenUsage) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("input", JsonValue.integer(usage.input))
    value.set("output", JsonValue.integer(usage.output))
    value.set("cache_creation", JsonValue.integer(usage.cache_creation))
    value.set("cache_read", JsonValue.integer(usage.cache_read))
    return value^


def mochi_error_to_json(error: MochiError) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("tag", JsonValue.integer(error.tag))
    value.set("message", JsonValue.string(error.message))
    value.set("status", JsonValue.integer(error.status))
    value.set("tool", JsonValue.string(error.tool))
    return value^
