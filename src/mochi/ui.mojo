"""Terminal-independent UI event, reducer, action, and view contracts."""

from mochi.json import JsonValue, parse_json
from mochi.types import Message


comptime UI_TRANSCRIPT_VERSION = 1


@fieldwise_init
struct UiRect(Copyable, Movable, Equatable):
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    def contains(self, row: Int, col: Int) -> Bool:
        return (
            self.width > 0 and self.height > 0
            and col >= self.x and col < self.x + self.width
            and row >= self.y and row < self.y + self.height
        )


@fieldwise_init
struct DocPos(Copyable, Movable, Equatable):
    var row: Int
    var col: Int


@fieldwise_init
struct ScreenSelection(Copyable, Movable, Equatable):
    var start_row: Int
    var start_col: Int
    var end_row: Int
    var end_col: Int


struct Selection(Copyable, Movable):
    comptime MESSAGES = 0
    comptime INPUT = 1
    comptime OVERLAY = 2

    var anchor: DocPos
    var cursor: DocPos
    var area: UiRect
    var zone: Int

    def __init__(
        out self,
        row: Int,
        col: Int,
        area: UiRect,
        zone: Int,
        scroll_offset: Int = 0,
    ):
        var pos = DocPos(
            scroll_offset + min(max(row, area.y), area.y + max(0, area.height - 1)) - area.y,
            min(max(col, area.x), area.x + max(0, area.width - 1)),
        )
        self.anchor = pos.copy()
        self.cursor = pos^
        self.area = area.copy()
        self.zone = zone

    def update(mut self, row: Int, col: Int, scroll_offset: Int = 0):
        self.cursor = DocPos(
            scroll_offset
            + min(max(row, self.area.y), self.area.y + max(0, self.area.height - 1))
            - self.area.y,
            min(max(col, self.area.x), self.area.x + max(0, self.area.width - 1)),
        )

    def is_empty(self) -> Bool:
        return self.anchor == self.cursor

    def normalized(self) -> Tuple[DocPos, DocPos]:
        if (
            self.anchor.row < self.cursor.row
            or self.anchor.row == self.cursor.row and self.anchor.col <= self.cursor.col
        ):
            return (self.anchor.copy(), self.cursor.copy())
        return (self.cursor.copy(), self.anchor.copy())

    def to_screen(self, scroll_offset: Int = 0) -> Optional[ScreenSelection]:
        var bounds = self.normalized()
        var start = bounds[0].copy()
        var end = bounds[1].copy()
        if start == end:
            return None
        var view_bottom = scroll_offset + self.area.height
        if end.row < scroll_offset or start.row >= view_bottom:
            return None
        var start_row = self.area.y
        var start_col = self.area.x
        if start.row >= scroll_offset:
            start_row += start.row - scroll_offset
            start_col = start.col
        var end_row = self.area.y + max(0, self.area.height - 1)
        var end_col = self.area.x + max(0, self.area.width - 1)
        if end.row < view_bottom:
            end_row = self.area.y + end.row - scroll_offset
            end_col = end.col
        return Optional(ScreenSelection(start_row, start_col, end_row, end_col))


@fieldwise_init
struct SelectableZone(Copyable, Movable):
    var area: UiRect
    var zone: Int


