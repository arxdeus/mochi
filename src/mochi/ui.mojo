"""Terminal-independent UI event, reducer, action, and view contracts."""

from mochi.json import JsonValue, parse_json
from mochi.plugin import plugin_command_key
from mochi.types import Message


comptime UI_TRANSCRIPT_VERSION = 1

# Emoji-related states from unicode-width 0.2.2's reverse string-width
# automaton. Maki uses UnicodeWidthChar for wrapping but UnicodeWidthStr for
# the cursor span, so these states intentionally affect only cursor columns.
comptime _WIDTH_DEFAULT = 0
comptime _WIDTH_EMOJI_MODIFIER = 1
comptime _WIDTH_REGIONAL_INDICATOR = 2
comptime _WIDTH_SEVERAL_REGIONAL_INDICATORS = 3
comptime _WIDTH_EMOJI_PRESENTATION = 4
comptime _WIDTH_ZWJ_EMOJI_PRESENTATION = 5
comptime _WIDTH_VS16_ZWJ_EMOJI_PRESENTATION = 6
comptime _WIDTH_KEYCAP_ZWJ_EMOJI_PRESENTATION = 7
comptime _WIDTH_VS16_KEYCAP_ZWJ_EMOJI_PRESENTATION = 8
comptime _WIDTH_REGIONAL_INDICATOR_ZWJ_PRESENTATION = 9
comptime _WIDTH_EVEN_REGIONAL_INDICATOR_ZWJ_PRESENTATION = 10
comptime _WIDTH_ODD_REGIONAL_INDICATOR_ZWJ_PRESENTATION = 11
comptime _WIDTH_TAG_END_ZWJ_EMOJI_PRESENTATION = 12
comptime _WIDTH_TAG_D1_END_ZWJ_EMOJI_PRESENTATION = 13
comptime _WIDTH_TAG_D2_END_ZWJ_EMOJI_PRESENTATION = 14
comptime _WIDTH_TAG_D3_END_ZWJ_EMOJI_PRESENTATION = 15
comptime _WIDTH_TAG_A1_END_ZWJ_EMOJI_PRESENTATION = 16
comptime _WIDTH_TAG_A2_END_ZWJ_EMOJI_PRESENTATION = 17
comptime _WIDTH_TAG_A3_END_ZWJ_EMOJI_PRESENTATION = 18
comptime _WIDTH_TAG_A4_END_ZWJ_EMOJI_PRESENTATION = 19
comptime _WIDTH_TAG_A5_END_ZWJ_EMOJI_PRESENTATION = 20
comptime _WIDTH_TAG_A6_END_ZWJ_EMOJI_PRESENTATION = 21
comptime _WIDTH_VARIATION_SELECTOR_15 = 22
comptime _WIDTH_VARIATION_SELECTOR_16 = 23


@fieldwise_init
struct UiRect(Copyable, Equatable, Movable):
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    def contains(self, row: Int, col: Int) -> Bool:
        return (
            self.width > 0
            and self.height > 0
            and col >= self.x
            and col < self.x + self.width
            and row >= self.y
            and row < self.y + self.height
        )


@fieldwise_init
struct DocPos(Copyable, Equatable, Movable):
    var row: Int
    var col: Int


@fieldwise_init
struct InputCursorLayout(Copyable, Movable):
    """Rendered main-input cursor plus the vertical layout that owns it."""

    var cursor: Optional[DocPos]
    var scroll_y: Int
    var total_rows: Int


@fieldwise_init
struct ScreenSelection(Copyable, Equatable, Movable):
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
            scroll_offset
            + min(max(row, area.y), area.y + max(0, area.height - 1))
            - area.y,
            min(max(col, area.x), area.x + max(0, area.width - 1)),
        )
        self.anchor = pos.copy()
        self.cursor = pos^
        self.area = area.copy()
        self.zone = zone

    def update(mut self, row: Int, col: Int, scroll_offset: Int = 0):
        self.cursor = DocPos(
            scroll_offset
            + min(
                max(row, self.area.y),
                self.area.y + max(0, self.area.height - 1),
            )
            - self.area.y,
            min(
                max(col, self.area.x), self.area.x + max(0, self.area.width - 1)
            ),
        )

    def is_empty(self) -> Bool:
        return self.anchor == self.cursor

    def normalized(self) -> Tuple[DocPos, DocPos]:
        if (
            self.anchor.row < self.cursor.row
            or self.anchor.row == self.cursor.row
            and self.anchor.col <= self.cursor.col
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

    def input_cursor_layout(
        self,
        width: Int,
        height: Int,
        focused: Bool,
        main_input: Bool,
        scroll_y: Int = 0,
        follow_cursor: Bool = True,
    ) -> InputCursorLayout:
        """Locate the real cursor on the exact cell used by the main input.

        Rows are content rows (before any renderer-owned border offset). The
        two-cell prompt prefix appears only on the first visual row of each
        logical line, matching Maki's input layout.
        """
        var exposed = (
            focused
            and main_input
            and not self.search_open
            and self.picker_name == ""
            and self.overlay_name == ""
        )
        return _input_cursor_layout(
            self.draft,
            self.cursor,
            width,
            height,
            scroll_y,
            exposed,
            follow_cursor,
        )

    def add_zone(mut self, area: UiRect, zone: Int):
        self.zones.append(SelectableZone(area.copy(), zone))

    def clear_zones(mut self):
        self.zones.clear()

    def register_terminal_zones(mut self, width: Int, height: Int):
        self.clear_zones()
        var area = UiRect(0, 0, max(1, width), max(1, height))
        self.add_zone(area.copy(), Selection.INPUT)
        if (
            self.search_open
            or self.picker_name != ""
            or self.overlay_name != ""
        ):
            self.add_zone(area^, Selection.OVERLAY)

    def selected_input_text(self) -> String:
        if not self.selection or not self.selection_pending_copy:
            return ""
        var selection = self.selection.value().copy()
        if selection.zone != Selection.INPUT:
            return ""
        var bounds = selection.normalized()
        var start = max(0, bounds[0].col - 2)
        var end = max(0, bounds[1].col - 2)
        return _codepoint_range(self.draft, start, end)

    def clear_pending_copy(mut self):
        self.selection = None
        self.selection_pending_copy = False
        self.selection_edge_scroll = 0

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
            self.viewport_offset = max(
                0, len(self.messages) - self.viewport_height
            )


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
    "tasks",
    "compact",
    "new",
    "help",
    "usage",
    "queue",
    "model",
    "theme",
    "mcp",
    "login",
    "cd",
    "btw",
    "yolo",
    "thinking",
    "fast",
    "workflow",
    "exit",
    "reload",
]

