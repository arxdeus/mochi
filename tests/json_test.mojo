from mochi.json import JsonValue, parse_json, serialize_json
from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite


def test_scalars_and_whitespace() raises:
    assert_true(parse_json(" null \n").is_null())
    assert_true(parse_json("true").bool_value)
    assert_false(parse_json("false").bool_value)
    assert_equal(parse_json("-42").int_value, -42)
    assert_equal(parse_json("1.25e2").float_value, 125.0)
    assert_equal(parse_json("\"hello\"").string_value, "hello")


def test_arrays_objects_and_helpers() raises:
    var value = parse_json("{\"name\":\"mochi\",\"items\":[null,2,false]}")
    assert_true(value.contains("name"))
    assert_equal(value.get("name").string_value, "mochi")
    assert_equal(len(value.get("items").array_value), 3)
    value.set("name", JsonValue.string("Mojo"))
    value.set("added", JsonValue.integer(7))
    assert_equal(value.get("name").string_value, "Mojo")
    assert_equal(value.get("added").int_value, 7)
    assert_true(value.remove("added"))
    assert_false(value.contains("added"))
    assert_false(value.remove("missing"))


def test_strings_and_round_trip() raises:
    var source = "{\"quote\":\"a\\\"b\\\\c\\n\",\"unicode\":\"\\u263a\\ud83d\\ude00\"}"
    var value = parse_json(source)
    assert_equal(value.get("quote").string_value, "a\"b\\c\n")
    assert_equal(value.get("unicode").string_value, "☺😀")
    var encoded = serialize_json(value)
    var decoded = parse_json(encoded)
    assert_equal(decoded.get("quote").string_value, "a\"b\\c\n")
    assert_equal(decoded.get("unicode").string_value, "☺😀")


def test_serializer() raises:
    var value = JsonValue.object()
    value.set("ok", JsonValue.boolean(True))
    var items = JsonValue.array()
    items.append(JsonValue.integer(1))
    items.append(JsonValue.string("x\n"))
    value.set("items", items^)
    assert_equal(serialize_json(value), "{\"ok\":true,\"items\":[1,\"x\\n\"]}")


def test_invalid_input() raises:
    with assert_raises():
        _ = parse_json("")
    with assert_raises():
        _ = parse_json("[1,]")
    with assert_raises():
        _ = parse_json("01")
    with assert_raises():
        _ = parse_json("true false")
    with assert_raises():
        _ = parse_json("\"\\uD800\"")
    with assert_raises():
        _ = JsonValue.integer(1).get("x")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