struct UiEvent(Copyable, Movable):
    comptime EDIT = 0
    comptime SUBMIT = 1
    comptime CANCEL = 2
    comptime COMMAND = 3
    comptime VIEWPORT = 4
    comptime MESSAGE = 5
    comptime COMPLETE = 6
    comptime MOVE_CURSOR = 7
    comptime DELETE_BACKWARD = 8
    comptime INSERT = 9
    comptime HISTORY_UP = 10
    comptime HISTORY_DOWN = 11
    comptime CONTINUE_LINE = 12
    comptime PASTE_SPACED = 13
    comptime SCROLL = 14
    comptime SCROLL_BOTTOM = 15
    comptime SEARCH_OPEN = 16
    comptime SEARCH_QUERY = 17
    comptime SEARCH_NEXT = 18
    comptime SEARCH_PREVIOUS = 19
    comptime SEARCH_CLOSE = 20
    comptime SEARCH_SELECT = 21
    comptime SEARCH_BACKSPACE = 22
    comptime COMMAND_NEXT = 23
    comptime COMMAND_PREVIOUS = 24
    comptime PICKER_OPEN = 25
    comptime PICKER_NEXT = 26
    comptime PICKER_PREVIOUS = 27
    comptime PICKER_TOGGLE = 28
    comptime PICKER_CLOSE = 29
    comptime PICKER_FILTER = 30
    comptime PICKER_BACKSPACE = 31
    comptime PICKER_PAGE_NEXT = 32
    comptime PICKER_PAGE_PREVIOUS = 33
    comptime MOUSE_DOWN = 34
    comptime MOUSE_DRAG = 35
    comptime MOUSE_UP = 36
    comptime OVERLAY_OPEN = 37
    comptime OVERLAY_CLOSE = 38

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

    @staticmethod
    def move_cursor(offset: Int) -> Self:
        var event = Self(Self.MOVE_CURSOR)
        event.offset = offset
        return event^

    @staticmethod
    def delete_backward() -> Self:
        return Self(Self.DELETE_BACKWARD)

    @staticmethod
    def insert(text: String) -> Self:
        var event = Self(Self.INSERT)
        event.text = text
        return event^

    @staticmethod
    def history_up() -> Self:
        return Self(Self.HISTORY_UP)

    @staticmethod
    def history_down() -> Self:
        return Self(Self.HISTORY_DOWN)

    @staticmethod
    def continue_line() -> Self:
        return Self(Self.CONTINUE_LINE)

    @staticmethod
    def paste_spaced(text: String) -> Self:
        var event = Self(Self.PASTE_SPACED)
        event.text = text
        return event^

    @staticmethod
    def scroll(offset: Int) -> Self:
        var event = Self(Self.SCROLL)
        event.offset = offset
        return event^

    @staticmethod
    def scroll_bottom() -> Self:
        return Self(Self.SCROLL_BOTTOM)

    @staticmethod
    def search_open() -> Self:
        return Self(Self.SEARCH_OPEN)

    @staticmethod
    def search_query(text: String) -> Self:
        var event = Self(Self.SEARCH_QUERY)
        event.text = text
        return event^

    @staticmethod
    def search_next() -> Self:
        return Self(Self.SEARCH_NEXT)

    @staticmethod
    def search_previous() -> Self:
        return Self(Self.SEARCH_PREVIOUS)

    @staticmethod
    def search_close() -> Self:
        return Self(Self.SEARCH_CLOSE)

    @staticmethod
    def search_select() -> Self:
        return Self(Self.SEARCH_SELECT)

    @staticmethod
    def search_backspace() -> Self:
        return Self(Self.SEARCH_BACKSPACE)

    @staticmethod
    def command_next() -> Self:
        return Self(Self.COMMAND_NEXT)

    @staticmethod
    def command_previous() -> Self:
        return Self(Self.COMMAND_PREVIOUS)

    @staticmethod
    def picker_open(name: String, text: String) -> Self:
        var event = Self(Self.PICKER_OPEN)
        event.name = name
        event.text = text
        return event^

    @staticmethod
    def picker_next() -> Self:
        return Self(Self.PICKER_NEXT)

    @staticmethod
    def picker_previous() -> Self:
        return Self(Self.PICKER_PREVIOUS)

    @staticmethod
    def picker_toggle() -> Self:
        return Self(Self.PICKER_TOGGLE)

    @staticmethod
    def picker_close() -> Self:
        return Self(Self.PICKER_CLOSE)

    @staticmethod
    def picker_filter(text: String) -> Self:
        var event = Self(Self.PICKER_FILTER)
        event.text = text
        return event^

    @staticmethod
    def picker_backspace() -> Self:
        return Self(Self.PICKER_BACKSPACE)

    @staticmethod
    def picker_page_next() -> Self:
        return Self(Self.PICKER_PAGE_NEXT)

    @staticmethod
    def picker_page_previous() -> Self:
        return Self(Self.PICKER_PAGE_PREVIOUS)

    @staticmethod
    def mouse_down(row: Int, col: Int) -> Self:
        var event = Self(Self.MOUSE_DOWN)
        event.height = row
        event.width = col
        return event^

    @staticmethod
    def mouse_drag(row: Int, col: Int) -> Self:
        var event = Self(Self.MOUSE_DRAG)
        event.height = row
        event.width = col
        return event^

    @staticmethod
    def mouse_up(row: Int, col: Int) -> Self:
        var event = Self(Self.MOUSE_UP)
        event.height = row
        event.width = col
        return event^

    @staticmethod
    def overlay_open(name: String) -> Self:
        var event = Self(Self.OVERLAY_OPEN)
        event.name = name
        return event^

    @staticmethod
    def overlay_close() -> Self:
        return Self(Self.OVERLAY_CLOSE)