comptime BUILTIN_COMMAND_MAX_ARGS = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    2147483647,
    0,
    1,
    0,
    0,
    0,
    0,
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
            marker
            + state.roles[message_index]
            + ": "
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
                    state.picker_filter,
                    0,
                    state.picker_filter.byte_length() - 1,
                )
                Self._picker_rebuild(state)
        elif event.tag == UiEvent.PICKER_PAGE_NEXT:
            Self._picker_page(state, 10)
        elif event.tag == UiEvent.PICKER_PAGE_PREVIOUS:
            Self._picker_page(state, -10)
        elif event.tag == UiEvent.PICKER_TOGGLE:
            if state.picker_name != "" and len(state.picker_items) > 0:
                var selected = state.picker_selected
                state.picker_enabled[selected] = not state.picker_enabled[
                    selected
                ]
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
                if (
                    state.overlay_modal or state.picker_name != ""
                ) and zone.value().zone != Selection.OVERLAY:
                    return UiAction.none()
                var scroll = (
                    state.viewport_offset if zone.value().zone
                    == Selection.MESSAGES else 0
                )
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
                var at_bottom = (
                    event.height + 1 >= selection.area.y + selection.area.height
                )
                state.selection_edge_scroll = 1 if at_top else (
                    -1 if at_bottom else 0
                )
                if (
                    selection.zone == Selection.MESSAGES
                    and state.selection_edge_scroll != 0
                ):
                    state.auto_scroll = False
                    state.viewport_offset = Self._bounded_offset(
                        state,
                        state.viewport_offset - state.selection_edge_scroll,
                        False,
                    )
                var scroll = (
                    state.viewport_offset if selection.zone
                    == Selection.MESSAGES else 0
                )
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
        if (
            len(state.history) == 0
            or state.history[len(state.history) - 1] != text
        ):
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
            if is_builtin_command(command_name):
                state.command_selected = 0
                var builtin_source = command_name.copy()
                var builtin_name = String(
                    builtin_source.removeprefix("/")
                ).lower()
                return UiAction.command(builtin_name^, command_arguments^)
            try:
                var requested_key = plugin_command_key(command_name)
                for extension in state.extension_commands:
                    if plugin_command_key(extension) == requested_key:
                        state.command_selected = 0
                        return UiAction.command(extension, command_arguments^)
            except:
                # Malformed command text is ordinary prompt input. Installed
                # extension names have already passed protocol validation.
                pass
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
                            command,
                            separator.value() + 1,
                            command.byte_length(),
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
            if (
                needle == ""
                or _fuzzy_score(needle, state.picker_items[i].lower()) >= 0
            ):
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
        visible = max(
            0, min(len(state.picker_filtered) - 1, visible + direction)
        )
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
    def _bounded_offset(
        state: UiState, requested: Int, auto_scroll: Bool
    ) -> Int:
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
    return (
        needle.count_codepoints() * 100
        + consecutive * 25
        - first
        - candidate_index
    )


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
    if (
        value == "_"
        or value == ")"
        or value == "]"
        or value == "}"
        or value == ">"
    ):
        return True
    for cp in value.codepoints():
        var code = Int(cp.to_u32())
        return (
            (code >= 48 and code <= 57)
            or (code >= 65 and code <= 90)
            or (code >= 97 and code <= 122)
            or code >= 128
        )
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


def _codepoint_range(value: String, start: Int, end_inclusive: Int) -> String:
    var result = String("")
    var index = 0
    for part in value.codepoint_slices():
        if index > end_inclusive:
            break
        if index >= start:
            result += String(part)
        index += 1
    return result^


def _input_cursor_layout(
    draft: String,
    cursor: Int,
    width: Int,
    height: Int,
    scroll_y: Int,
    exposed: Bool,
    follow_cursor: Bool,
) -> InputCursorLayout:
    # Maki reserves two cells for the chevron or continuation padding and
    # greedily wraps the remaining display cells. Wrapped continuation rows
    # have no prefix.
    var row_width = max(1, width - 2)
    var viewport_height = max(1, height)
    var cursor_index = min(max(0, cursor), draft.count_codepoints())
    var codepoints = List[Int]()
    var consumed = 0
    var total_rows = 0
    var cursor_visual_row = 0
    var cursor_col = 0
    var found_cursor = False

    for cp in draft.codepoints():
        var value = Int(cp.to_u32())
        if value == 10:
            var local_cursor = cursor_index - consumed
            var owns_cursor = (
                not found_cursor
                and local_cursor >= 0
                and local_cursor <= len(codepoints)
            )
            var metrics = _wrapped_line_metrics(
                codepoints, row_width, local_cursor, exposed and owns_cursor
            )
            if owns_cursor:
                cursor_visual_row = total_rows + metrics[1]
                cursor_col = metrics[2]
                found_cursor = True
            total_rows += metrics[0]
            consumed += len(codepoints) + 1
            codepoints.clear()
        else:
            codepoints.append(value)

    var local_cursor = cursor_index - consumed
    var owns_cursor = (
        not found_cursor
        and local_cursor >= 0
        and local_cursor <= len(codepoints)
    )
    var metrics = _wrapped_line_metrics(
        codepoints, row_width, local_cursor, exposed and owns_cursor
    )
    if owns_cursor:
        cursor_visual_row = total_rows + metrics[1]
        cursor_col = metrics[2]
        found_cursor = True
    total_rows += metrics[0]

    var maximum_scroll = max(0, total_rows - viewport_height)
    var effective_scroll = min(max(0, scroll_y), maximum_scroll)
    if exposed and found_cursor and follow_cursor:
        if cursor_visual_row < effective_scroll:
            effective_scroll = cursor_visual_row
        elif cursor_visual_row >= effective_scroll + viewport_height:
            effective_scroll = cursor_visual_row - viewport_height + 1
        effective_scroll = min(max(0, effective_scroll), maximum_scroll)

    var visible_cursor: Optional[DocPos] = None
    var screen_row = cursor_visual_row - effective_scroll
    if (
        exposed
        and found_cursor
        and height > 0
        and screen_row >= 0
        and screen_row < viewport_height
        and cursor_col >= 0
        and cursor_col < max(0, width)
    ):
        visible_cursor = Optional(DocPos(screen_row, cursor_col))
    return InputCursorLayout(visible_cursor^, effective_scroll, total_rows)


def _wrapped_line_metrics(
    codepoints: List[Int],
    row_width: Int,
    cursor_x: Int,
    cursor_visible: Bool,
) -> Tuple[Int, Int, Int]:
    # Character starts preserve the gap left when a wide character no longer
    # fits. Dividing accumulated display width by row width does not.
    var starts: List[Int] = [0]
    var row_col = 0
    for i in range(len(codepoints)):
        var cell_width = _terminal_cell_width(codepoints[i])
        if row_col + cell_width > row_width and row_col > 0:
            starts.append(i)
            row_col = 0
        row_col += cell_width
    # A reversed software cursor consumes one cell. At the end of a full row
    # it belongs to a new empty row, exactly as in Maki.
    if cursor_visible and row_col + 1 > row_width:
        starts.append(len(codepoints))

    var cursor_row = 0
    var cursor_start = 0
    if cursor_visible:
        for row in range(len(starts)):
            if starts[row] <= cursor_x:
                cursor_row = row
                cursor_start = starts[row]
    var cursor_col = 2 if cursor_row == 0 else 0
    if cursor_visible:
        var cursor_end = min(max(cursor_start, cursor_x), len(codepoints))
        cursor_col += _terminal_string_width(
            codepoints, cursor_start, cursor_end
        )
    return (len(starts), cursor_row, cursor_col)


