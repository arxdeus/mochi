"""Pure Mojo command-line parsing and configuration."""

from std.os import getenv

from mochi.json import JsonValue
from mochi.mcp import McpSession, StdioTransport, StreamableHttpTransport
from mochi.plugin import PluginExecutable, PluginProtocol
from mochi.provider import ProviderSpec, builtin_provider_registry
from mochi.runtime import ToolDefinition
from mochi.storage import SessionRef


comptime VERSION = "0.1.0"
comptime DEFAULT_MODEL = "gpt-4.1-mini"
comptime DEFAULT_PROVIDER = "openai"
comptime DEFAULT_PROVIDER_URL = "https://api.openai.com/v1"
comptime DEFAULT_ANTHROPIC_URL = "https://api.anthropic.com"
comptime DEFAULT_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta"
comptime DEFAULT_COPILOT_URL = "https://api.githubcopilot.com"
comptime OPENAI_COMPATIBLE_PROVIDERS = [
    "openai", "openrouter", "xai", "deepseek", "mistral", "zai", "groq",
    "together", "fireworks", "perplexity", "cerebras", "moonshot", "ollama",
    "lmstudio", "vllm",
]


@fieldwise_init
struct NamedEndpoint(Copyable, Movable):
    var name: String
    var value: String


struct CliConfig(Copyable, Movable):
    var model: String
    var provider: String
    var provider_url: String
    var provider_keys: List[String]
    var print_mode: Bool
    var output_format: String
    var yolo: Bool
    var mcp_stdio: List[NamedEndpoint]
    var mcp_http: List[NamedEndpoint]
    var plugins: List[String]
    var prompt: Optional[String]
    var show_help: Bool
    var show_version: Bool
    var openai_oauth: Bool
    var openai_oauth_login: Bool
    var continue_session: Bool
    var session_id: Optional[String]
    var acp: Bool
    var rollback: Bool

    def __init__(out self):
        self.model = DEFAULT_MODEL
        self.provider = DEFAULT_PROVIDER
        self.provider_url = DEFAULT_PROVIDER_URL
        self.provider_keys = List[String]()
        self.print_mode = False
        self.output_format = "text"
        self.yolo = False
        self.mcp_stdio = List[NamedEndpoint]()
        self.mcp_http = List[NamedEndpoint]()
        self.plugins = List[String]()
        self.prompt = None
        self.show_help = False
        self.show_version = False
        self.openai_oauth = False
        self.openai_oauth_login = False
        self.continue_session = False
        self.session_id = None
        self.acp = False
        self.rollback = False

    def normalize_provider_url(mut self):
        if self.provider_url != DEFAULT_PROVIDER_URL:
            return
        if self.provider == "anthropic":
            self.provider_url = DEFAULT_ANTHROPIC_URL
        elif self.provider == "gemini":
            self.provider_url = DEFAULT_GEMINI_URL
        elif self.provider == "copilot":
            self.provider_url = DEFAULT_COPILOT_URL
        else:
            try:
                self.provider_url = builtin_provider_registry().get(
                    self.provider
                ).base_url
            except:
                pass

    def api_key(self) -> String:
        if len(self.provider_keys) > 0:
            return self.provider_keys[0]
        if self.provider == "anthropic":
            return getenv("ANTHROPIC_API_KEY", "")
        if self.provider == "gemini":
            var key = getenv("GEMINI_API_KEY", "")
            if key == "":
                key = getenv("GOOGLE_API_KEY", "")
            return key^
        if self.provider == "copilot":
            var key = getenv("GH_COPILOT_TOKEN", "")
            if key.strip() == "":
                key = getenv("COPILOT_GITHUB_TOKEN", "")
            return key^
        if self.provider == "openrouter":
            return getenv("OPENROUTER_API_KEY", "")
        if self.provider == "xai":
            return getenv("XAI_API_KEY", "")
        if self.provider == "deepseek":
            return getenv("DEEPSEEK_API_KEY", "")
        if self.provider == "mistral":
            return getenv("MISTRAL_API_KEY", "")
        if self.provider == "zai":
            return getenv("ZHIPU_API_KEY", "")
        if self.provider == "groq":
            return getenv("GROQ_API_KEY", "")
        if self.provider == "together":
            return getenv("TOGETHER_API_KEY", "")
        if self.provider == "fireworks":
            return getenv("FIREWORKS_API_KEY", "")
        if self.provider == "perplexity":
            return getenv("PERPLEXITY_API_KEY", "")
        if self.provider == "cerebras":
            return getenv("CEREBRAS_API_KEY", "")
        if self.provider == "moonshot":
            return getenv("MOONSHOT_API_KEY", "")
        return getenv("OPENAI_API_KEY", "") if self.provider == "openai" else ""

    def provider_spec(self) -> ProviderSpec:
        var spec = ProviderSpec(self.provider, self.provider_url)
        spec.responses_api = self.openai_oauth
        for key in self.provider_keys:
            spec.add_api_key(key)
        if len(spec.api_keys) == 0:
            var key = self.api_key()
            if key != "":
                spec.add_api_key(key^)
        return spec^


