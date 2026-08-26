from std.os import makedirs, remove
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_true

from mochi.json import JsonValue, parse_json
from mochi.ops import (
    backup_binary,
    StructuredLogger,
    TelemetryEvent,
    compare_versions,
    is_newer_version,
    plan_update,
    replace_from_download,
    restore_backup,
)


comptime PATH = "/tmp/mochi-ops/logs/mochi.jsonl"
comptime TEST_DIR = "/tmp/mochi-ops-update"


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


def test_version_comparison() raises:
    assert_equal(compare_versions("v1.2.3", "1.2.3"), 0)
    assert_equal(compare_versions("1.2.4", "1.2.3"), 1)
    assert_equal(compare_versions("1.2", "1.2.1"), -1)
    assert_equal(compare_versions("2.0.0-beta", "1.9.9"), 1)
    assert_true(is_newer_version("0.5.0", "0.4.12"))
    assert_equal(is_newer_version("abc", "0.4.12"), False)
    assert_equal(is_newer_version("1.0.0-rc1", "0.9.0"), False)
    var plan = plan_update("0.4.12", "0.5.0", "/usr/local/bin/mochi")
    assert_true(plan.update_available)
    assert_equal(plan.backup, "/usr/local/bin/mochi_backup")
    assert_equal(plan.executable, "/usr/local/bin/mochi")


def test_binary_backup_replace_and_restore() raises:
    try:
        remove(TEST_DIR + "/mochi")
        remove(TEST_DIR + "/download")
        remove(TEST_DIR + "/mochi_backup")
    except:
        pass
    makedirs(TEST_DIR, exist_ok=True)
    with open(TEST_DIR + "/mochi", "w") as file:
        file.write("old")
    with open(TEST_DIR + "/download", "w") as file:
        file.write("new")
    var backup = TEST_DIR + "/mochi_backup"
    replace_from_download(TEST_DIR + "/download", TEST_DIR + "/mochi", backup)
    assert_equal(open(TEST_DIR + "/mochi", "r").read(), "new")
    assert_equal(open(backup, "r").read(), "old")
    restore_backup(backup, TEST_DIR + "/mochi")
    assert_equal(open(TEST_DIR + "/mochi", "r").read(), "old")


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