def _terminal_cell_width(codepoint: Int) -> Int:
    # Maki uses unicode-width and falls back to one cell for control codepoints.
    if _is_zero_width_codepoint(codepoint):
        return 0
    # unicode-width deliberately treats each regional indicator as one cell;
    # a valid pair therefore remains two cells before any ZWJ collapsing.
    if _in_codepoint_range(codepoint, 0x1F1E6, 0x1F1FF):
        return 1
    if _is_wide_codepoint(codepoint):
        return 2
    return 1


def _terminal_string_width(codepoints: List[Int], start: Int, end: Int) -> Int:
    """Width of one row prefix using Maki's emoji UnicodeWidthStr rules.

    Row ownership remains scalar-width based. Only the completed substring
    before the cursor is folded here, matching tui-textarea's cursor overlay.
    """
    var first = min(max(0, start), len(codepoints))
    var last = min(max(first, end), len(codepoints))
    var cells = 0
    var next_state = _WIDTH_DEFAULT
    for offset in range(last - first):
        var cp = codepoints[last - 1 - offset]
        var step = _terminal_string_width_step(cp, next_state)
        cells += step[0]
        next_state = step[1]
    return cells


def _terminal_string_width_step(cp: Int, next_state: Int) -> Tuple[Int, Int]:
    var state = next_state

    if (
        state == _WIDTH_VARIATION_SELECTOR_16
        or state == _WIDTH_VS16_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_VS16_KEYCAP_ZWJ_EMOJI_PRESENTATION
    ):
        if _starts_emoji_presentation_sequence(cp):
            var width = 2
            if (
                state == _WIDTH_VS16_ZWJ_EMOJI_PRESENTATION
                or state == _WIDTH_VS16_KEYCAP_ZWJ_EMOJI_PRESENTATION
            ):
                width = 0
            return (width, _WIDTH_EMOJI_PRESENTATION)
        state = _WIDTH_DEFAULT

    if state != _WIDTH_DEFAULT:
        if cp == 0xFE0F:
            if state == _WIDTH_ZWJ_EMOJI_PRESENTATION:
                return (0, _WIDTH_VS16_ZWJ_EMOJI_PRESENTATION)
            if state == _WIDTH_KEYCAP_ZWJ_EMOJI_PRESENTATION:
                return (0, _WIDTH_VS16_KEYCAP_ZWJ_EMOJI_PRESENTATION)
            return (0, _WIDTH_VARIATION_SELECTOR_16)
        if cp == 0xFE0E:
            return (0, _WIDTH_VARIATION_SELECTOR_15)
        if state == _WIDTH_VARIATION_SELECTOR_15:
            if _starts_non_ideographic_text_presentation_sequence(cp):
                return (1, _WIDTH_DEFAULT)
            state = _WIDTH_DEFAULT

        if state == _WIDTH_EMOJI_MODIFIER and _is_emoji_modifier_base(cp):
            return (0, _WIDTH_EMOJI_PRESENTATION)

        if (
            state == _WIDTH_REGIONAL_INDICATOR
            or state == _WIDTH_SEVERAL_REGIONAL_INDICATORS
        ) and _in_codepoint_range(cp, 0x1F1E6, 0x1F1FF):
            return (1, _WIDTH_SEVERAL_REGIONAL_INDICATORS)

        if cp == 0x200D and (
            state == _WIDTH_EMOJI_PRESENTATION
            or state == _WIDTH_SEVERAL_REGIONAL_INDICATORS
            or state == _WIDTH_EVEN_REGIONAL_INDICATOR_ZWJ_PRESENTATION
            or state == _WIDTH_ODD_REGIONAL_INDICATOR_ZWJ_PRESENTATION
            or state == _WIDTH_EMOJI_MODIFIER
        ):
            return (0, _WIDTH_ZWJ_EMOJI_PRESENTATION)
        if state == _WIDTH_ZWJ_EMOJI_PRESENTATION and cp == 0x20E3:
            return (0, _WIDTH_KEYCAP_ZWJ_EMOJI_PRESENTATION)
        if state == _WIDTH_VS16_KEYCAP_ZWJ_EMOJI_PRESENTATION and (
            cp == 0x23 or cp == 0x2A or _in_codepoint_range(cp, 0x30, 0x39)
        ):
            return (0, _WIDTH_EMOJI_PRESENTATION)
        if state == _WIDTH_ZWJ_EMOJI_PRESENTATION and _in_codepoint_range(
            cp, 0x1F1E6, 0x1F1FF
        ):
            return (1, _WIDTH_REGIONAL_INDICATOR_ZWJ_PRESENTATION)
        if (
            state == _WIDTH_REGIONAL_INDICATOR_ZWJ_PRESENTATION
            or state == _WIDTH_ODD_REGIONAL_INDICATOR_ZWJ_PRESENTATION
        ) and _in_codepoint_range(cp, 0x1F1E6, 0x1F1FF):
            return (-1, _WIDTH_EVEN_REGIONAL_INDICATOR_ZWJ_PRESENTATION)
        if (
            state == _WIDTH_EVEN_REGIONAL_INDICATOR_ZWJ_PRESENTATION
            and _in_codepoint_range(cp, 0x1F1E6, 0x1F1FF)
        ):
            return (3, _WIDTH_ODD_REGIONAL_INDICATOR_ZWJ_PRESENTATION)
        if state == _WIDTH_ZWJ_EMOJI_PRESENTATION and _in_codepoint_range(
            cp, 0x1F3FB, 0x1F3FF
        ):
            return (0, _WIDTH_EMOJI_MODIFIER)

        var tag_step = _terminal_emoji_tag_width_step(cp, state)
        if tag_step[1] != _WIDTH_DEFAULT:
            return tag_step

        if (
            state == _WIDTH_ZWJ_EMOJI_PRESENTATION
            and _is_default_emoji_presentation(cp)
        ):
            return (0, _WIDTH_EMOJI_PRESENTATION)

    if cp == 0xFE0F:
        return (0, _WIDTH_VARIATION_SELECTOR_16)
    if cp == 0xFE0E:
        return (0, _WIDTH_VARIATION_SELECTOR_15)
    if _in_codepoint_range(cp, 0x1F1E6, 0x1F1FF):
        return (1, _WIDTH_REGIONAL_INDICATOR)
    if _in_codepoint_range(cp, 0x1F3FB, 0x1F3FF):
        return (2, _WIDTH_EMOJI_MODIFIER)
    if _is_default_emoji_presentation(cp):
        return (2, _WIDTH_EMOJI_PRESENTATION)
    return (_terminal_cell_width(cp), _WIDTH_DEFAULT)