def decode_sgr_mouse(encoded: String, final: Int) -> Optional[UiEvent]:
    if final != 77 and final != 109:
        return None
    var fields = encoded.split(";")
    if len(fields) != 3:
        return None
    var button = _parse_nonnegative_int(String(fields[0]))
    var col = _parse_nonnegative_int(String(fields[1])) - 1
    var row = _parse_nonnegative_int(String(fields[2])) - 1
    if button < 0 or col < 0 or row < 0:
        return None
    if button == 64:
        return Optional(UiEvent.scroll(-3))
    if button == 65:
        return Optional(UiEvent.scroll(3))
    if final == 109:
        return Optional(UiEvent.mouse_up(row, col))
    if (button & 32) != 0:
        return Optional(UiEvent.mouse_drag(row, col))
    if (button & 3) == 0:
        return Optional(UiEvent.mouse_down(row, col))
    return None


def _parse_nonnegative_int(value: String) -> Int:
    if value == "":
        return -1
    var result = 0
    for cp in value.codepoints():
        var digit = Int(cp.to_u32()) - 48
        if digit < 0 or digit > 9:
            return -1
        result = result * 10 + digit
    return result


struct UiAction(Copyable, Movable):
    comptime NONE = 0
    comptime SUBMIT = 1
    comptime CANCEL = 2
    comptime COMMAND = 3
    comptime PICKER_TOGGLE = 4

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

    @staticmethod
    def picker_toggle(name: String, enabled: Bool) -> Self:
        var action = Self(Self.PICKER_TOGGLE)
        action.name = name
        action.text = "on" if enabled else "off"
        return action^

    def is_none(self) -> Bool:
        return self.tag == Self.NONE

    def is_submit(self) -> Bool:
        return self.tag == Self.SUBMIT

    def is_cancel(self) -> Bool:
        return self.tag == Self.CANCEL

    def is_command(self) -> Bool:
        return self.tag == Self.COMMAND

    def is_picker_toggle(self) -> Bool:
        return self.tag == Self.PICKER_TOGGLE


struct UiState(Copyable, Movable):
    var draft: String
    var roles: List[String]
    var messages: List[String]
    var busy: Bool
    var viewport_width: Int
    var viewport_height: Int
    var viewport_offset: Int
    var auto_scroll: Bool
    var cursor: Int
    var history: List[String]
    var history_index: Int
    var history_draft: String
    var command_selected: Int
    var search_open: Bool
    var search_query: String
    var search_matches: List[Int]
    var search_selected: Int
    var search_saved_offset: Int
    var search_saved_auto_scroll: Bool
    var picker_name: String
    var picker_items: List[String]
    var picker_enabled: List[Bool]
    var picker_filtered: List[Int]
    var picker_selected: Int
    var picker_filter: String
    var zones: List[SelectableZone]
    var selection: Optional[Selection]
    var selection_pending_copy: Bool
    var selection_edge_scroll: Int
    var overlay_name: String
    var overlay_modal: Bool
    var extension_commands: List[String]

    def __init__(out self):
        self.draft = ""
        self.roles = List[String]()
        self.messages = List[String]()
        self.busy = False
        self.viewport_width = 80
        self.viewport_height = 24
        self.viewport_offset = 0
        self.auto_scroll = True
        self.cursor = 0
        self.history = List[String]()
        self.history_index = -1
        self.history_draft = ""
        self.command_selected = 0
        self.search_open = False
        self.search_query = ""
        self.search_matches = List[Int]()
        self.search_selected = 0
        self.search_saved_offset = 0
        self.search_saved_auto_scroll = True
        self.picker_name = ""
        self.picker_items = List[String]()
        self.picker_enabled = List[Bool]()
        self.picker_filtered = List[Int]()
        self.picker_selected = 0
        self.picker_filter = ""
        self.zones = List[SelectableZone]()
        self.selection = None
        self.selection_pending_copy = False
        self.selection_edge_scroll = 0
        self.overlay_name = ""
        self.overlay_modal = False
        self.extension_commands = List[String]()

    def add_zone(mut self, area: UiRect, zone: Int):
        self.zones.append(SelectableZone(area.copy(), zone))

    def clear_zones(mut self):
        self.zones.clear()

    def zone_at(self, row: Int, col: Int) -> Optional[SelectableZone]:
        for i in range(len(self.zones) - 1, -1, -1):
            if self.zones[i].area.contains(row, col):
                return Optional(self.zones[i].copy())
        return None

    def set_extension_commands(mut self, commands: List[String]):
        self.extension_commands = commands.copy()

    def set_history(mut self, var history: List[String]):
        self.history = history^
        self.history_index = -1
        self.history_draft = ""

    def set_transcript(mut self, messages: List[Message]):
        self.roles.clear()
        self.messages.clear()
        for message in messages:
            if message.role == "assistant":
                if message.content != "":
                    self.roles.append("assistant")
                    self.messages.append(message.content)
                for call in message.tool_calls:
                    self.roles.append("tool call")
                    self.messages.append(call.name)
            elif message.role == "tool":
                var role = String("tool result")
                if message.name != "":
                    role += " " + message.name
                self.roles.append(role^)
                self.messages.append(message.content)
            elif message.content != "":
                self.roles.append(message.role)
                self.messages.append(message.content)
        if self.auto_scroll:
            self.viewport_offset = max(0, len(self.messages) - self.viewport_height)


