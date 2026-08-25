"""Transport-neutral HTTP contracts and production/test transports."""

from floki import Session


comptime HttpChunkCallback = def(String, Pointer[NoneType, MutUntrackedOrigin]) thin -> None


@fieldwise_init
struct HttpHeader(Copyable, Movable):
    var name: String
    var value: String


struct HttpRequest(Copyable, Movable):
    var method: String
    var url: String
    var headers: List[HttpHeader]
    var body: String
    var timeout_ms: Int

    def __init__(out self, method: String, url: String):
        self.method = method
        self.url = url
        self.headers = List[HttpHeader]()
        self.body = ""
        self.timeout_ms = 120000

    def add_header(mut self, name: String, value: String):
        self.headers.append(HttpHeader(name, value))


struct HttpResponse(Copyable, Movable):
    var status: Int
    var headers: List[HttpHeader]
    var body: String

    def __init__(out self, status: Int = 0, body: String = ""):
        self.status = status
        self.headers = List[HttpHeader]()
        self.body = body

    def add_header(mut self, name: String, value: String):
        self.headers.append(HttpHeader(name, value))

    def add_header_line(mut self, var line: String):
        var stripped = String(line.strip())
        line = stripped^
        if line == "":
            return
        var separator = _find_header_separator(line)
        if separator <= 0:
            return
        self.add_header(
            String(_byte_range(line, 0, separator).strip()),
            String(_byte_range(line, separator + 1, line.byte_length()).strip()),
        )

    def header(self, name: String) -> String:
        var wanted = _ascii_lower(name)
        var result = String("")
        for header in self.headers:
            if _ascii_lower(header.name) == wanted:
                result = header.value
        return result^

    def content_type(self) -> String:
        return self.header("Content-Type")

    def mcp_session_id(self) -> String:
        return self.header("Mcp-Session-Id")


trait HttpTransport:
    """Synchronous HTTP contract. Streaming callbacks run during transfer."""

    def perform(mut self, request: HttpRequest) raises -> HttpResponse: ...

    def perform_stream(
        mut self,
        request: HttpRequest,
        callback: HttpChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
    ) raises -> HttpResponse: ...


struct FlokiTransport(HttpTransport, Movable):
    """Production transport adapting the maintained Floki-style Session subset."""

    var session: Session

    def __init__(out self) raises:
        self.session = Session()

    def perform(mut self, request: HttpRequest) raises -> HttpResponse:
        def ignore(chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]):
            _ = chunk
            _ = userdata

        return self.perform_stream(
            request,
            ignore,
            Pointer(to=self).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
        )

    def perform_stream(
        mut self,
        request: HttpRequest,
        callback: HttpChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
    ) raises -> HttpResponse:
        var lines = List[String]()
        for header in request.headers:
            lines.append(header.name + ": " + header.value)
        var response = self.session.request_stream(
            request.method,
            request.url,
            lines^,
            request.body,
            request.timeout_ms,
            callback,
            userdata,
        )
        var result = HttpResponse(response.status, response.body^)
        for entry in response.headers.items():
            result.add_header(entry.key, entry.value)
        return result^


struct MockTransport(HttpTransport, Copyable, Movable):
    """Deterministic injectable transport that replays queued response chunks."""

    var responses: List[HttpResponse]
    var chunks: List[List[String]]
    var requests: List[HttpRequest]

    def __init__(out self):
        self.responses = List[HttpResponse]()
        self.chunks = List[List[String]]()
        self.requests = List[HttpRequest]()

    def enqueue(mut self, response: HttpResponse):
        self.responses.append(response.copy())
        var body_chunks: List[String] = [response.body]
        self.chunks.append(body_chunks^)

    def enqueue_stream(mut self, response: HttpResponse, chunks: List[String]):
        self.responses.append(response.copy())
        self.chunks.append(chunks.copy())

    def perform(mut self, request: HttpRequest) raises -> HttpResponse:
        def ignore(chunk: String, userdata: Pointer[NoneType, MutUntrackedOrigin]):
            _ = chunk
            _ = userdata

        return self.perform_stream(
            request,
            ignore,
            Pointer(to=self).unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin](),
        )

    def perform_stream(
        mut self,
        request: HttpRequest,
        callback: HttpChunkCallback,
        userdata: Pointer[NoneType, MutUntrackedOrigin],
    ) raises -> HttpResponse:
        self.requests.append(request.copy())
        if len(self.responses) == 0:
            raise Error("MockTransport has no queued response")
        var response = self.responses.pop(0)
        var response_chunks = self.chunks.pop(0)
        for chunk in response_chunks:
            callback(chunk, userdata)
        return response^


def _find_header_separator(value: String) -> Int:
    for i in range(value.byte_length()):
        if UInt8(ord(value[byte=i])) == UInt8(58):
            return i
    return -1


def _byte_range(value: String, start: Int, end: Int) -> String:
    var output = String("")
    for i in range(start, end):
        output += String(value[byte=i])
    return output^


def _ascii_lower(value: String) -> String:
    var output = String("")
    for i in range(value.byte_length()):
        var byte = Int(UInt8(ord(value[byte=i])))
        if byte >= 65 and byte <= 90:
            byte += 32
        output += chr(byte)
    return output^