def _terminal_emoji_tag_width_step(cp: Int, state: Int) -> Tuple[Int, Int]:
    if state == _WIDTH_ZWJ_EMOJI_PRESENTATION and cp == 0xE007F:
        return (0, _WIDTH_TAG_END_ZWJ_EMOJI_PRESENTATION)
    if state == _WIDTH_TAG_END_ZWJ_EMOJI_PRESENTATION and _in_codepoint_range(
        cp, 0xE0061, 0xE007A
    ):
        return (0, _WIDTH_TAG_A1_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_A1_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0061, 0xE007A)
    ):
        return (0, _WIDTH_TAG_A2_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_A2_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0061, 0xE007A)
    ):
        return (0, _WIDTH_TAG_A3_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_A3_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0061, 0xE007A)
    ):
        return (0, _WIDTH_TAG_A4_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_A4_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0061, 0xE007A)
    ):
        return (0, _WIDTH_TAG_A5_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_A5_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0061, 0xE007A)
    ):
        return (0, _WIDTH_TAG_A6_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A1_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A2_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A3_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A4_END_ZWJ_EMOJI_PRESENTATION
    ) and _in_codepoint_range(cp, 0xE0030, 0xE0039):
        return (0, _WIDTH_TAG_D1_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_D1_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0030, 0xE0039)
    ):
        return (0, _WIDTH_TAG_D2_END_ZWJ_EMOJI_PRESENTATION)
    if (
        state == _WIDTH_TAG_D2_END_ZWJ_EMOJI_PRESENTATION
        and _in_codepoint_range(cp, 0xE0030, 0xE0039)
    ):
        return (0, _WIDTH_TAG_D3_END_ZWJ_EMOJI_PRESENTATION)
    if cp == 0x1F3F4 and (
        state == _WIDTH_TAG_A3_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A4_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A5_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_A6_END_ZWJ_EMOJI_PRESENTATION
        or state == _WIDTH_TAG_D3_END_ZWJ_EMOJI_PRESENTATION
    ):
        return (0, _WIDTH_EMOJI_PRESENTATION)
    return (0, _WIDTH_DEFAULT)


# Unicode 17 properties generated by unicode-width 0.2.2. Keeping the
# exact property boundaries prevents invalid ZWJ strings from collapsing.
def _is_default_emoji_presentation(cp: Int) -> Bool:
    if cp < 0x231A:
        return False
    return (
        _in_codepoint_range(cp, 0x231A, 0x231B)
        or _in_codepoint_range(cp, 0x23E9, 0x23EC)
        or cp == 0x23F0
        or cp == 0x23F3
        or _in_codepoint_range(cp, 0x25FD, 0x25FE)
        or _in_codepoint_range(cp, 0x2614, 0x2615)
        or _in_codepoint_range(cp, 0x2648, 0x2653)
        or cp == 0x267F
        or cp == 0x2693
        or cp == 0x26A1
        or _in_codepoint_range(cp, 0x26AA, 0x26AB)
        or _in_codepoint_range(cp, 0x26BD, 0x26BE)
        or _in_codepoint_range(cp, 0x26C4, 0x26C5)
        or cp == 0x26CE
        or cp == 0x26D4
        or cp == 0x26EA
        or _in_codepoint_range(cp, 0x26F2, 0x26F3)
        or cp == 0x26F5
        or cp == 0x26FA
        or cp == 0x26FD
        or cp == 0x2705
        or _in_codepoint_range(cp, 0x270A, 0x270B)
        or cp == 0x2728
        or cp == 0x274C
        or cp == 0x274E
        or _in_codepoint_range(cp, 0x2753, 0x2755)
        or cp == 0x2757
        or _in_codepoint_range(cp, 0x2795, 0x2797)
        or cp == 0x27B0
        or cp == 0x27BF
        or _in_codepoint_range(cp, 0x2B1B, 0x2B1C)
        or cp == 0x2B50
        or cp == 0x2B55
        or cp == 0x1F004
        or cp == 0x1F0CF
        or cp == 0x1F18E
        or _in_codepoint_range(cp, 0x1F191, 0x1F19A)
        or cp == 0x1F201
        or cp == 0x1F21A
        or cp == 0x1F22F
        or _in_codepoint_range(cp, 0x1F232, 0x1F236)
        or _in_codepoint_range(cp, 0x1F238, 0x1F23A)
        or _in_codepoint_range(cp, 0x1F250, 0x1F251)
        or _in_codepoint_range(cp, 0x1F300, 0x1F320)
        or _in_codepoint_range(cp, 0x1F32D, 0x1F335)
        or _in_codepoint_range(cp, 0x1F337, 0x1F37C)
        or _in_codepoint_range(cp, 0x1F37E, 0x1F393)
        or _in_codepoint_range(cp, 0x1F3A0, 0x1F3CA)
        or _in_codepoint_range(cp, 0x1F3CF, 0x1F3D3)
        or _in_codepoint_range(cp, 0x1F3E0, 0x1F3F0)
        or cp == 0x1F3F4
        or _in_codepoint_range(cp, 0x1F3F8, 0x1F3FA)
        or _in_codepoint_range(cp, 0x1F400, 0x1F43E)
        or cp == 0x1F440
        or _in_codepoint_range(cp, 0x1F442, 0x1F4FC)
        or _in_codepoint_range(cp, 0x1F4FF, 0x1F53D)
        or _in_codepoint_range(cp, 0x1F54B, 0x1F54E)
        or _in_codepoint_range(cp, 0x1F550, 0x1F567)
        or cp == 0x1F57A
        or _in_codepoint_range(cp, 0x1F595, 0x1F596)
        or cp == 0x1F5A4
        or _in_codepoint_range(cp, 0x1F5FB, 0x1F64F)
        or _in_codepoint_range(cp, 0x1F680, 0x1F6C5)
        or cp == 0x1F6CC
        or _in_codepoint_range(cp, 0x1F6D0, 0x1F6D2)
        or _in_codepoint_range(cp, 0x1F6D5, 0x1F6D8)
        or _in_codepoint_range(cp, 0x1F6DC, 0x1F6DF)
        or _in_codepoint_range(cp, 0x1F6EB, 0x1F6EC)
        or _in_codepoint_range(cp, 0x1F6F4, 0x1F6FC)
        or _in_codepoint_range(cp, 0x1F7E0, 0x1F7EB)
        or cp == 0x1F7F0
        or _in_codepoint_range(cp, 0x1F90C, 0x1F93A)
        or _in_codepoint_range(cp, 0x1F93C, 0x1F945)
        or _in_codepoint_range(cp, 0x1F947, 0x1F9FF)
        or _in_codepoint_range(cp, 0x1FA70, 0x1FA7C)
        or _in_codepoint_range(cp, 0x1FA80, 0x1FA8A)
        or _in_codepoint_range(cp, 0x1FA8E, 0x1FAC6)
        or cp == 0x1FAC8
        or _in_codepoint_range(cp, 0x1FACD, 0x1FADC)
        or _in_codepoint_range(cp, 0x1FADF, 0x1FAEA)
        or _in_codepoint_range(cp, 0x1FAEF, 0x1FAF8)
    )