@fieldwise_init
struct UiView(Copyable, Movable):
    var lines: List[String]
    var draft: String
    var busy: Bool
    var width: Int
    var height: Int
    var offset: Int
    var auto_scroll: Bool


comptime BUILTIN_COMMANDS = [
    "tasks", "compact", "new", "help", "usage", "queue", "model", "theme",
    "mcp", "login", "cd", "btw", "yolo", "thinking", "fast", "workflow",
    "exit", "reload",
]

comptime BUILTIN_COMMAND_MAX_ARGS = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2147483647, 0, 1, 0, 0, 0, 0,
]

comptime BUILTIN_COMMAND_DESCRIPTIONS = [
    "Browse and search tasks",
    "Summarize and compact conversation history",
    "Start a new session",
    "Show keybindings",
    "Show token usage breakdown",
    "Remove items from queue",
    "Switch model",
    "Switch color theme",
    "Configure MCP servers",
    "Authenticate with an LLM provider",
    "Change working directory",
    "Ask a quick question (no tools, no history pollution)",
    "Toggle YOLO mode (skip all permission prompts)",
    "Toggle extended thinking",
    "Toggle Anthropic fast mode (Opus only)",
    "Toggle workflow mode",
    "Exit the application",
    "Reload plugins and config",
]


def command_names() -> List[String]:
    var result = List[String]()
    for name in materialize[BUILTIN_COMMANDS]():
        result.append(String(name))
    return result^


def is_builtin_command(name: String) -> Bool:
    var normalized = _ascii_lower(name)
    for candidate in materialize[BUILTIN_COMMANDS]():
        var plain = String(candidate)
        if normalized == plain or normalized == "/" + plain:
            return True
    return False


def command_max_args() -> List[Int]:
    var result = List[Int]()
    for maximum in materialize[BUILTIN_COMMAND_MAX_ARGS]():
        result.append(Int(maximum))
    return result^


def command_descriptions() -> List[String]:
    var result = List[String]()
    for description in materialize[BUILTIN_COMMAND_DESCRIPTIONS]():
        result.append(String(description))
    return result^


def command_help_lines() -> List[String]:
    var names = command_names()
    var descriptions = command_descriptions()
    var result = List[String]()
    for i in range(len(names)):
        result.append("/" + names[i] + "  " + descriptions[i])
    return result^


def transcript_messages(messages: List[Message]) -> List[String]:
    var lines = List[String]()
    for message in messages:
        if message.role == "assistant":
            if message.content != "":
                lines.append("assistant: " + message.content)
            for call in message.tool_calls:
                lines.append("tool call: " + call.name)
        elif message.role == "tool":
            var label = "tool result"
            if message.name != "":
                label += " " + message.name
            lines.append(label + ": " + message.content)
        elif message.content != "":
            lines.append(message.role + ": " + message.content)
    return lines^


def search_result_lines(state: UiState) -> List[String]:
    var lines = List[String]()
    for i in range(len(state.search_matches)):
        var message_index = state.search_matches[i]
        var marker = "  "
        if i == state.search_selected:
            marker = "> "
        lines.append(
            marker + state.roles[message_index] + ": "
            + _matched_line(state.messages[message_index], state.search_query)
        )
    return lines^


def command_completion(query: String, selected: Int = 0) -> String:
    var matches = command_matches(query.copy())
    if len(matches) == 0:
        return query
    var index = min(max(0, selected), len(matches) - 1)
    if " " in query or "\t" in query:
        return query
    return "/" + matches[index] + " "


def command_matches(query: String) -> List[String]:
    if not query.startswith("/") and query != "":
        return List[String]()
    var stripped = String(query.removeprefix("/"))
    var parts = List[String]()
    for part in stripped.split():
        parts.append(String(part))
    var command_word = stripped.copy()
    if len(parts) > 0:
        command_word = parts[0]
    var trailing_space = stripped.endswith(" ") or stripped.endswith("\t")
    var argument_count = max(0, len(parts) - 1)
    if trailing_space:
        argument_count = len(parts)
    var needle = _ascii_lower(command_word)
    var exact = List[String]()
    var partial = List[String]()
    var maximums = command_max_args()
    var names = command_names()
    for i in range(len(names)):
        if argument_count > maximums[i]:
            continue
        var candidate = names[i]
        if needle == "" or candidate.startswith(needle):
            exact.append(candidate^)
        elif _subsequence(needle, candidate):
            partial.append(candidate^)
    for candidate in partial:
        exact.append(candidate)
    return exact^


