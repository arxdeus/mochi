from std.ffi import c_int, external_call
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from mochi.http import FlokiTransport, HttpRequest, HttpResponse, MockTransport
from mochi.types import CancellationToken


struct ChunkLog(Movable):
    var values: List[String]

    def __init__(out self):
        self.values = List[String]()


def record_chunk(chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]):
    userdata.unsafe_bitcast[ChunkLog]()[].values.append(chunk)


struct CancellingChunkLog(Movable):
    var values: List[String]
    var cancel: CancellationToken

    def __init__(out self, var cancel: CancellationToken):
        self.values = List[String]()
        self.cancel = cancel^


def record_and_cancel(
    chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]
):
    var state = userdata.unsafe_bitcast[CancellingChunkLog]()
    state[].values.append(chunk)
    state[].cancel.cancel()


def test_mock_buffered_request_capture() raises:
    var transport = MockTransport()
    var queued = HttpResponse(201, "created")
    queued.add_header("Content-Type", "application/json")
    transport.enqueue(queued)
    var request = HttpRequest("POST", "https://fixture.invalid/items")
    request.body = "{}"
    var response = transport.perform(request)
    assert_equal(response.status, 201)
    assert_equal(response.body, "created")
    assert_equal(response.content_type(), "application/json")
    assert_equal(len(transport.requests), 1)
    assert_equal(transport.requests[0].body, "{}")


def test_mock_streams_in_queued_boundaries() raises:
    var transport = MockTransport()
    var response = HttpResponse(200, "one-two")
    var chunks: List[String] = ["one-", "two"]
    transport.enqueue_stream(response, chunks)
    var log = ChunkLog()
    var result = transport.perform_stream(
        HttpRequest("GET", "https://fixture.invalid/stream"),
        record_chunk,
        Pointer(to=log).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
    )
    assert_equal(result.body, "one-two")
    assert_equal(len(log.values), 2)
    assert_equal(log.values[0], "one-")
    assert_equal(log.values[1], "two")


def test_cancellable_stream_stops_during_transfer() raises:
    var transport = MockTransport()
    var chunks: List[String] = ["first", "second", "third"]
    transport.enqueue_stream(HttpResponse(200, "firstsecondthird"), chunks)
    var cancel = CancellationToken()
    var log = CancellingChunkLog(cancel.copy())
    with assert_raises():
        _ = transport.perform_stream_cancellable(
            HttpRequest("GET", "https://fixture.invalid/stream"),
            record_and_cancel,
            Pointer(to=log).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
            cancel.copy(),
        )
    assert_equal(len(log.values), 1)
    assert_equal(log.values[0], "first")


def test_floki_cancels_active_http_fixture() raises:
    var port = Int(external_call["mochi_http_fixture_start", c_int]())
    assert_true(port > 0)
    var transport = FlokiTransport()
    var cancel = CancellationToken()
    cancel.cancel_after(100)
    var log = ChunkLog()
    with assert_raises():
        _ = transport.perform_stream_cancellable(
            HttpRequest("GET", "http://127.0.0.1:" + String(port) + "/stream"),
            record_chunk,
            Pointer(to=log).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
            cancel.copy(),
        )
    assert_true(cancel.is_cancelled())


def test_mock_requires_queued_response() raises:
    var transport = MockTransport()
    with assert_raises():
        _ = transport.perform(HttpRequest("GET", "https://fixture.invalid"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