def _starts_emoji_presentation_sequence(cp: Int) -> Bool:
    return (
        cp == 0x23
        or cp == 0x2A
        or _in_codepoint_range(cp, 0x30, 0x39)
        or cp == 0xA9
        or cp == 0xAE
        or cp == 0x203C
        or cp == 0x2049
        or cp == 0x2122
        or cp == 0x2139
        or _in_codepoint_range(cp, 0x2194, 0x2199)
        or _in_codepoint_range(cp, 0x21A9, 0x21AA)
        or _in_codepoint_range(cp, 0x231A, 0x231B)
        or cp == 0x2328
        or cp == 0x23CF
        or _in_codepoint_range(cp, 0x23E9, 0x23F3)
        or _in_codepoint_range(cp, 0x23F8, 0x23FA)
        or cp == 0x24C2
        or _in_codepoint_range(cp, 0x25AA, 0x25AB)
        or cp == 0x25B6
        or cp == 0x25C0
        or _in_codepoint_range(cp, 0x25FB, 0x25FE)
        or _in_codepoint_range(cp, 0x2600, 0x2604)
        or cp == 0x260E
        or cp == 0x2611
        or _in_codepoint_range(cp, 0x2614, 0x2615)
        or cp == 0x2618
        or cp == 0x261D
        or cp == 0x2620
        or _in_codepoint_range(cp, 0x2622, 0x2623)
        or cp == 0x2626
        or cp == 0x262A
        or _in_codepoint_range(cp, 0x262E, 0x262F)
        or _in_codepoint_range(cp, 0x2638, 0x263A)
        or cp == 0x2640
        or cp == 0x2642
        or _in_codepoint_range(cp, 0x2648, 0x2653)
        or _in_codepoint_range(cp, 0x265F, 0x2660)
        or cp == 0x2663
        or _in_codepoint_range(cp, 0x2665, 0x2666)
        or cp == 0x2668
        or cp == 0x267B
        or _in_codepoint_range(cp, 0x267E, 0x267F)
        or _in_codepoint_range(cp, 0x2692, 0x2697)
        or cp == 0x2699
        or _in_codepoint_range(cp, 0x269B, 0x269C)
        or _in_codepoint_range(cp, 0x26A0, 0x26A1)
        or cp == 0x26A7
        or _in_codepoint_range(cp, 0x26AA, 0x26AB)
        or _in_codepoint_range(cp, 0x26B0, 0x26B1)
        or _in_codepoint_range(cp, 0x26BD, 0x26BE)
        or _in_codepoint_range(cp, 0x26C4, 0x26C5)
        or cp == 0x26C8
        or _in_codepoint_range(cp, 0x26CE, 0x26CF)
        or cp == 0x26D1
        or _in_codepoint_range(cp, 0x26D3, 0x26D4)
        or _in_codepoint_range(cp, 0x26E9, 0x26EA)
        or _in_codepoint_range(cp, 0x26F0, 0x26F5)
        or _in_codepoint_range(cp, 0x26F7, 0x26FA)
        or cp == 0x26FD
        or cp == 0x2702
        or cp == 0x2705
        or _in_codepoint_range(cp, 0x2708, 0x270D)
        or cp == 0x270F
        or cp == 0x2712
        or cp == 0x2714
        or cp == 0x2716
        or cp == 0x271D
        or cp == 0x2721
        or cp == 0x2728
        or _in_codepoint_range(cp, 0x2733, 0x2734)
        or cp == 0x2744
        or cp == 0x2747
        or cp == 0x274C
        or cp == 0x274E
        or _in_codepoint_range(cp, 0x2753, 0x2755)
        or cp == 0x2757
        or _in_codepoint_range(cp, 0x2763, 0x2764)
        or _in_codepoint_range(cp, 0x2795, 0x2797)
        or cp == 0x27A1
        or cp == 0x27B0
        or cp == 0x27BF
        or _in_codepoint_range(cp, 0x2934, 0x2935)
        or _in_codepoint_range(cp, 0x2B05, 0x2B07)
        or _in_codepoint_range(cp, 0x2B1B, 0x2B1C)
        or cp == 0x2B50
        or cp == 0x2B55
        or cp == 0x3030
        or cp == 0x303D
        or cp == 0x3297
        or cp == 0x3299
        or cp == 0x1F004
        or _in_codepoint_range(cp, 0x1F170, 0x1F171)
        or _in_codepoint_range(cp, 0x1F17E, 0x1F17F)
        or cp == 0x1F202
        or cp == 0x1F21A
        or cp == 0x1F22F
        or cp == 0x1F237
        or _in_codepoint_range(cp, 0x1F30D, 0x1F30F)
        or cp == 0x1F315
        or cp == 0x1F31C
        or cp == 0x1F321
        or _in_codepoint_range(cp, 0x1F324, 0x1F32C)
        or cp == 0x1F336
        or cp == 0x1F378
        or cp == 0x1F37D
        or cp == 0x1F393
        or _in_codepoint_range(cp, 0x1F396, 0x1F397)
        or _in_codepoint_range(cp, 0x1F399, 0x1F39B)
        or _in_codepoint_range(cp, 0x1F39E, 0x1F39F)
        or cp == 0x1F3A7
        or _in_codepoint_range(cp, 0x1F3AC, 0x1F3AE)
        or cp == 0x1F3C2
        or cp == 0x1F3C4
        or cp == 0x1F3C6
        or _in_codepoint_range(cp, 0x1F3CA, 0x1F3CE)
        or _in_codepoint_range(cp, 0x1F3D4, 0x1F3E0)
        or cp == 0x1F3ED
        or cp == 0x1F3F3
        or cp == 0x1F3F5
        or cp == 0x1F3F7
        or cp == 0x1F408
        or cp == 0x1F415
        or cp == 0x1F41F
        or cp == 0x1F426
        or cp == 0x1F43F
        or _in_codepoint_range(cp, 0x1F441, 0x1F442)
        or _in_codepoint_range(cp, 0x1F446, 0x1F449)
        or _in_codepoint_range(cp, 0x1F44D, 0x1F44E)
        or cp == 0x1F453
        or cp == 0x1F46A
        or cp == 0x1F47D
        or cp == 0x1F4A3
        or cp == 0x1F4B0
        or cp == 0x1F4B3
        or cp == 0x1F4BB
        or cp == 0x1F4BF
        or cp == 0x1F4CB
        or cp == 0x1F4DA
        or cp == 0x1F4DF
        or _in_codepoint_range(cp, 0x1F4E4, 0x1F4E6)
        or _in_codepoint_range(cp, 0x1F4EA, 0x1F4ED)
        or cp == 0x1F4F7
        or _in_codepoint_range(cp, 0x1F4F9, 0x1F4FB)
        or cp == 0x1F4FD
        or cp == 0x1F508
        or cp == 0x1F50D
        or _in_codepoint_range(cp, 0x1F512, 0x1F513)
        or _in_codepoint_range(cp, 0x1F549, 0x1F54A)
        or _in_codepoint_range(cp, 0x1F550, 0x1F567)
        or _in_codepoint_range(cp, 0x1F56F, 0x1F570)
        or _in_codepoint_range(cp, 0x1F573, 0x1F579)
        or cp == 0x1F587
        or _in_codepoint_range(cp, 0x1F58A, 0x1F58D)
        or cp == 0x1F590
        or cp == 0x1F5A5
        or cp == 0x1F5A8
        or _in_codepoint_range(cp, 0x1F5B1, 0x1F5B2)
        or cp == 0x1F5BC
        or _in_codepoint_range(cp, 0x1F5C2, 0x1F5C4)
        or _in_codepoint_range(cp, 0x1F5D1, 0x1F5D3)
        or _in_codepoint_range(cp, 0x1F5DC, 0x1F5DE)
        or cp == 0x1F5E1
        or cp == 0x1F5E3
        or cp == 0x1F5E8
        or cp == 0x1F5EF
        or cp == 0x1F5F3
        or cp == 0x1F5FA
        or cp == 0x1F610
        or cp == 0x1F687
        or cp == 0x1F68D
        or cp == 0x1F691
        or cp == 0x1F694
        or cp == 0x1F698
        or cp == 0x1F6AD
        or cp == 0x1F6B2
        or _in_codepoint_range(cp, 0x1F6B9, 0x1F6BA)
        or cp == 0x1F6BC
        or cp == 0x1F6CB
        or _in_codepoint_range(cp, 0x1F6CD, 0x1F6CF)
        or _in_codepoint_range(cp, 0x1F6E0, 0x1F6E5)
        or cp == 0x1F6E9
        or cp == 0x1F6F0
        or cp == 0x1F6F3
    )


