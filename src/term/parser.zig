const std = @import("std");
const actions_mod = @import("actions.zig");

pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

const State = enum {
    ground,
    escape,
    csi,
};

/// Intermediate result of parsing CSI parameter bytes (e.g. "31;1" → [31, 1]).
/// Internal to the parser — never exposed.
const CsiParams = struct {
    params: [16]u16 = undefined,
    len: u8 = 0,
};

/// Incremental VT parser.
///
/// Consumes one byte at a time via `next()`, returning an optional Action.
/// Maintains internal state across calls so partial escape sequences that
/// span multiple `feed()` chunks are handled correctly.
///
/// Zero allocations — all state lives in fixed-size fields.
pub const Parser = struct {
    state: State = .ground,

    /// Buffer for CSI parameter/intermediate bytes (retained for debug tracing).
    csi_buf: [64]u8 = undefined,
    csi_len: usize = 0,
    /// The final byte of the last completed CSI sequence (for tracing).
    csi_final: u8 = 0,
    /// The byte that followed ESC in the last non-CSI escape (for tracing).
    last_esc_byte: u8 = 0,

    /// Process a single byte. Returns an Action if one is ready,
    /// or null if the byte was consumed as part of an incomplete sequence.
    pub fn next(self: *Parser, byte: u8) ?Action {
        return switch (self.state) {
            .ground => self.onGround(byte),
            .escape => self.onEscape(byte),
            .csi => self.onCsi(byte),
        };
    }

    // -- State handlers ----------------------------------------------------

    fn onGround(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x1B => {
                self.state = .escape;
                return null;
            },
            0x20...0x7E => return .{ .print = byte },
            '\n' => return .{ .control = .lf },
            '\r' => return .{ .control = .cr },
            0x08 => return .{ .control = .bs },
            '\t' => return .{ .control = .tab },
            else => return .nop,
        }
    }

    fn onEscape(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '[' => {
                self.state = .csi;
                self.csi_len = 0;
                return null;
            },
            0x1B => {
                return .nop;
            },
            else => {
                self.last_esc_byte = byte;
                self.state = .ground;
                return .nop;
            },
        }
    }

    fn onCsi(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            0x40...0x7E => {
                self.csi_final = byte;
                self.state = .ground;
                return self.dispatchCsi(byte);
            },
            0x1B => {
                self.state = .escape;
                return .nop;
            },
            else => {
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                }
                return null;
            },
        }
    }

    // -- CSI dispatch ------------------------------------------------------

    fn dispatchCsi(self: *Parser, final: u8) Action {
        const params = parseCsiParams(self.csi_buf[0..self.csi_len]);
        return switch (final) {
            'H', 'f' => makeCursorAbs(params),
            'A' => makeCursorRel(params, .up),
            'B' => makeCursorRel(params, .down),
            'C' => makeCursorRel(params, .right),
            'D' => makeCursorRel(params, .left),
            'J' => makeEraseDisplay(params),
            'K' => makeEraseLine(params),
            'm' => makeSgr(params),
            else => .nop,
        };
    }
};

// ---------------------------------------------------------------------------
// CSI parameter parsing (internal)
// ---------------------------------------------------------------------------

/// Parse a CSI parameter buffer like "31;1" into a list of u16 values.
/// Semicolons delimit params. Missing digits default to 0.
/// Non-digit/non-semicolon bytes (like '?' in DEC private mode) are ignored.
fn parseCsiParams(buf: []const u8) CsiParams {
    var result = CsiParams{};
    if (buf.len == 0) return result;

    var current: u32 = 0;

    for (buf) |byte| {
        if (byte >= '0' and byte <= '9') {
            current = @min(current * 10 + (byte - '0'), 65535);
        } else if (byte == ';') {
            if (result.len < 16) {
                result.params[result.len] = @intCast(current);
                result.len += 1;
            }
            current = 0;
        }
        // Ignore other bytes (e.g. '?' for DEC private modes)
    }
    if (result.len < 16) {
        result.params[result.len] = @intCast(current);
        result.len += 1;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Action constructors (internal)
// ---------------------------------------------------------------------------

/// CUP (ESC[row;colH) — default row=1, col=1, converted to 0-based.
fn makeCursorAbs(params: CsiParams) Action {
    const raw_row: u16 = if (params.len > 0) params.params[0] else 0;
    const raw_col: u16 = if (params.len > 1) params.params[1] else 0;
    return .{ .cursor_abs = .{
        .row = if (raw_row == 0) 0 else raw_row - 1,
        .col = if (raw_col == 0) 0 else raw_col - 1,
    } };
}

/// CUU/CUD/CUF/CUB — default n=1.
fn makeCursorRel(params: CsiParams, dir: actions_mod.Direction) Action {
    const raw: u16 = if (params.len > 0) params.params[0] else 0;
    return .{ .cursor_rel = .{
        .dir = dir,
        .n = if (raw == 0) 1 else raw,
    } };
}

/// ED (ESC[nJ) — default n=0 (clear to end).
fn makeEraseDisplay(params: CsiParams) Action {
    const mode: u16 = if (params.len > 0) params.params[0] else 0;
    return switch (mode) {
        0 => .{ .erase_display = .to_end },
        1 => .{ .erase_display = .to_start },
        2 => .{ .erase_display = .all },
        else => .nop,
    };
}

/// EL (ESC[nK) — default n=0 (clear to end of line).
fn makeEraseLine(params: CsiParams) Action {
    const mode: u16 = if (params.len > 0) params.params[0] else 0;
    return switch (mode) {
        0 => .{ .erase_line = .to_end },
        1 => .{ .erase_line = .to_start },
        2 => .{ .erase_line = .all },
        else => .nop,
    };
}

/// SGR (ESC[...m) — if no params, defaults to [0] (reset).
fn makeSgr(params: CsiParams) Action {
    var sgr = actions_mod.Sgr{};
    if (params.len == 0) {
        sgr.params[0] = 0;
        sgr.len = 1;
        return .{ .sgr = sgr };
    }
    const count: u8 = @intCast(@min(params.len, @as(u8, 16)));
    for (0..count) |i| {
        sgr.params[i] = @intCast(@min(params.params[i], 255));
    }
    sgr.len = count;
    return .{ .sgr = sgr };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "printable bytes produce print actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
    try std.testing.expectEqual(Action{ .print = '~' }, p.next('~').?);
    try std.testing.expectEqual(Action{ .print = ' ' }, p.next(' ').?);
}

test "control codes produce control actions" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .control = .lf }, p.next('\n').?);
    try std.testing.expectEqual(Action{ .control = .cr }, p.next('\r').?);
    try std.testing.expectEqual(Action{ .control = .bs }, p.next(0x08).?);
    try std.testing.expectEqual(Action{ .control = .tab }, p.next('\t').?);
}

