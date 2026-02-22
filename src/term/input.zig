const std = @import("std");
const actions_mod = @import("actions.zig");

pub const MouseTrackingMode = actions_mod.MouseTrackingMode;

pub const MouseButton = enum {
    left,
    middle,
    right,
    none,
};

pub const MouseEventKind = enum {
    press,
    release,
    move,
    scroll_up,
    scroll_down,
};

pub const MouseEvent = struct {
    kind: MouseEventKind,
    button: MouseButton = .none,
    x: u16 = 1,
    y: u16 = 1,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const InputError = error{BufferTooSmall};

/// Wrap text for bracketed paste mode.
/// If enabled, surrounds the text with ESC[200~ ... ESC[201~.
/// Writes into the caller-provided buffer; no allocations.
pub fn wrapPaste(enabled: bool, text: []const u8, out: []u8) InputError![]const u8 {
    if (!enabled) {
        if (out.len < text.len) return error.BufferTooSmall;
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }
    const prefix = "\x1b[200~";
    const suffix = "\x1b[201~";
    const total = prefix.len + text.len + suffix.len;
    if (out.len < total) return error.BufferTooSmall;
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..text.len], text);
    @memcpy(out[prefix.len + text.len..][0..suffix.len], suffix);
    return out[0..total];
}

/// Encode a mouse event in SGR format (CSI < Cb ; Cx ; Cy M/m).
/// Returns a slice of `out` with the encoded bytes, or an empty slice
/// when the current modes don't require reporting this event.
/// Only SGR encoding is produced; legacy X10 is not implemented.
pub fn encodeMouse(
    tracking: MouseTrackingMode,
    sgr_enabled: bool,
    ev: MouseEvent,
    out: []u8,
) []const u8 {
    if (tracking == .off) return out[0..0];
    if (!sgr_enabled) return out[0..0];
    if (ev.kind == .move and tracking != .any_event) return out[0..0];

    var cb: u8 = switch (ev.kind) {
        .press, .release => switch (ev.button) {
            .left => @as(u8, 0),
            .middle => 1,
            .right => 2,
            .none => 0,
        },
        .move => switch (ev.button) {
            .left => @as(u8, 32),
            .middle => 33,
            .right => 34,
            .none => 35,
        },
        .scroll_up => 64,
        .scroll_down => 65,
    };

    if (ev.shift) cb += 4;
    if (ev.alt) cb += 8;
    if (ev.ctrl) cb += 16;

    const final: u8 = if (ev.kind == .release) 'm' else 'M';

    return std.fmt.bufPrint(out, "\x1b[<{d};{d};{d}{c}", .{
        cb, ev.x, ev.y, final,
    }) catch return out[0..0];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "wrapPaste disabled passes through text" {
    var buf: [64]u8 = undefined;
    const result = try wrapPaste(false, "abc", &buf);
    try testing.expectEqualStrings("abc", result);
}

test "wrapPaste enabled wraps with brackets" {
    var buf: [64]u8 = undefined;
    const result = try wrapPaste(true, "abc", &buf);
    try testing.expectEqualStrings("\x1b[200~abc\x1b[201~", result);
}

test "wrapPaste enabled buffer too small" {
    var buf: [4]u8 = undefined;
    const result = wrapPaste(true, "abc", &buf);
    try testing.expectError(error.BufferTooSmall, result);
}

test "wrapPaste disabled empty text" {
    var buf: [64]u8 = undefined;
    const result = try wrapPaste(false, "", &buf);
    try testing.expectEqualStrings("", result);
}

test "wrapPaste enabled empty text still wraps" {
    var buf: [64]u8 = undefined;
    const result = try wrapPaste(true, "", &buf);
    try testing.expectEqualStrings("\x1b[200~\x1b[201~", result);
}

test "encodeMouse off returns empty" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.off, true, .{ .kind = .press, .button = .left }, &buf);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "encodeMouse sgr disabled returns empty" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, false, .{ .kind = .press, .button = .left }, &buf);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "encodeMouse left press SGR" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .left,
        .x = 10,
        .y = 5,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<0;10;5M", result);
}

test "encodeMouse left release SGR" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .release,
        .button = .left,
        .x = 10,
        .y = 5,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<0;10;5m", result);
}

test "encodeMouse scroll up SGR" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .scroll_up,
        .x = 3,
        .y = 4,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<64;3;4M", result);
}

test "encodeMouse scroll down SGR" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .scroll_down,
        .x = 1,
        .y = 1,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<65;1;1M", result);
}

test "encodeMouse ctrl+left press" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .left,
        .x = 10,
        .y = 5,
        .ctrl = true,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<16;10;5M", result);
}

test "encodeMouse shift+middle press" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .middle,
        .x = 2,
        .y = 3,
        .shift = true,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<5;2;3M", result);
}

test "encodeMouse move only in any_event mode" {
    var buf: [64]u8 = undefined;
    const ev = MouseEvent{
        .kind = .move,
        .button = .left,
        .x = 5,
        .y = 6,
    };
    // x10: move suppressed
    try testing.expectEqual(@as(usize, 0), encodeMouse(.x10, true, ev, &buf).len);
    // button_event: move suppressed (MVP simplification)
    try testing.expectEqual(@as(usize, 0), encodeMouse(.button_event, true, ev, &buf).len);
    // any_event: move emitted
    const result = encodeMouse(.any_event, true, ev, &buf);
    try testing.expectEqualStrings("\x1b[<32;5;6M", result);
}

test "encodeMouse right press" {
    var buf: [64]u8 = undefined;
    const result = encodeMouse(.x10, true, .{
        .kind = .press,
        .button = .right,
        .x = 1,
        .y = 1,
    }, &buf);
    try testing.expectEqualStrings("\x1b[<2;1;1M", result);
}