def _is_emoji_modifier_base(cp: Int) -> Bool:
    if cp < 0x261D:
        return False
    return (
        cp == 0x261D
        or cp == 0x26F9
        or _in_codepoint_range(cp, 0x270A, 0x270D)
        or cp == 0x1F385
        or _in_codepoint_range(cp, 0x1F3C2, 0x1F3C4)
        or cp == 0x1F3C7
        or _in_codepoint_range(cp, 0x1F3CA, 0x1F3CC)
        or _in_codepoint_range(cp, 0x1F442, 0x1F443)
        or _in_codepoint_range(cp, 0x1F446, 0x1F450)
        or _in_codepoint_range(cp, 0x1F466, 0x1F478)
        or cp == 0x1F47C
        or _in_codepoint_range(cp, 0x1F481, 0x1F483)
        or _in_codepoint_range(cp, 0x1F485, 0x1F487)
        or cp == 0x1F48F
        or cp == 0x1F491
        or cp == 0x1F4AA
        or _in_codepoint_range(cp, 0x1F574, 0x1F575)
        or cp == 0x1F57A
        or cp == 0x1F590
        or _in_codepoint_range(cp, 0x1F595, 0x1F596)
        or _in_codepoint_range(cp, 0x1F645, 0x1F647)
        or _in_codepoint_range(cp, 0x1F64B, 0x1F64F)
        or cp == 0x1F6A3
        or _in_codepoint_range(cp, 0x1F6B4, 0x1F6B6)
        or cp == 0x1F6C0
        or cp == 0x1F6CC
        or cp == 0x1F90C
        or cp == 0x1F90F
        or _in_codepoint_range(cp, 0x1F918, 0x1F91F)
        or cp == 0x1F926
        or _in_codepoint_range(cp, 0x1F930, 0x1F939)
        or _in_codepoint_range(cp, 0x1F93C, 0x1F93E)
        or cp == 0x1F977
        or _in_codepoint_range(cp, 0x1F9B5, 0x1F9B6)
        or _in_codepoint_range(cp, 0x1F9B8, 0x1F9B9)
        or cp == 0x1F9BB
        or _in_codepoint_range(cp, 0x1F9CD, 0x1F9CF)
        or _in_codepoint_range(cp, 0x1F9D1, 0x1F9DD)
        or _in_codepoint_range(cp, 0x1FAC3, 0x1FAC5)
        or _in_codepoint_range(cp, 0x1FAF0, 0x1FAF8)
    )


def _starts_non_ideographic_text_presentation_sequence(cp: Int) -> Bool:
    if cp < 0x231A:
        return False
    return (
        _in_codepoint_range(cp, 0x231A, 0x231B)
        or _in_codepoint_range(cp, 0x23E9, 0x23EC)
        or cp == 0x23F0
        or cp == 0x23F3
        or _in_codepoint_range(cp, 0x25FD, 0x25FE)
        or _in_codepoint_range(cp, 0x2614, 0x2615)
        or _in_codepoint_range(cp, 0x2648, 0x2653)
        or cp == 0x267F
        or cp == 0x2693
        or cp == 0x26A1
        or _in_codepoint_range(cp, 0x26AA, 0x26AB)
        or _in_codepoint_range(cp, 0x26BD, 0x26BE)
        or _in_codepoint_range(cp, 0x26C4, 0x26C5)
        or cp == 0x26CE
        or cp == 0x26D4
        or cp == 0x26EA
        or _in_codepoint_range(cp, 0x26F2, 0x26F3)
        or cp == 0x26F5
        or cp == 0x26FA
        or cp == 0x26FD
        or cp == 0x2705
        or _in_codepoint_range(cp, 0x270A, 0x270B)
        or cp == 0x2728
        or cp == 0x274C
        or cp == 0x274E
        or _in_codepoint_range(cp, 0x2753, 0x2755)
        or cp == 0x2757
        or _in_codepoint_range(cp, 0x2795, 0x2797)
        or cp == 0x27B0
        or cp == 0x27BF
        or _in_codepoint_range(cp, 0x2B1B, 0x2B1C)
        or cp == 0x2B50
        or cp == 0x2B55
        or cp == 0x1F004
        or _in_codepoint_range(cp, 0x1F30D, 0x1F30F)
        or cp == 0x1F315
        or cp == 0x1F31C
        or cp == 0x1F378
        or cp == 0x1F393
        or cp == 0x1F3A7
        or _in_codepoint_range(cp, 0x1F3AC, 0x1F3AE)
        or cp == 0x1F3C2
        or cp == 0x1F3C4
        or cp == 0x1F3C6
        or cp == 0x1F3CA
        or cp == 0x1F3E0
        or cp == 0x1F3ED
        or cp == 0x1F408
        or cp == 0x1F415
        or cp == 0x1F41F
        or cp == 0x1F426
        or cp == 0x1F442
        or _in_codepoint_range(cp, 0x1F446, 0x1F449)
        or _in_codepoint_range(cp, 0x1F44D, 0x1F44E)
        or cp == 0x1F453
        or cp == 0x1F46A
        or cp == 0x1F47D
        or cp == 0x1F4A3
        or cp == 0x1F4B0
        or cp == 0x1F4B3
        or cp == 0x1F4BB
        or cp == 0x1F4BF
        or cp == 0x1F4CB
        or cp == 0x1F4DA
        or cp == 0x1F4DF
        or _in_codepoint_range(cp, 0x1F4E4, 0x1F4E6)
        or _in_codepoint_range(cp, 0x1F4EA, 0x1F4ED)
        or cp == 0x1F4F7
        or _in_codepoint_range(cp, 0x1F4F9, 0x1F4FB)
        or cp == 0x1F508
        or cp == 0x1F50D
        or _in_codepoint_range(cp, 0x1F512, 0x1F513)
        or _in_codepoint_range(cp, 0x1F550, 0x1F567)
        or cp == 0x1F610
        or cp == 0x1F687
        or cp == 0x1F68D
        or cp == 0x1F691
        or cp == 0x1F694
        or cp == 0x1F698
        or cp == 0x1F6AD
        or cp == 0x1F6B2
        or _in_codepoint_range(cp, 0x1F6B9, 0x1F6BA)
        or cp == 0x1F6BC
    )


