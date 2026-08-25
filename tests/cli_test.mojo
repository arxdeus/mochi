from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.cli import parse_args, standard_tool_definitions


def test_defaults() raises:
    var config = parse_args(List[String]())
    assert_equal(config.model, "gpt-4.1-mini")
    assert_equal(config.output_format, "text")
    assert_false(config.print_mode)


def test_all_options() raises:
    var arguments: List[String] = [
        "--model", "test-model", "--provider-url", "http://localhost/v1",
        "--provider-key", "one", "--provider-key", "two", "--print",
        "--output-format", "json", "--yolo", "--mcp-stdio", "local=server --flag",
        "--mcp-http", "remote=https://example.test/mcp", "--plugin", "/tmp/plugin",
        "hello",
    ]
    var config = parse_args(arguments^)
    assert_equal(config.model, "test-model")
    assert_equal(len(config.provider_keys), 2)
    assert_true(config.print_mode)
    assert_true(config.yolo)
    assert_equal(config.mcp_stdio[0].name, "local")
    assert_equal(config.mcp_http[0].value, "https://example.test/mcp")
    assert_equal(config.prompt.value(), "hello")


def test_invalid_output_format() raises:
    var failed = False
    try:
        _ = parse_args(["--output-format", "yaml"])
    except:
        failed = True
    assert_true(failed)


def test_provider_spec_and_builtin_definitions() raises:
    var config = parse_args([
        "--provider-url", "http://localhost/v1", "--provider-key", "secret"
    ])
    var spec = config.provider_spec()
    assert_equal(spec.base_url, "http://localhost/v1")
    assert_equal(spec.api_keys[0], "secret")
    var definitions = standard_tool_definitions()
    assert_equal(len(definitions), 6)
    assert_equal(definitions[0].name, "read")
    assert_equal(definitions[5].name, "code_execution")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
