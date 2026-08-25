from std.os import remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from mochi.json import JsonValue, parse_json
from mochi.ops import StructuredLogger, TelemetryEvent


comptime PATH = "/tmp/mochi-ops/logs/mochi.jsonl"


def _clean():
    for path in [PATH, PATH + ".1", PATH + ".2"]:
        try:
            remove(path)
        except:
            pass


def test_structured_logging_and_rotation() raises:
    _clean()
    var logger = StructuredLogger(PATH, 20, 2)
    logger.log("info", "startup", "first")
    logger.log("info", "turn", "second")
    assert_true(exists(PATH))
    assert_true(exists(PATH + ".1"))
    var line = String(open(PATH, "r").read().split("\n")[0])
    var value = parse_json(line)
    assert_equal(value.get("event").string_value, "turn")


def test_telemetry_event_codec() raises:
    var attributes = JsonValue.object()
    attributes.set("turns", JsonValue.integer(2))
    var event = TelemetryEvent("agent.run", attributes^)
    assert_equal(
        event.to_json().serialize(),
        '{"name":"agent.run","attributes":{"turns":2}}',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