def _in_codepoint_range(codepoint: Int, first: Int, last: Int) -> Bool:
    return codepoint >= first and codepoint <= last


def _is_zero_width_codepoint(cp: Int) -> Bool:
    # Default-ignorable format controls used by Arabic shaping, historic
    # scripts, and emoji tag sequences are zero-cell values in unicode-width.
    # Keep these explicit because they live outside the combining-mark tables.
    if (
        _in_codepoint_range(cp, 0x0600, 0x0605)
        or cp == 0x061C
        or cp == 0x06DD
        or cp == 0x070F
        or _in_codepoint_range(cp, 0x0890, 0x0891)
        or cp == 0x110BD
        or cp == 0x110CD
        or _in_codepoint_range(cp, 0x13430, 0x1343F)
        or _in_codepoint_range(cp, 0x1BCA0, 0x1BCA3)
        or _in_codepoint_range(cp, 0x1D173, 0x1D17A)
        or cp == 0xE0001
        or _in_codepoint_range(cp, 0xE0020, 0xE007F)
    ):
        return True
    if cp < 0x0300:
        return False
    return (
        _in_codepoint_range(cp, 0x0300, 0x036F)
        or _in_codepoint_range(cp, 0x0483, 0x0489)
        or _in_codepoint_range(cp, 0x0591, 0x05BD)
        or cp == 0x05BF
        or _in_codepoint_range(cp, 0x05C1, 0x05C2)
        or _in_codepoint_range(cp, 0x05C4, 0x05C5)
        or cp == 0x05C7
        or _in_codepoint_range(cp, 0x0610, 0x061A)
        or _in_codepoint_range(cp, 0x064B, 0x065F)
        or cp == 0x0670
        or _in_codepoint_range(cp, 0x06D6, 0x06ED)
        or cp == 0x0711
        or _in_codepoint_range(cp, 0x0730, 0x074A)
        or _in_codepoint_range(cp, 0x07A6, 0x07B0)
        or _in_codepoint_range(cp, 0x07EB, 0x07F3)
        or cp == 0x07FD
        or _in_codepoint_range(cp, 0x0816, 0x082D)
        or _in_codepoint_range(cp, 0x0859, 0x085B)
        or _in_codepoint_range(cp, 0x0898, 0x089F)
        or _in_codepoint_range(cp, 0x08CA, 0x08D2)
        or _in_codepoint_range(cp, 0x08D3, 0x0902)
        or cp == 0x093A
        or cp == 0x093C
        or _in_codepoint_range(cp, 0x0941, 0x0948)
        or cp == 0x094D
        or _in_codepoint_range(cp, 0x0951, 0x0957)
        or _in_codepoint_range(cp, 0x0962, 0x0963)
        or _in_codepoint_range(cp, 0x0981, 0x0981)
        or cp == 0x09BC
        or _in_codepoint_range(cp, 0x09C1, 0x09C4)
        or cp == 0x09CD
        or _in_codepoint_range(cp, 0x09E2, 0x09E3)
        or cp == 0x09FE
        or _in_codepoint_range(cp, 0x0A01, 0x0A02)
        or cp == 0x0A3C
        or _in_codepoint_range(cp, 0x0A41, 0x0A42)
        or _in_codepoint_range(cp, 0x0A47, 0x0A48)
        or _in_codepoint_range(cp, 0x0A4B, 0x0A4D)
        or cp == 0x0A51
        or _in_codepoint_range(cp, 0x0A70, 0x0A71)
        or cp == 0x0A75
        or _in_codepoint_range(cp, 0x0A81, 0x0A82)
        or _in_codepoint_range(cp, 0x0ABC, 0x0ABC)
        or _in_codepoint_range(cp, 0x0AC1, 0x0AC5)
        or _in_codepoint_range(cp, 0x0AC7, 0x0AC8)
        or cp == 0x0ACD
        or _in_codepoint_range(cp, 0x0AE2, 0x0AE3)
        or _in_codepoint_range(cp, 0x0AFA, 0x0AFF)
        or _in_codepoint_range(cp, 0x0B3C, 0x0B3C)
        or _in_codepoint_range(cp, 0x0B41, 0x0B44)
        or cp == 0x0B4D
        or _in_codepoint_range(cp, 0x0B62, 0x0B63)
        or _in_codepoint_range(cp, 0x0C3E, 0x0C40)
        or _in_codepoint_range(cp, 0x0C46, 0x0C48)
        or _in_codepoint_range(cp, 0x0C4A, 0x0C4D)
        or _in_codepoint_range(cp, 0x0D41, 0x0D44)
        or cp == 0x0D4D
        or _in_codepoint_range(cp, 0x0E31, 0x0E31)
        or _in_codepoint_range(cp, 0x0E34, 0x0E3A)
        or _in_codepoint_range(cp, 0x0E47, 0x0E4E)
        or _in_codepoint_range(cp, 0x0EB1, 0x0EB1)
        or _in_codepoint_range(cp, 0x0EB4, 0x0EBC)
        or _in_codepoint_range(cp, 0x0EC8, 0x0ECD)
        or _in_codepoint_range(cp, 0x0F71, 0x0F84)
        or _in_codepoint_range(cp, 0x0F86, 0x0F87)
        or _in_codepoint_range(cp, 0x0F8D, 0x0FBC)
        or _in_codepoint_range(cp, 0x102D, 0x1030)
        or _in_codepoint_range(cp, 0x1032, 0x1037)
        or _in_codepoint_range(cp, 0x1039, 0x103A)
        or _in_codepoint_range(cp, 0x1160, 0x11FF)
        or _in_codepoint_range(cp, 0x135D, 0x135F)
        or _in_codepoint_range(cp, 0x1712, 0x1714)
        or _in_codepoint_range(cp, 0x1732, 0x1734)
        or _in_codepoint_range(cp, 0x1752, 0x1753)
        or _in_codepoint_range(cp, 0x1772, 0x1773)
        or _in_codepoint_range(cp, 0x17B4, 0x17B5)
        or _in_codepoint_range(cp, 0x17B7, 0x17BD)
        or cp == 0x17C6
        or _in_codepoint_range(cp, 0x17C9, 0x17D3)
        or _in_codepoint_range(cp, 0x180B, 0x180F)
        or _in_codepoint_range(cp, 0x1AB0, 0x1AFF)
        or _in_codepoint_range(cp, 0x1DC0, 0x1DFF)
        or _in_codepoint_range(cp, 0x200B, 0x200F)
        or _in_codepoint_range(cp, 0x202A, 0x202E)
        or _in_codepoint_range(cp, 0x2060, 0x2064)
        or _in_codepoint_range(cp, 0x2066, 0x206F)
        or _in_codepoint_range(cp, 0x20D0, 0x20FF)
        or _in_codepoint_range(cp, 0x2CEF, 0x2CF1)
        or cp == 0x2D7F
        or _in_codepoint_range(cp, 0x2DE0, 0x2DFF)
        or _in_codepoint_range(cp, 0x302A, 0x302D)
        or _in_codepoint_range(cp, 0x3099, 0x309A)
        or _in_codepoint_range(cp, 0xA66F, 0xA672)
        or _in_codepoint_range(cp, 0xA674, 0xA67D)
        or _in_codepoint_range(cp, 0xA69E, 0xA69F)
        or _in_codepoint_range(cp, 0xA6F0, 0xA6F1)
        or _in_codepoint_range(cp, 0xA8E0, 0xA8F1)
        or _in_codepoint_range(cp, 0xA926, 0xA92D)
        or _in_codepoint_range(cp, 0xFE00, 0xFE0F)
        or _in_codepoint_range(cp, 0xFE20, 0xFE2F)
        or cp == 0xFEFF
        or _in_codepoint_range(cp, 0xFFF9, 0xFFFB)
        or _in_codepoint_range(cp, 0x1D167, 0x1D169)
        or _in_codepoint_range(cp, 0x1D17B, 0x1D182)
        or _in_codepoint_range(cp, 0x1D185, 0x1D18B)
        or _in_codepoint_range(cp, 0x1D1AA, 0x1D1AD)
        or _in_codepoint_range(cp, 0x1D242, 0x1D244)
        or _in_codepoint_range(cp, 0xE0100, 0xE01EF)
    )


