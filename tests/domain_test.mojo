from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.domain import (
    ContentBlock,
    DomainMessage,
    DomainProviderEvent,
    ImageMediaType,
    ImageSource,
    MessageKind,
    MochiError,
    Model,
    ModelFamily,
    ModelInfo,
    ModelPricing,
    ModelTier,
    Role,
    StopReason,
    StreamResponse,
    ThinkingSupport,
    TokenUsage,
    domain_message_to_json,
    mochi_error_to_json,
    token_usage_to_json,
)
from mochi.json import JsonValue


def test_image_media_and_source() raises:
    var media = [
        ImageMediaType.png(),
        ImageMediaType.jpeg(),
        ImageMediaType.gif(),
        ImageMediaType.webp(),
    ]
    var mimes = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    for i in range(len(media)):
        assert_equal(media[i].mime(), mimes[i])
        assert_true(ImageMediaType.from_mime(mimes[i]))
        assert_equal(
            ImageMediaType.from_mime(mimes[i]).value().tag, media[i].tag
        )
    assert_false(ImageMediaType.from_mime("image/bmp"))
    var source = ImageSource(ImageMediaType.png(), "YWJj")
    assert_equal(source.to_data_url(), "data:image/png;base64,YWJj")


def test_content_block_factories_and_predicates() raises:
    var text = ContentBlock.text_block("hello")
    assert_true(text.is_text())
    assert_false(text.is_thinking())
    assert_equal(text.text, "hello")

    var thinking = ContentBlock.thinking("reason", Optional("sig"))
    assert_true(thinking.is_thinking())
    assert_equal(thinking.signature.value(), "sig")
    var redacted = ContentBlock.redacted_thinking("secret")
    assert_true(redacted.is_thinking())

    var input = JsonValue.object()
    input.set("path", JsonValue.string("x"))
    var tool = ContentBlock.tool_use(
        "call-1", "read", input^, Optional("thought")
    )
    assert_true(tool.is_tool_use())
    assert_equal(tool.id, "call-1")
    assert_equal(tool.input.get("path").string_value, "x")
    assert_equal(tool.signature.value(), "thought")

    var result = ContentBlock.tool_result("call-1", "failed", True)
    assert_true(result.is_tool_result())
    assert_true(result.is_error)
    var image = ContentBlock.image(ImageSource(ImageMediaType.webp(), "data"))
    assert_true(image.is_image())
    assert_equal(image.image_source.value().media_type.mime(), "image/webp")


def test_roles_message_kinds_and_messages() raises:
    assert_true(Role.user().is_user())
    assert_true(Role.assistant().is_assistant())
    assert_true(MessageKind.turn().is_turn())
    assert_true(MessageKind.observation().is_observation())

    var user = DomainMessage.user("hello")
    assert_true(user.role.is_user())
    assert_true(user.content[0].is_text())
    user.add_block(ContentBlock.tool_use("id", "bash", JsonValue.object()))
    assert_true(user.has_tool_calls())

    var assistant = DomainMessage.assistant("done")
    assert_true(assistant.role.is_assistant())
    var observation = DomainMessage.observation("host noticed")
    assert_true(observation.is_observation())
    assert_true(observation.role.is_user())


def test_usage_accumulation_and_stream_response() raises:
    var usage = TokenUsage(10, 5, 3, 2)
    usage.add(TokenUsage(2, 4, 1, 6))
    assert_equal(usage.input, 12)
    assert_equal(usage.output, 9)
    assert_equal(usage.cache_creation, 4)
    assert_equal(usage.cache_read, 8)
    assert_equal(usage.input_tokens(), 24)
    assert_equal(usage.total_tokens(), 33)
    var response = StreamResponse(
        DomainMessage.assistant("ok"),
        usage.copy(),
        Optional(StopReason.end_turn()),
    )
    assert_true(response.stop_reason.value().is_end_turn())


def test_provider_event_factories_and_predicates() raises:
    var text = DomainProviderEvent.text_delta("a")
    assert_true(text.is_text_delta())
    assert_equal(text.text, "a")
    var thinking = DomainProviderEvent.thinking_delta("b")
    assert_true(thinking.is_thinking_delta())
    var tool = DomainProviderEvent.tool_use_start("id", "read")
    assert_true(tool.is_tool_use_start())
    assert_equal(tool.name, "read")
    var progress = DomainProviderEvent.prompt_progress(10, 20, 4)
    assert_true(progress.is_prompt_progress())
    assert_equal(progress.processed, 10)
    assert_equal(progress.total, 20)
    assert_equal(progress.cache, 4)


