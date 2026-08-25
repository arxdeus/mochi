"""Terminal-independent UI event, reducer, action, and view contracts."""

from mochi.json import JsonValue, parse_json


comptime UI_TRANSCRIPT_VERSION = 1


struct UiEvent(Copyable, Movable):
    comptime EDIT = 0
    comptime SUBMIT = 1
    comptime CANCEL = 2
    comptime COMMAND = 3
    comptime VIEWPORT = 4
    comptime MESSAGE = 5
    comptime COMPLETE = 6

    var tag: Int
    var text: String
    var name: String
    var role: String
    var width: Int
    var height: Int
    var offset: Int
    var auto_scroll: Bool

    def __init__(out self, tag: Int):
        self.tag = tag
        self.text = ""
        self.name = ""
        self.role = ""
        self.width = 0
        self.height = 0
        self.offset = 0
        self.auto_scroll = True

    @staticmethod
    def edit(text: String) -> Self:
        var event = Self(Self.EDIT)
        event.text = text
        return event^

    @staticmethod
    def submit() -> Self:
        return Self(Self.SUBMIT)

    @staticmethod
    def cancel() -> Self:
        return Self(Self.CANCEL)

    @staticmethod
    def command(name: String, arguments: String = "") -> Self:
        var event = Self(Self.COMMAND)
        event.name = name
        event.text = arguments
        return event^

    @staticmethod
    def viewport(
        width: Int, height: Int, offset: Int = 0, auto_scroll: Bool = True
    ) -> Self:
        var event = Self(Self.VIEWPORT)
        event.width = width
        event.height = height
        event.offset = offset
        event.auto_scroll = auto_scroll
        return event^

    @staticmethod
    def message(role: String, text: String) -> Self:
        var event = Self(Self.MESSAGE)
        event.role = role
        event.text = text
        return event^

    @staticmethod
    def complete() -> Self:
        return Self(Self.COMPLETE)


struct UiAction(Copyable, Movable):
    comptime NONE = 0
    comptime SUBMIT = 1
    comptime CANCEL = 2
    comptime COMMAND = 3

    var tag: Int
    var text: String
    var name: String

    def __init__(out self, tag: Int):
        self.tag = tag
        self.text = ""
        self.name = ""

    @staticmethod
    def none() -> Self:
        return Self(Self.NONE)

    @staticmethod
    def submit(text: String) -> Self:
        var action = Self(Self.SUBMIT)
        action.text = text
        return action^

    @staticmethod
    def cancel() -> Self:
        return Self(Self.CANCEL)

    @staticmethod
    def command(name: String, arguments: String = "") -> Self:
        var action = Self(Self.COMMAND)
        action.name = name
        action.text = arguments
        return action^

    def is_none(self) -> Bool:
        return self.tag == Self.NONE

    def is_submit(self) -> Bool:
        return self.tag == Self.SUBMIT

    def is_cancel(self) -> Bool:
        return self.tag == Self.CANCEL

    def is_command(self) -> Bool:
        return self.tag == Self.COMMAND


struct UiState(Copyable, Movable):
    var draft: String
    var roles: List[String]
    var messages: List[String]
    var busy: Bool
    var viewport_width: Int
    var viewport_height: Int
    var viewport_offset: Int
    var auto_scroll: Bool

    def __init__(out self):
        self.draft = ""
        self.roles = List[String]()
        self.messages = List[String]()
        self.busy = False
        self.viewport_width = 80
        self.viewport_height = 24
        self.viewport_offset = 0
        self.auto_scroll = True


@fieldwise_init
struct UiView(Copyable, Movable):
    var lines: List[String]
    var draft: String
    var busy: Bool
    var width: Int
    var height: Int
    var offset: Int
    var auto_scroll: Bool


