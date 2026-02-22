/// The set of control codes handled by the terminal.
pub const ControlCode = enum {
    lf,
    cr,
    bs,
    tab,
};

/// Direction for relative cursor movement (CUU/CUD/CUF/CUB).
pub const Direction = enum {
    up,
    down,
    right,
    left,
};

/// Mode argument for erase operations (ED / EL).
pub const EraseMode = enum(u2) {
    to_end = 0,
    to_start = 1,
    all = 2,
};

/// Absolute cursor positioning (CUP). Values are 0-based.
/// The parser converts from the 1-based CSI encoding.
pub const CursorAbs = struct {
    row: u16 = 0,
    col: u16 = 0,
};

/// Relative cursor movement (CUU / CUD / CUF / CUB).
pub const CursorRel = struct {
    dir: Direction,
    n: u16 = 1,
};

/// SGR (Select Graphic Rendition) parameters.
/// Carries the raw numeric codes for the state to interpret.
pub const Sgr = struct {
    params: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 0,
};

/// A single terminal action produced by the parser.
///
/// The parser converts raw bytes into Actions; TerminalState
/// consumes Actions and mutates the grid.
pub const Action = union(enum) {
    /// Write a printable ASCII byte at the cursor position.
    print: u8,
    /// Execute a C0 control code (LF, CR, BS, TAB).
    control: ControlCode,
    /// No-op: ignored byte or unsupported escape sequence.
    nop,
    /// CSI H / f — set cursor to absolute position (0-based).
    cursor_abs: CursorAbs,
    /// CSI A/B/C/D — move cursor relative to current position.
    cursor_rel: CursorRel,
    /// CSI J — erase in display.
    erase_display: EraseMode,
    /// CSI K — erase in line.
    erase_line: EraseMode,
    /// CSI m — select graphic rendition (colors, bold, underline).
    sgr: Sgr,
};