def _valid_provider(provider: String) -> Bool:
    if provider == "anthropic" or provider == "gemini" or provider == "copilot":
        return True
    for candidate in materialize[OPENAI_COMPATIBLE_PROVIDERS]():
        if provider == candidate:
            return True
    return False


def parse_args(arguments: List[String]) raises -> CliConfig:
    var config = CliConfig()
    var index = 0
    while index < len(arguments):
        var argument = arguments[index]
        if index == 0 and argument == "rollback":
            config.rollback = True
            index += 1
            continue
        if argument == "--help" or argument == "-h":
            config.show_help = True
        elif argument == "--version":
            config.show_version = True
        elif argument == "--print":
            config.print_mode = True
        elif argument == "--openai-oauth":
            config.openai_oauth = True
        elif argument == "--openai-oauth-login":
            config.openai_oauth_login = True
        elif argument == "--acp":
            config.acp = True
        elif argument == "--yolo":
            config.yolo = True
        elif argument == "--continue" or argument == "-c":
            config.continue_session = True
        elif argument == "--session" or argument == "--resume" or argument == "-s":
            var value = _option_value(arguments, index, argument)
            _ = SessionRef(value)
            config.session_id = Optional(value^)
            index += 1
        elif argument == "--model":
            config.model = _option_value(arguments, index, argument)
            index += 1
        elif argument == "--provider":
            config.provider = _option_value(arguments, index, argument)
            index += 1
            if not _valid_provider(config.provider):
                raise Error("invalid --provider: " + config.provider)
        elif argument == "--provider-url":
            config.provider_url = _option_value(arguments, index, argument)
            index += 1
        elif argument == "--provider-key":
            config.provider_keys.append(_option_value(arguments, index, argument))
            index += 1
        elif argument == "--output-format":
            config.output_format = _option_value(arguments, index, argument)
            index += 1
            if config.output_format != "text" and config.output_format != "json" and config.output_format != "stream-json":
                raise Error("invalid --output-format: " + config.output_format + " (expected text, json, or stream-json)")
        elif argument == "--mcp-stdio":
            var value = _option_value(arguments, index, argument)
            config.mcp_stdio.append(_named_endpoint(value, argument))
            index += 1
        elif argument == "--mcp-http":
            var value = _option_value(arguments, index, argument)
            config.mcp_http.append(_named_endpoint(value, argument))
            index += 1
        elif argument == "--plugin":
            var path = _option_value(arguments, index, argument)
            if path == "":
                raise Error("--plugin requires a non-empty PATH")
            config.plugins.append(path^)
            index += 1
        elif argument.startswith("-"):
            raise Error("unknown option: " + argument)
        elif config.prompt:
            raise Error("unexpected argument: " + argument)
        else:
            config.prompt = Optional(argument.copy())
        index += 1
    config.normalize_provider_url()
    if config.openai_oauth and config.openai_oauth_login:
        raise Error("--openai-oauth and --openai-oauth-login cannot be combined")
    if (config.openai_oauth or config.openai_oauth_login) and config.provider != "openai":
        raise Error("OpenAI OAuth requires --provider openai")
    if config.openai_oauth and len(config.provider_keys) > 0:
        raise Error("--openai-oauth cannot be combined with --provider-key")
    if config.openai_oauth and config.provider_url != DEFAULT_PROVIDER_URL:
        raise Error("--openai-oauth cannot be combined with --provider-url")
    if config.continue_session and config.session_id:
        raise Error("--continue cannot be combined with --session")
    return config^


def read_stdin() raises -> String:
    """Read standard input to EOF using Mojo native file descriptors."""
    var reader = FileDescriptor(0)
    var result = String("")
    while True:
        var buffer = Array[Byte, 4096](fill=0)
        var count = reader.read_bytes(buffer)
        if count <= 0:
            return result^
        for index in range(count):
            result += String(buffer[index])


def validate_protocol_metadata(config: CliConfig) raises:
    """Construct protocol launch metadata before runtime connection setup."""
    for endpoint in config.mcp_stdio:
        var command = _words(endpoint.value)
        if len(command) == 0:
            raise Error("MCP stdio " + endpoint.name + " has an empty command")
        _ = McpSession()
    for endpoint in config.mcp_http:
        if not endpoint.value.startswith("http://") and not endpoint.value.startswith("https://"):
            raise Error("MCP HTTP " + endpoint.name + " has an invalid URL: " + endpoint.value)
        _ = StreamableHttpTransport(endpoint.value)
        _ = McpSession()
    for path in config.plugins:
        _ = PluginExecutable(path)
        _ = PluginProtocol()


