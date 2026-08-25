from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from mochi.extension_contract import (
    EXTENSION_PROTOCOL,
    EXTENSION_PROTOCOL_VERSION,
    ExtensionCapabilities,
    ExtensionEnvelope,
    ExtensionSession,
)
from mochi.json import JsonValue


def _capabilities() raises -> ExtensionCapabilities:
    var caps = ExtensionCapabilities()
    caps.host_calls = True
    caps.concurrent_calls = True
    caps.cancellation = True
    caps.reload = True
    caps.ui_actions = True
    caps.ui_events = True
    caps.max_in_flight = 2
    caps.max_buffered = 4
    caps.validate()
    return caps^


def test_capability_golden_codec() raises:
    assert_equal(EXTENSION_PROTOCOL, "mochi.extension")
    assert_equal(EXTENSION_PROTOCOL_VERSION, 1)
    var encoded = _capabilities().to_json().serialize()
    assert_equal(
        encoded,
        '{"host_calls":true,"concurrent_calls":true,"cancellation":true,"reload":true,"ui_actions":true,"ui_events":true,"max_in_flight":2,"max_buffered":4}',
    )
    var decoded = ExtensionCapabilities.from_json(_capabilities().to_json())
    assert_equal(decoded.max_in_flight, 2)
    assert_true(decoded.ui_actions)


def test_bidirectional_envelope_codec() raises:
    var params = JsonValue.object()
    params.set("name", JsonValue.string("read"))
    var request = ExtensionEnvelope.request(7, "host/invoke", params^)
    var parsed = ExtensionEnvelope.parse(request.to_line())
    assert_equal(parsed.kind, ExtensionEnvelope.REQUEST)
    assert_equal(parsed.id, 7)
    assert_equal(parsed.method, "host/invoke")
    var notification = ExtensionEnvelope.notification(
        "ui/event", JsonValue.object()
    )
    var decoded = ExtensionEnvelope.parse(notification.to_line())
    assert_equal(decoded.kind, ExtensionEnvelope.NOTIFICATION)
    assert_equal(decoded.method, "ui/event")


def test_ordering_reentrancy_backpressure_and_cancellation() raises:
    var session = ExtensionSession(_capabilities())
    var first = session.request("plugin/invoke", JsonValue.object())
    var second = session.request("plugin/invoke", JsonValue.object())
    assert_equal(first, 1)
    assert_equal(second, 2)
    with assert_raises():
        _ = session.request("plugin/invoke", JsonValue.object())
    session.cancel(first, "user")
    assert_equal(len(session.outbound), 3)
    assert_equal(session.outbound[2].method, "$/cancelRequest")

    session.accept(ExtensionEnvelope.response(second, JsonValue.null()))
    assert_equal(len(session.pending_ids), 1)
    session.accept(ExtensionEnvelope.response(first, JsonValue.null()))
    assert_equal(len(session.pending_ids), 0)

    session.accept(
        ExtensionEnvelope.request(99, "host/invoke", JsonValue.object())
    )
    with assert_raises():
        session.accept(ExtensionEnvelope.response(100, JsonValue.null()))


def test_reload_ownership_and_ui_negotiation() raises:
    var caps = _capabilities()
    var borrowed = ExtensionSession(caps.copy(), ExtensionSession.BORROWED)
    assert_false(borrowed.should_terminate_process())
    _ = borrowed.request("plugin/invoke", JsonValue.object())
    with assert_raises():
        borrowed.reload()
    borrowed.accept(ExtensionEnvelope.response(1, JsonValue.null()))
    borrowed.reload()
    assert_equal(borrowed.generation, 2)
    assert_equal(borrowed.next_id, 1)

    var owned = ExtensionSession(caps^)
    assert_true(owned.should_terminate_process())
    assert_true(owned.capabilities.ui_actions)
    assert_true(owned.capabilities.ui_events)
    owned.close()
    with assert_raises():
        owned.notify("ui/event", JsonValue.object())


def test_serial_and_buffer_bounds() raises:
    var serial = ExtensionCapabilities()
    serial.max_in_flight = 2
    with assert_raises():
        serial.validate()
    var caps = _capabilities()
    caps.max_buffered = 1
    var session = ExtensionSession(caps^)
    _ = session.request("one", JsonValue.object())
    with assert_raises():
        session.notify("two", JsonValue.object())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