def _is_wide_codepoint(cp: Int) -> Bool:
    if cp < 0x1100:
        return False
    return (
        _in_codepoint_range(cp, 0x1100, 0x115F)
        or _in_codepoint_range(cp, 0x231A, 0x231B)
        or cp == 0x2329
        or cp == 0x232A
        or _in_codepoint_range(cp, 0x23E9, 0x23EC)
        or cp == 0x23F0
        or cp == 0x23F3
        or _in_codepoint_range(cp, 0x25FD, 0x25FE)
        or _in_codepoint_range(cp, 0x2614, 0x2615)
        or _in_codepoint_range(cp, 0x2648, 0x2653)
        or cp == 0x267F
        or cp == 0x2693
        or cp == 0x26A1
        or _in_codepoint_range(cp, 0x26AA, 0x26AB)
        or _in_codepoint_range(cp, 0x26BD, 0x26BE)
        or _in_codepoint_range(cp, 0x26C4, 0x26C5)
        or cp == 0x26CE
        or cp == 0x26D4
        or cp == 0x26EA
        or _in_codepoint_range(cp, 0x26F2, 0x26F3)
        or cp == 0x26F5
        or cp == 0x26FA
        or cp == 0x26FD
        or cp == 0x2705
        or _in_codepoint_range(cp, 0x270A, 0x270B)
        or cp == 0x2728
        or cp == 0x274C
        or cp == 0x274E
        or _in_codepoint_range(cp, 0x2753, 0x2755)
        or cp == 0x2757
        or _in_codepoint_range(cp, 0x2795, 0x2797)
        or cp == 0x27B0
        or cp == 0x27BF
        or _in_codepoint_range(cp, 0x2B1B, 0x2B1C)
        or cp == 0x2B50
        or cp == 0x2B55
        or _in_codepoint_range(cp, 0x2E80, 0x303E)
        or _in_codepoint_range(cp, 0x3040, 0xA4CF)
        or _in_codepoint_range(cp, 0xA960, 0xA97C)
        or _in_codepoint_range(cp, 0xAC00, 0xD7A3)
        or _in_codepoint_range(cp, 0xF900, 0xFAFF)
        or _in_codepoint_range(cp, 0xFE10, 0xFE19)
        or _in_codepoint_range(cp, 0xFE30, 0xFE6F)
        or _in_codepoint_range(cp, 0xFF00, 0xFF60)
        or _in_codepoint_range(cp, 0xFFE0, 0xFFE6)
        or _in_codepoint_range(cp, 0x16FE0, 0x16FE4)
        or _in_codepoint_range(cp, 0x16FF0, 0x16FF1)
        or _in_codepoint_range(cp, 0x17000, 0x18D08)
        or _in_codepoint_range(cp, 0x1AFF0, 0x1AFF3)
        or _in_codepoint_range(cp, 0x1AFF5, 0x1AFFB)
        or _in_codepoint_range(cp, 0x1AFFD, 0x1AFFE)
        or _in_codepoint_range(cp, 0x1B000, 0x1B122)
        or cp == 0x1B132
        or _in_codepoint_range(cp, 0x1B150, 0x1B152)
        or cp == 0x1B155
        or _in_codepoint_range(cp, 0x1B164, 0x1B167)
        or _in_codepoint_range(cp, 0x1B170, 0x1B2FB)
        or cp == 0x1F004
        or cp == 0x1F0CF
        or cp == 0x1F18E
        or _in_codepoint_range(cp, 0x1F191, 0x1F19A)
        or _in_codepoint_range(cp, 0x1F200, 0x1F202)
        or _in_codepoint_range(cp, 0x1F210, 0x1F23B)
        or _in_codepoint_range(cp, 0x1F240, 0x1F248)
        or _in_codepoint_range(cp, 0x1F250, 0x1F265)
        or _in_codepoint_range(cp, 0x1F1E6, 0x1F1FF)
        or _in_codepoint_range(cp, 0x1F300, 0x1F64F)
        or _in_codepoint_range(cp, 0x1F680, 0x1F6FF)
        or _in_codepoint_range(cp, 0x1F7E0, 0x1F7EB)
        or cp == 0x1F7F0
        or _in_codepoint_range(cp, 0x1F900, 0x1F9FF)
        or _in_codepoint_range(cp, 0x1FA70, 0x1FAFF)
        or _in_codepoint_range(cp, 0x20000, 0x3FFFD)
    )


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


def ui_transcript_line(
    event: UiEvent, action: UiAction, view: UiView
) raises -> String:
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
    if (
        not value.contains("version")
        or value.get("version").int_value != UI_TRANSCRIPT_VERSION
    ):
        raise Error("unsupported UI transcript version")
    if (
        not value.contains("event")
        or not value.contains("action")
        or not value.contains("view")
    ):
        raise Error("incomplete UI transcript")


def _byte_range(value: String, start: Int, end: Int) -> String:
    var output = String("")
    for i in range(start, end):
        output += String(value[byte=i])
    return output^