test "unknown bytes produce nop" {
    var p: Parser = .{};
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x00).?);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x7F).?);
}

test "ESC enters escape state, no action emitted" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
}

test "ESC followed by non-bracket emits nop and returns to ground" {
    var p: Parser = .{};
    try std.testing.expect(p.next(0x1B) == null);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('X').?);
    try std.testing.expectEqual(Action{ .print = 'A' }, p.next('A').?);
}

test "ESC during escape cancels first, stays in escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    try std.testing.expect(p.next('[') == null);
    const a = p.next('m').?;
    switch (a) {
        .sgr => {},
        else => return error.TestUnexpectedResult,
    }
}

test "ESC during CSI cancels sequence, enters new escape" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    try std.testing.expectEqual(Action{ .nop = {} }, p.next(0x1B).?);
    try std.testing.expect(p.next('[') == null);
    const a = p.next('m').?;
    switch (a) {
        .sgr => {},
        else => return error.TestUnexpectedResult,
    }
}

test "CSI parameters are buffered for tracing" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('1');
    _ = p.next('m');
    try std.testing.expectEqualStrings("31;1", p.csi_buf[0..p.csi_len]);
    try std.testing.expectEqual(@as(u8, 'm'), p.csi_final);
}

test "returns to ground after CSI final byte" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('m');
    try std.testing.expectEqual(Action{ .print = 'Z' }, p.next('Z').?);
}

test "CSI H dispatches cursor_abs (0-based)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('5');
    _ = p.next(';');
    _ = p.next('1');
    _ = p.next('0');
    const a = p.next('H').?;
    try std.testing.expectEqual(Action{ .cursor_abs = .{ .row = 4, .col = 9 } }, a);
}

test "CSI H with no params defaults to home (0,0)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('H').?;
    try std.testing.expectEqual(Action{ .cursor_abs = .{ .row = 0, .col = 0 } }, a);
}

test "CSI A dispatches cursor_rel up" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    const a = p.next('A').?;
    try std.testing.expectEqual(Action{ .cursor_rel = .{ .dir = .up, .n = 3 } }, a);
}

test "CSI cursor_rel defaults n to 1" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('B').?;
    try std.testing.expectEqual(Action{ .cursor_rel = .{ .dir = .down, .n = 1 } }, a);
}

test "CSI J dispatches erase_display" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('2');
    const a = p.next('J').?;
    try std.testing.expectEqual(Action{ .erase_display = .all }, a);
}

test "CSI K dispatches erase_line" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('K').?;
    try std.testing.expectEqual(Action{ .erase_line = .to_end }, a);
}

test "CSI m dispatches sgr with parsed params" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('1');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 1), sgr.len);
            try std.testing.expectEqual(@as(u8, 31), sgr.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CSI m with no params defaults to reset (0)" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 1), sgr.len);
            try std.testing.expectEqual(@as(u8, 0), sgr.params[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CSI m with multiple params" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('3');
    _ = p.next('1');
    _ = p.next(';');
    _ = p.next('4');
    const a = p.next('m').?;
    switch (a) {
        .sgr => |sgr| {
            try std.testing.expectEqual(@as(u8, 3), sgr.len);
            try std.testing.expectEqual(@as(u8, 1), sgr.params[0]);
            try std.testing.expectEqual(@as(u8, 31), sgr.params[1]);
            try std.testing.expectEqual(@as(u8, 4), sgr.params[2]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unsupported CSI final byte returns nop" {
    var p: Parser = .{};
    _ = p.next(0x1B);
    _ = p.next('[');
    try std.testing.expectEqual(Action{ .nop = {} }, p.next('z').?);
}