struct UiReducer:
    @staticmethod
    def reduce(mut state: UiState, event: UiEvent) -> UiAction:
        if event.tag == UiEvent.EDIT:
            state.draft = event.text
            return UiAction.none()
        if event.tag == UiEvent.SUBMIT:
            return Self._submit(state)
        if event.tag == UiEvent.CANCEL:
            if state.busy:
                state.busy = False
                return UiAction.cancel()
            return UiAction.none()
        if event.tag == UiEvent.COMMAND:
            state.draft = ""
            return UiAction.command(event.name, event.text)
        if event.tag == UiEvent.VIEWPORT:
            state.viewport_width = max(1, event.width)
            state.viewport_height = max(1, event.height)
            state.auto_scroll = event.auto_scroll
            state.viewport_offset = Self._bounded_offset(
                state, event.offset, event.auto_scroll
            )
            return UiAction.none()
        if event.tag == UiEvent.MESSAGE:
            state.roles.append(event.role)
            state.messages.append(event.text)
            if state.auto_scroll:
                state.viewport_offset = Self._max_offset(state)
            return UiAction.none()
        if event.tag == UiEvent.COMPLETE:
            state.busy = False
        return UiAction.none()

    @staticmethod
    def view(state: UiState) -> UiView:
        var lines = List[String]()
        var end = min(
            len(state.messages), state.viewport_offset + state.viewport_height
        )
        for i in range(state.viewport_offset, end):
            lines.append(state.roles[i] + ": " + state.messages[i])
        return UiView(
            lines^,
            state.draft,
            state.busy,
            state.viewport_width,
            state.viewport_height,
            state.viewport_offset,
            state.auto_scroll,
        )

    @staticmethod
    def _submit(mut state: UiState) -> UiAction:
        var text = String(state.draft.strip())
        if text == "":
            return UiAction.none()
        state.draft = ""
        if text.startswith("/"):
            var command = String(text.removeprefix("/"))
            var separator = command.find(" ")
            if separator:
                var name = _byte_range(command, 0, separator.value())
                var arguments = String(
                    _byte_range(
                        command, separator.value() + 1, command.byte_length()
                    ).strip()
                )
                return UiAction.command(name^, arguments^)
            return UiAction.command(command^)
        state.busy = True
        return UiAction.submit(text^)

    @staticmethod
    def _max_offset(state: UiState) -> Int:
        return max(0, len(state.messages) - state.viewport_height)

    @staticmethod
    def _bounded_offset(state: UiState, requested: Int, auto_scroll: Bool) -> Int:
        var maximum = Self._max_offset(state)
        if auto_scroll:
            return maximum
        return min(max(0, requested), maximum)


def ui_event_to_json(event: UiEvent) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("version", JsonValue.integer(UI_TRANSCRIPT_VERSION))
    value.set("tag", JsonValue.integer(event.tag))
    value.set("text", JsonValue.string(event.text))
    value.set("name", JsonValue.string(event.name))
    value.set("role", JsonValue.string(event.role))
    value.set("width", JsonValue.integer(event.width))
    value.set("height", JsonValue.integer(event.height))
    value.set("offset", JsonValue.integer(event.offset))
    value.set("auto_scroll", JsonValue.boolean(event.auto_scroll))
    return value^


def ui_action_to_json(action: UiAction) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("version", JsonValue.integer(UI_TRANSCRIPT_VERSION))
    value.set("tag", JsonValue.integer(action.tag))
    value.set("text", JsonValue.string(action.text))
    value.set("name", JsonValue.string(action.name))
    return value^


def ui_view_to_json(view: UiView) raises -> JsonValue:
    var value = JsonValue.object()
    value.set("version", JsonValue.integer(UI_TRANSCRIPT_VERSION))
    var lines = JsonValue.array()
    for line in view.lines:
        lines.append(JsonValue.string(line))
    value.set("lines", lines^)
    value.set("draft", JsonValue.string(view.draft))
    value.set("busy", JsonValue.boolean(view.busy))
    value.set("width", JsonValue.integer(view.width))
    value.set("height", JsonValue.integer(view.height))
    value.set("offset", JsonValue.integer(view.offset))
    value.set("auto_scroll", JsonValue.boolean(view.auto_scroll))
    return value^


def ui_transcript_line(event: UiEvent, action: UiAction, view: UiView) raises -> String:
    var value = JsonValue.object()
    value.set("version", JsonValue.integer(UI_TRANSCRIPT_VERSION))
    value.set("event", ui_event_to_json(event))
    value.set("action", ui_action_to_json(action))
    value.set("view", ui_view_to_json(view))
    return value.serialize()


def validate_ui_transcript_line(line: String) raises:
    var value = parse_json(line)
    if value.kind != JsonValue.OBJECT:
        raise Error("UI transcript must be an object")
    if not value.contains("version") or value.get("version").int_value != UI_TRANSCRIPT_VERSION:
        raise Error("unsupported UI transcript version")
    if not value.contains("event") or not value.contains("action") or not value.contains("view"):
        raise Error("incomplete UI transcript")


def _byte_range(value: String, start: Int, end: Int) -> String:
    var output = String("")
    for i in range(start, end):
        output += String(value[byte=i])
    return output^
