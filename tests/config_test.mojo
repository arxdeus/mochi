from std.os import makedirs, remove
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.config import AppConfig, load_layered_config
from mochi.json import parse_json


comptime ROOT = "/tmp/mochi-config-test"


def test_recursive_layer_merge() raises:
    var base = AppConfig.from_json(
        parse_json(
            '{"model":"global","yolo":false,"provider":{"url":"one","headers":{"a":"1"}}}'
        )
    )
    var project = AppConfig.from_json(
        parse_json(
            '{"model":"project","provider":{"headers":{"b":"2"}}}'
        )
    )
    var merged = base.merged(project)
    assert_equal(merged.model.value(), "project")
    assert_false(merged.yolo.value())
    var provider = merged.raw.get("provider")
    assert_equal(provider.get("url").string_value, "one")
    assert_equal(provider.get("headers").get("a").string_value, "1")
    assert_equal(provider.get("headers").get("b").string_value, "2")


def test_load_layered_files_and_validation() raises:
    makedirs(ROOT, exist_ok=True)
    var global_path = ROOT + "/global.json"
    var project_path = ROOT + "/project.json"
    with open(global_path, "w") as file:
        file.write('{"model":"global","max_turns":10}')
    with open(project_path, "w") as file:
        file.write('{"output_format":"json","yolo":true}')
    var config = load_layered_config(global_path, project_path)
    assert_equal(config.model.value(), "global")
    assert_equal(config.output_format.value(), "json")
    assert_true(config.yolo.value())
    assert_equal(config.max_turns.value(), 10)
    with assert_raises():
        _ = AppConfig.from_json(parse_json('{"max_turns":0}'))
    with assert_raises():
        _ = AppConfig.from_json(parse_json('{"output_format":"yaml"}'))
    remove(global_path)
    remove(project_path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