def test_stop_reason_mappings() raises:
    assert_true(StopReason.from_anthropic("end_turn").is_end_turn())
    assert_true(StopReason.from_anthropic("tool_use").is_tool_use())
    assert_true(StopReason.from_anthropic("max_tokens").is_max_tokens())
    assert_true(StopReason.from_openai("stop").is_end_turn())
    assert_true(StopReason.from_openai("tool_calls").is_tool_use())
    assert_true(StopReason.from_openai("length").is_max_tokens())
    assert_true(StopReason.from_google("STOP").is_end_turn())
    assert_true(StopReason.from_google("MAX_TOKENS").is_max_tokens())
    assert_true(StopReason.from_google("SAFETY").is_end_turn())


def test_model_tags_capabilities_and_pricing() raises:
    assert_equal(ModelTier.weak().name(), "weak")
    assert_equal(ModelTier.medium().name(), "medium")
    assert_equal(ModelTier.strong().name(), "strong")
    assert_equal(ModelTier.compaction().name(), "compaction")
    assert_true(ModelFamily.claude().supports_tool_examples())
    assert_false(ModelFamily.gemini().supports_tool_examples())
    assert_true(ModelFamily.gemini().supports_vision())
    assert_false(ModelFamily.glm().supports_vision())
    assert_true(ModelFamily.generic().tag == ModelFamily.GENERIC)
    assert_true(ModelFamily.gpt().tag == ModelFamily.GPT)
    assert_true(ModelFamily.synthetic().tag == ModelFamily.SYNTHETIC)

    assert_false(ThinkingSupport.no().supports())
    assert_true(ThinkingSupport.yes().supports())
    assert_true(ThinkingSupport.required().requires())
    assert_true(ThinkingSupport.from_flags(None, True).value().requires())
    assert_true(
        ThinkingSupport.from_flags(Optional(True), False).value().supports()
    )
    assert_false(ThinkingSupport.from_flags(None, False))

    var zero = ModelPricing()
    assert_true(zero.is_zero())
    var pricing = ModelPricing(2.0, 8.0, 2.5, 0.2)
    var usage = TokenUsage(1000000, 1000000, 1000000, 1000000)
    assert_equal(pricing.cost(usage), 12.7)
    var info = ModelInfo.id_only("model")
    assert_equal(info.id, "model")
    assert_false(info.context_window)

    var model = Model(
        "sonnet",
        "anthropic",
        ModelTier.strong(),
        ModelFamily.claude(),
        ThinkingSupport.required(),
        None,
        pricing.copy(),
        Optional(8192),
        200000,
    )
    assert_equal(model.spec(), "anthropic/sonnet")
    assert_true(model.supports_thinking())
    assert_true(model.requires_thinking())
    assert_true(model.supports_vision())
    assert_true(model.supports_tool_examples())
    assert_equal(model.list_cost(usage).value(), 12.7)
    var unpriced = Model(
        "local",
        "ollama",
        ModelTier.medium(),
        ModelFamily.generic(),
        ThinkingSupport.no(),
        Optional(True),
        zero.copy(),
        None,
        32768,
    )
    assert_true(unpriced.supports_vision())
    assert_false(unpriced.list_cost(usage))


def test_error_classification() raises:
    var auth = MochiError.api(401, "bad key")
    assert_true(auth.is_auth_error())
    assert_true(auth.should_rotate_key())
    assert_false(auth.is_retryable())
    assert_true(MochiError.api(429, "slow down").is_retryable())
    assert_true(MochiError.api(503, "overloaded").is_retryable())
    assert_false(
        MochiError.api(400, "maximum context length exceeded").is_retryable()
    )
    assert_true(
        MochiError.api(
            400, "maximum context length exceeded"
        ).is_context_overflow()
    )
    assert_true(MochiError.api(413, "large").is_context_overflow())
    assert_true(MochiError.io("closed").is_retryable())
    assert_true(MochiError.http("network").is_retryable())
    assert_true(MochiError.timeout().is_retryable())
    assert_false(MochiError.config("bad config").is_retryable())
    assert_false(MochiError.tool_error("read", "bad").is_retryable())
    assert_false(MochiError.json("bad json").is_retryable())
    assert_false(MochiError.cancelled().is_retryable())
    assert_false(MochiError.internal("channel").is_retryable())


def test_domain_golden_codecs() raises:
    var message = DomainMessage.assistant("hello")
    assert_equal(
        domain_message_to_json(message).serialize(),
        '{"role":"assistant","kind":"turn","content":[{"tag":0,"text":"hello","id":"","name":"","input":null,"is_error":false}]}',
    )
    assert_equal(
        token_usage_to_json(TokenUsage(1, 2, 3, 4)).serialize(),
        '{"input":1,"output":2,"cache_creation":3,"cache_read":4}',
    )
    assert_equal(
        mochi_error_to_json(MochiError.api(429, "slow")).serialize(),
        '{"tag":0,"message":"slow","status":429,"tool":""}',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