def standard_tool_definitions() raises -> List[ToolDefinition]:
    """Return OpenAI schemas for every built-in implemented by ToolRegistry."""
    var definitions = List[ToolDefinition]()
    definitions.append(_tool("read", "Read a UTF-8 file", _properties("path", "string", True)))
    definitions.append(_tool("write", "Write a UTF-8 file", _two_properties("path", "string", "content", "string")))
    definitions.append(_tool("edit", "Replace exact text in a file", _three_string_properties("path", "old_string", "new_string")))
    definitions.append(_tool("list", "List a directory", _properties("path", "string", True)))
    definitions.append(_tool("bash", "Run a shell command", _properties("command", "string", True)))
    definitions.append(_tool("code_execution", "Run the bounded Mochi command interpreter", _properties("code", "string", True)))
    return definitions^


def _tool(name: String, description: String, var parameters: JsonValue) -> ToolDefinition:
    return ToolDefinition(name, description, parameters^)


def _properties(name: String, kind: String, required: Bool) raises -> JsonValue:
    var schema = JsonValue.object()
    schema.set("type", JsonValue.string("object"))
    var properties = JsonValue.object()
    var field = JsonValue.object()
    field.set("type", JsonValue.string(kind))
    properties.set(name, field^)
    schema.set("properties", properties^)
    var required_fields = JsonValue.array()
    if required:
        required_fields.append(JsonValue.string(name))
    schema.set("required", required_fields^)
    schema.set("additionalProperties", JsonValue.boolean(False))
    return schema^


def _two_properties(first: String, first_kind: String, second: String, second_kind: String) raises -> JsonValue:
    var schema = _properties(first, first_kind, True)
    var properties = schema.get("properties")
    var field = JsonValue.object()
    field.set("type", JsonValue.string(second_kind))
    properties.set(second, field^)
    schema.set("properties", properties^)
    var required = schema.get("required")
    required.append(JsonValue.string(second))
    schema.set("required", required^)
    return schema^


def _three_string_properties(first: String, second: String, third: String) raises -> JsonValue:
    var schema = _two_properties(first, "string", second, "string")
    var properties = schema.get("properties")
    var field = JsonValue.object()
    field.set("type", JsonValue.string("string"))
    properties.set(third, field^)
    schema.set("properties", properties^)
    var required = schema.get("required")
    required.append(JsonValue.string(third))
    schema.set("required", required^)
    return schema^


def help_text() -> String:
    return """Usage: mochi [OPTIONS] [PROMPT]

Pure Mojo AI coding agent.

Options:
  -h, --help                    Show this help
      --version                 Show version
      --model MODEL             Model name (default: gpt-4.1-mini)
  -c, --continue                Resume the latest session for this directory
  -s, --session ID              Resume a specific session
      --resume ID               Alias for --session
      --provider PROVIDER       openai, anthropic, gemini, or copilot
      --provider-url URL        Provider API base URL
      --provider-key KEY        API key; may be repeated
      --openai-oauth            Use ChatGPT/Codex OAuth Responses API
      --openai-oauth-login      Log in to ChatGPT/Codex with a device code
      --acp                     Run the ACP v1 NDJSON stdio server
      --print                   Read one prompt from stdin when PROMPT is absent
      --output-format FORMAT    text, json, or stream-json
      --yolo                    Allow tool operations without prompting
      --mcp-stdio NAME=COMMAND  Connect an MCP stdio server; may be repeated
      --mcp-http NAME=URL       Connect an MCP HTTP server; may be repeated
      --plugin PATH             Launch a Mojo executable plugin; may be repeated
"""


def _option_value(arguments: List[String], index: Int, option: String) raises -> String:
    if index + 1 >= len(arguments):
        raise Error(option + " requires a value")
    var value = arguments[index + 1]
    if value == "":
        raise Error(option + " requires a non-empty value")
    return value


def _named_endpoint(value: String, option: String) raises -> NamedEndpoint:
    var separator = _find_byte(value, UInt8(61))
    if separator <= 0 or separator + 1 >= value.byte_length():
        raise Error(option + " requires NAME=VALUE")
    return NamedEndpoint(_byte_range(value, 0, separator), _byte_range(value, separator + 1, value.byte_length()))


def _words(value: String) -> List[String]:
    var result = List[String]()
    for word in value.split():
        if word.byte_length() != 0:
            result.append(String(word))
    return result^


def _find_byte(value: String, needle: UInt8) -> Int:
    for index in range(value.byte_length()):
        if UInt8(ord(value[byte=index])) == needle:
            return index
    return -1


def _byte_range(value: String, start: Int, end: Int) -> String:
    var result = String("")
    for index in range(start, end):
        result += String(value[byte=index])
    return result^