def _subsequence(needle: String, candidate: String) -> Bool:
    var index = 0
    for cp in candidate.codepoint_slices():
        if index < needle.count_codepoints():
            var target = String("")
            var current = 0
            for part in needle.codepoint_slices():
                if current == index:
                    target = String(part)
                    break
                current += 1
            if String(cp) == target:
                index += 1
    return index == needle.count_codepoints()


struct UiReducer:
    @staticmethod
    def reduce(mut state: UiState, event: UiEvent) -> UiAction:
        if state.overlay_modal and event.tag not in [
            UiEvent.OVERLAY_CLOSE,
            UiEvent.MOUSE_DOWN,
            UiEvent.MOUSE_DRAG,
            UiEvent.MOUSE_UP,
        ]:
            return UiAction.none()
        if event.tag == UiEvent.EDIT:
            state.draft = event.text
            state.cursor = event.text.count_codepoints()
            state.command_selected = 0
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
            state.cursor = 0
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
        elif event.tag == UiEvent.MOVE_CURSOR:
            state.cursor = min(
                max(0, state.cursor + event.offset),
                state.draft.count_codepoints(),
            )
        elif event.tag == UiEvent.DELETE_BACKWARD:
            Self._delete_backward(state)
        elif event.tag == UiEvent.INSERT:
            Self._insert(state, event.text)
        elif event.tag == UiEvent.HISTORY_UP:
            Self._history_up(state)
        elif event.tag == UiEvent.HISTORY_DOWN:
            Self._history_down(state)
        elif event.tag == UiEvent.CONTINUE_LINE:
            Self._continue_line(state)
        elif event.tag == UiEvent.PASTE_SPACED:
            Self._paste_spaced(state, event.text)
        elif event.tag == UiEvent.SCROLL:
            state.auto_scroll = False
            state.viewport_offset = Self._bounded_offset(
                state, state.viewport_offset + event.offset, False
            )
        elif event.tag == UiEvent.SCROLL_BOTTOM:
            state.auto_scroll = True
            state.viewport_offset = Self._max_offset(state)
        elif event.tag == UiEvent.SEARCH_OPEN:
            Self._search_open(state)
        elif event.tag == UiEvent.SEARCH_QUERY:
            Self._search_update(state, event.text)
        elif event.tag == UiEvent.SEARCH_NEXT:
            Self._search_move(state, 1)
        elif event.tag == UiEvent.SEARCH_PREVIOUS:
            Self._search_move(state, -1)
        elif event.tag == UiEvent.SEARCH_CLOSE:
            Self._search_close(state, True)
        elif event.tag == UiEvent.SEARCH_SELECT:
            Self._search_close(state, len(state.search_matches) == 0)
        elif event.tag == UiEvent.SEARCH_BACKSPACE:
            if state.search_open and state.search_query.count_codepoints() > 0:
                Self._search_update(
                    state,
                    _codepoint_prefix(
                        state.search_query,
                        state.search_query.count_codepoints() - 1,
                    ),
                )
        elif event.tag == UiEvent.COMMAND_NEXT:
            Self._command_move(state, 1)
        elif event.tag == UiEvent.COMMAND_PREVIOUS:
            Self._command_move(state, -1)
        elif event.tag == UiEvent.PICKER_OPEN:
            Self._picker_open(state, event.name, event.text)
        elif event.tag == UiEvent.PICKER_NEXT:
            Self._picker_move(state, 1)
        elif event.tag == UiEvent.PICKER_PREVIOUS:
            Self._picker_move(state, -1)
        elif event.tag == UiEvent.PICKER_CLOSE:
            Self._picker_close(state)
        elif event.tag == UiEvent.PICKER_FILTER:
            state.picker_filter += event.text
            Self._picker_rebuild(state)
        elif event.tag == UiEvent.PICKER_BACKSPACE:
            if state.picker_filter.byte_length() > 0:
                state.picker_filter = _byte_range(
                    state.picker_filter, 0, state.picker_filter.byte_length() - 1
                )
                Self._picker_rebuild(state)
        elif event.tag == UiEvent.PICKER_PAGE_NEXT:
            Self._picker_page(state, 10)
        elif event.tag == UiEvent.PICKER_PAGE_PREVIOUS:
            Self._picker_page(state, -10)
        elif event.tag == UiEvent.PICKER_TOGGLE:
            if state.picker_name != "" and len(state.picker_items) > 0:
                var selected = state.picker_selected
                state.picker_enabled[selected] = not state.picker_enabled[selected]
                return UiAction.picker_toggle(
                    state.picker_items[selected], state.picker_enabled[selected]
                )
        elif event.tag == UiEvent.OVERLAY_OPEN:
            state.overlay_name = event.name
            state.overlay_modal = True
            state.selection = None
            state.selection_pending_copy = False
            state.selection_edge_scroll = 0
        elif event.tag == UiEvent.OVERLAY_CLOSE:
            state.overlay_name = ""
            state.overlay_modal = False
            if not state.selection_pending_copy:
                state.selection = None
            state.selection_edge_scroll = 0
        elif event.tag == UiEvent.MOUSE_DOWN:
            var zone = state.zone_at(event.height, event.width)
            if zone:
                if (state.overlay_modal or state.picker_name != "") and zone.value().zone != Selection.OVERLAY:
                    return UiAction.none()
                var scroll = state.viewport_offset if zone.value().zone == Selection.MESSAGES else 0
                state.selection = Optional(
                    Selection(
                        event.height,
                        event.width,
                        zone.value().area,
                        zone.value().zone,
                        scroll,
                    )
                )
                state.selection_pending_copy = False
                state.selection_edge_scroll = 0
        elif event.tag == UiEvent.MOUSE_DRAG:
            if state.selection and not state.selection_pending_copy:
                var selection = state.selection.value().copy()
                var at_top = event.height <= selection.area.y
                var at_bottom = event.height + 1 >= selection.area.y + selection.area.height
                state.selection_edge_scroll = 1 if at_top else (-1 if at_bottom else 0)
                if selection.zone == Selection.MESSAGES and state.selection_edge_scroll != 0:
                    state.auto_scroll = False
                    state.viewport_offset = Self._bounded_offset(
                        state,
                        state.viewport_offset - state.selection_edge_scroll,
                        False,
                    )
                var scroll = state.viewport_offset if selection.zone == Selection.MESSAGES else 0
                selection.update(event.height, event.width, scroll)
                state.selection = Optional(selection^)
        elif event.tag == UiEvent.MOUSE_UP:
            if state.selection and not state.selection_pending_copy:
                if state.selection.value().is_empty():
                    state.selection = None
                else:
                    state.selection_pending_copy = True
                state.selection_edge_scroll = 0
        return UiAction.none()

    @staticmethod
    def view(state: UiState) -> UiView:
        var lines = List[String]()
        var end = min(
            len(state.messages), state.viewport_offset + state.viewport_height
        )
        for i in range(state.viewport_offset, end):
            lines.append(state.roles[i] + ": " + state.messages[i])
        if state.picker_name != "":
            lines.append("[" + state.picker_name + "] " + state.picker_filter)
            if len(state.picker_filtered) == 0:
                lines.append("  No matches")
            for i in state.picker_filtered:
                var marker = "> " if i == state.picker_selected else "  "
                var toggle = "[x] " if state.picker_enabled[i] else "[ ] "
                lines.append(marker + toggle + state.picker_items[i])
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
        if len(state.history) == 0 or state.history[len(state.history) - 1] != text:
            state.history.append(text.copy())
        state.history_index = -1
        state.history_draft = ""
        state.draft = ""
        state.cursor = 0
        if text.startswith("/"):
            var slash_text = text.copy()
            var command_text = String(slash_text.removeprefix("/"))
            var command_separator = command_text.find(" ")
            var command_name = command_text
            var command_arguments = String("")
            if command_separator:
                command_name = _byte_range(
                    command_text, 0, command_separator.value()
                )
                command_arguments = String(
                    _byte_range(
                        command_text,
                        command_separator.value() + 1,
                        command_text.byte_length(),
                    ).strip()
                )
            for extension in state.extension_commands:
                if extension.lower() == command_name.lower():
                    state.command_selected = 0
                    return UiAction.command(extension, command_arguments^)
            var matches = command_matches(text.copy())
            if len(matches) > 0:
                var selected = min(state.command_selected, len(matches) - 1)
                var name = matches[selected]
                var slash_text = text.copy()
                var command = String(slash_text.removeprefix("/"))
                var separator = command.find(" ")
                var arguments = String("")
                if separator:
                    arguments = String(
                        _byte_range(
                            command, separator.value() + 1, command.byte_length()
                        ).strip()
                    )
                state.command_selected = 0
                return UiAction.command(name^, arguments^)
            state.busy = True
            return UiAction.submit(text^)
        state.busy = True
        return UiAction.submit(text^)

    @staticmethod
    def _insert(mut state: UiState, text: String):
        var before = _codepoint_prefix(state.draft, state.cursor)
        var after = _codepoint_suffix(state.draft, state.cursor)
        state.draft = before + text + after
        state.cursor += text.count_codepoints()

    @staticmethod
    def _delete_backward(mut state: UiState):
        if state.cursor <= 0:
            return
        var before = _codepoint_prefix(state.draft, state.cursor - 1)
        var after = _codepoint_suffix(state.draft, state.cursor)
        state.draft = before + after
        state.cursor -= 1

    @staticmethod
    def _paste_spaced(mut state: UiState, text: String):
        var before = _codepoint_prefix(state.draft, state.cursor)
        var after = _codepoint_suffix(state.draft, state.cursor)
        var pasted = text
        if _ends_word(before) and not pasted.startswith(" "):
            pasted = " " + pasted
        if _starts_word(after) and not pasted.endswith(" "):
            pasted += " "
        Self._insert(state, pasted^)

    @staticmethod
    def _continue_line(mut state: UiState):
        var before = _codepoint_prefix(state.draft, state.cursor)
        if before.endswith("\\"):
            Self._delete_backward(state)
        Self._insert(state, "\n")

    @staticmethod
    def _history_up(mut state: UiState):
        if len(state.history) == 0:
            return
        if state.history_index < 0:
            state.history_draft = state.draft
            state.history_index = len(state.history) - 1
        elif state.history_index > 0:
            state.history_index -= 1
        state.draft = state.history[state.history_index]
        state.cursor = state.draft.count_codepoints()

    @staticmethod
    def _history_down(mut state: UiState):
        if state.history_index < 0:
            return
        if state.history_index + 1 < len(state.history):
            state.history_index += 1
            state.draft = state.history[state.history_index]
        else:
            state.history_index = -1
            state.draft = state.history_draft
            state.history_draft = ""
        state.cursor = state.draft.count_codepoints()

    @staticmethod
    def _command_move(mut state: UiState, direction: Int):
        var matches = command_matches(state.draft)
        if len(matches) == 0:
            state.command_selected = 0
            return
        state.command_selected = (
            state.command_selected + direction + len(matches)
        ) % len(matches)

    @staticmethod
    def _picker_open(mut state: UiState, name: String, text: String):
        state.picker_name = name
        state.picker_items.clear()
        state.picker_enabled.clear()
        state.picker_filtered.clear()
        state.picker_selected = 0
        state.picker_filter = ""
        for raw in text.split("\n"):
            var item = String(raw.strip())
            if item == "":
                continue
            var enabled = item.startswith("1:")
            if item.startswith("1:") or item.startswith("0:"):
                item = _byte_range(item, 2, item.byte_length())
            state.picker_items.append(item^)
            state.picker_enabled.append(enabled)
        Self._picker_rebuild(state)

    @staticmethod
    def _picker_rebuild(mut state: UiState):
        state.picker_filtered.clear()
        var needle = state.picker_filter.lower()
        for i in range(len(state.picker_items)):
            if needle == "" or _fuzzy_score(needle, state.picker_items[i].lower()) >= 0:
                state.picker_filtered.append(i)
        if len(state.picker_filtered) == 0:
            state.picker_selected = 0
            return
        for i in state.picker_filtered:
            if i == state.picker_selected:
                return
        state.picker_selected = state.picker_filtered[0]

    @staticmethod
    def _picker_move(mut state: UiState, direction: Int):
        if len(state.picker_filtered) == 0:
            state.picker_selected = 0
            return
        var visible = 0
        for i in range(len(state.picker_filtered)):
            if state.picker_filtered[i] == state.picker_selected:
                visible = i
                break
        visible = (visible + direction + len(state.picker_filtered)) % len(
            state.picker_filtered
        )
        state.picker_selected = state.picker_filtered[visible]

    @staticmethod
    def _picker_page(mut state: UiState, direction: Int):
        if len(state.picker_filtered) == 0:
            return
        var visible = 0
        for i in range(len(state.picker_filtered)):
            if state.picker_filtered[i] == state.picker_selected:
                visible = i
                break
        visible = max(0, min(len(state.picker_filtered) - 1, visible + direction))
        state.picker_selected = state.picker_filtered[visible]

    @staticmethod
    def _picker_close(mut state: UiState):
        state.picker_name = ""
        state.picker_items.clear()
        state.picker_enabled.clear()
        state.picker_filtered.clear()
        state.picker_selected = 0
        state.picker_filter = ""

    @staticmethod
    def _search_open(mut state: UiState):
        if state.search_open:
            return
        state.search_open = True
        state.search_query = ""
        state.search_matches.clear()
        state.search_selected = 0
        state.search_saved_offset = state.viewport_offset
        state.search_saved_auto_scroll = state.auto_scroll

    @staticmethod
    def _search_update(mut state: UiState, query: String):
        if not state.search_open:
            return
        state.search_query = query
        state.search_matches.clear()
        state.search_selected = 0
        var needle = String(query.strip()).lower()
        if needle == "":
            return
        var scores = List[Int]()
        for i in range(len(state.messages)):
            var candidate = _search_text(state, i).lower()
            var score = _fuzzy_score(needle, candidate)
            if score < 0:
                continue
            var position = len(scores)
            for j in range(len(scores)):
                if score > scores[j]:
                    position = j
                    break
            scores.insert(position, score)
            state.search_matches.insert(position, i)
        Self._search_reveal(state)

    @staticmethod
    def _search_move(mut state: UiState, direction: Int):
        if not state.search_open or len(state.search_matches) == 0:
            return
        state.search_selected = (
            state.search_selected + direction + len(state.search_matches)
        ) % len(state.search_matches)
        Self._search_reveal(state)

    @staticmethod
    def _search_reveal(mut state: UiState):
        if len(state.search_matches) == 0:
            return
        state.auto_scroll = False
        state.viewport_offset = Self._bounded_offset(
            state, state.search_matches[state.search_selected], False
        )

    @staticmethod
    def _search_close(mut state: UiState, restore: Bool):
        if not state.search_open:
            return
        if restore:
            state.auto_scroll = state.search_saved_auto_scroll
            state.viewport_offset = Self._bounded_offset(
                state, state.search_saved_offset, state.search_saved_auto_scroll
            )
        state.search_open = False
        state.search_query = ""
        state.search_matches.clear()
        state.search_selected = 0

    @staticmethod
    def _max_offset(state: UiState) -> Int:
        return max(0, len(state.messages) - state.viewport_height)

    @staticmethod
    def _bounded_offset(state: UiState, requested: Int, auto_scroll: Bool) -> Int:
        var maximum = Self._max_offset(state)
        if auto_scroll:
            return maximum
        return min(max(0, requested), maximum)


