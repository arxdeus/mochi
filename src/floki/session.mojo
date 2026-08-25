"""Minimal Floki-compatible session built on mojo-curl 0.4.2.

Derived from the MIT-licensed Floki Session API by Mikhail Tavarez. This
maintained subset intentionally contains only request/response streaming.
"""

from std.ffi import c_char, c_size_t

from mojo_curl import CurlList, Easy, Result
from mojo_curl.c.types import MutExternalPointer

from mochi.types import CancellationToken


comptime ChunkCallback = def(String, Pointer[NoneType, MutUntrackedOrigin]) thin -> None


@fieldwise_init
struct Response(Copyable, Movable):
    var status: Int
    var headers: Dict[String, String]
    var body: String


struct _StreamState(Movable):
    var callback: ChunkCallback
    var userdata: Pointer[NoneType, MutUntrackedOrigin]
    var body: String
    var error: String
    var cancel: CancellationToken

    def __init__(
        out self,
        callback: ChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
        var cancel: CancellationToken,
    ):
        self.callback = callback
        self.userdata = userdata
        self.body = ""
        self.error = ""
        self.cancel = cancel^


def _write_stream(
    contents: MutExternalPointer[c_char],
    size: c_size_t,
    count: c_size_t,
    userdata: MutExternalPointer[NoneType],
) abi("C") -> c_size_t:
    var byte_count = Int(size * count)
    var state = userdata.unsafe_bitcast[_StreamState]()
    if state[].cancel.is_cancelled():
        return 0
    var bytes = contents.unsafe_bitcast[UInt8]()
    var chunk = String(unsafe_from_utf8=Span(unsafe_ptr=bytes, length=byte_count))
    state[].body += chunk
    state[].callback(chunk^, state[].userdata)
    if state[].cancel.is_cancelled():
        return 0
    if state[].error != "":
        return 0
    return size * count


struct Session(Movable):
    """Floki-style reusable synchronous HTTP session with live body callbacks."""

    var easy: Easy

    def __init__(out self) raises:
        self.easy = Easy()

    def request(
        mut self,
        method: String,
        url: String,
        headers: List[String],
        body: String,
        timeout_ms: Int,
    ) raises -> Response:
        def collect(chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]):
            _ = chunk
            _ = userdata

        return self.request_stream(
            method,
            url,
            headers,
            body,
            timeout_ms,
            collect,
            Pointer(to=self).unsafe_bitcast[NoneType](),
        )

    def request_stream(
        mut self,
        method: String,
        url: String,
        headers: List[String],
        body: String,
        timeout_ms: Int,
        callback: ChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
    ) raises -> Response:
        return self.request_stream_cancellable(
            method,
            url,
            headers,
            body,
            timeout_ms,
            callback,
            userdata,
            CancellationToken(),
        )

    def request_stream_cancellable(
        mut self,
        method: String,
        url: String,
        headers: List[String],
        body: String,
        timeout_ms: Int,
        callback: ChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
        var cancel: CancellationToken,
    ) raises -> Response:
        if cancel.is_cancelled():
            raise Error("operation cancelled")
        self.easy.reset()
        self._check(self.easy.url(url), "URL")
        self._check(self.easy.signal(signal=False), "signal mode")
        self._check(self.easy.ssl_verify_peer(), "TLS peer verification")
        self._check(self.easy.ssl_verify_host(), "TLS host verification")
        self._check(self.easy.timeout(timeout_ms), "timeout")
        self._check(self.easy.connect_timeout(min(timeout_ms, 30000)), "connect timeout")
        self._check(self.easy.custom_request(method), "HTTP method")

        var request_body = body
        if body != "" or method == "POST":
            self._check(self.easy.post_fields(request_body.as_bytes()), "request body")
            self._check(self.easy.post_field_size(request_body.byte_length()), "request body size")

        var header_list = CurlList()
        try:
            for header in headers:
                header_list.append(header)
            if not header_list.is_empty():
                self._check(self.easy.http_headers(header_list), "headers")

            var state = _StreamState(callback, userdata, cancel^)
            self._check(self.easy.write_function(_write_stream), "write callback")
            self._check(
                self.easy.write_data(Pointer(to=state).unsafe_bitcast[NoneType]()),
                "write callback data",
            )
            var result = self.easy.perform()
            if state.cancel.is_cancelled():
                raise Error("operation cancelled")
            if state.error != "":
                raise Error("HTTP stream callback failed: " + state.error)
            if result != Result.OK:
                raise Error("HTTP request failed: " + self.easy.describe_error(result))
            var response_headers = self.easy.headers()
            return Response(Int(self.easy.response_code()), response_headers^, state.body.copy())
        finally:
            header_list^.free()

    def _check(self, result: Result, operation: String) raises:
        if result != Result.OK:
            raise Error(operation + " failed: " + self.easy.describe_error(result))
