from std.testing import TestSuite, assert_equal, assert_false, assert_true

from mochi.json import JsonValue
from mochi.tools import RemoteToolMetadata, RemoteToolRouter, mcp_wire_tool_name


def test_remote_router_keeps_exposed_and_raw_names() raises:
    assert_equal(mcp_wire_tool_name("alpha", "do__thing"), "alpha__do__thing")
    var router = RemoteToolRouter()
    router.register(
        RemoteToolMetadata(
            "mcp", "alpha", "alpha__search", "", JsonValue.object()
        ),
        "search",
    )
    router.register(
        RemoteToolMetadata(
            "mcp", "beta", "beta__search", "", JsonValue.object()
        ),
        "search",
    )

    assert_true(router.is_remote("alpha__search"))
    assert_true(router.is_remote("beta__search"))
    assert_equal(router.endpoint_for("alpha__search"), "alpha")
    assert_equal(router.endpoint_for("beta__search"), "beta")
    assert_equal(router.raw_name_for("alpha__search"), "search")
    assert_equal(router.raw_name_for("beta__search"), "search")

    router.remove_endpoint("mcp", "alpha")
    assert_false(router.is_remote("alpha__search"))
    assert_true(router.is_remote("beta__search"))
    assert_equal(router.raw_name_for("beta__search"), "search")


def test_remote_router_preserves_plugin_names() raises:
    var router = RemoteToolRouter()
    router.register(
        RemoteToolMetadata(
            "plugin", "formatter", "format", "", JsonValue.object()
        )
    )

    assert_equal(router.raw_name_for("format"), "format")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