def _ascii_lower(value: String) -> String:
    var result = String("")
    for cp in value.codepoints():
        var code = Int(cp.to_u32())
        if code >= 65 and code <= 90:
            code += 32
        result += chr(code)
    return result^


def _fuzzy_score(needle: String, candidate: String) -> Int:
    if needle == "":
        return 0
    var needle_index = 0
    var candidate_index = 0
    var first = -1
    var previous = -2
    var consecutive = 0
    for cp in candidate.codepoint_slices():
        if needle_index < needle.count_codepoints():
            var target = String("")
            var target_index = 0
            for part in needle.codepoint_slices():
                if target_index == needle_index:
                    target = String(part)
                    break
                target_index += 1
            if String(cp) == target:
                if first < 0:
                    first = candidate_index
                if candidate_index == previous + 1:
                    consecutive += 1
                previous = candidate_index
                needle_index += 1
        candidate_index += 1
    if needle_index != needle.count_codepoints():
        return -1
    return needle.count_codepoints() * 100 + consecutive * 25 - first - candidate_index


def _search_text(state: UiState, index: Int) -> String:
    var prefix = state.roles[index]
    if prefix == "user":
        prefix = "you"
    elif prefix == "assistant":
        prefix = "maki"
    return prefix + "> " + state.messages[index]


def _matched_line(text: String, query: String) -> String:
    var needle = String(query.strip()).lower()
    var fallback = String("")
    for line in text.split("\n"):
        var candidate = String(line)
        if fallback == "":
            fallback = candidate.copy()
        if needle != "" and _subsequence(needle, candidate.lower()):
            return candidate^
    return fallback^


def _ends_word(value: String) -> Bool:
    var last = String("")
    for cp in value.codepoint_slices():
        last = String(cp)
    return _word_boundary(last)


def _starts_word(value: String) -> Bool:
    for cp in value.codepoint_slices():
        return _word_boundary(String(cp))
    return False


def _word_boundary(value: String) -> Bool:
    if value == "_" or value == ")" or value == "]" or value == "}" or value == ">":
        return True
    for cp in value.codepoints():
        var code = Int(cp.to_u32())
        return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code >= 128
    return False


def _codepoint_prefix(value: String, count: Int) -> String:
    var result = String("")
    var index = 0
    for part in value.codepoint_slices():
        if index >= count:
            break
        result += String(part)
        index += 1
    return result^


def _codepoint_suffix(value: String, start: Int) -> String:
    var result = String("")
    var index = 0
    for part in value.codepoint_slices():
        if index >= start:
            result += String(part)
        index += 1
    return result^


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
