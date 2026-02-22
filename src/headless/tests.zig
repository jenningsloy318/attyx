const std = @import("std");
const runner = @import("runner.zig");
const Engine = @import("../term/engine.zig").Engine;
const Color = @import("../term/grid.zig").Color;

/// Helper: create a terminal, feed input, compare snapshot to expected output.
fn expectSnapshot(rows: usize, cols: usize, input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.run(alloc, rows, cols, input);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}

/// Helper: feed input as separate chunks, compare snapshot.
fn expectChunkedSnapshot(rows: usize, cols: usize, chunks: []const []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const snap = try runner.runChunked(alloc, rows, cols, chunks);
    defer alloc.free(snap);
    try std.testing.expectEqualStrings(expected, snap);
}

// ===========================================================================
// Basic printing (carried from milestone 1)
// ===========================================================================

test "golden: basic printing" {
    try expectSnapshot(3, 5, "Hello",
        "Hello\n" ++
        "     \n" ++
        "     \n");
}

test "golden: multiple characters fill left to right" {
    try expectSnapshot(2, 4, "ABCD",
        "ABCD\n" ++
        "    \n");
}

// ===========================================================================
// Line wrapping (carried from milestone 1)
// ===========================================================================

test "golden: text wraps at right edge" {
    try expectSnapshot(2, 3, "ABCDE",
        "ABC\n" ++
        "DE \n");
}

test "golden: wrap triggers scroll when grid is full" {
    try expectSnapshot(2, 3, "ABCDEF",
        "DEF\n" ++
        "   \n");
}

// ===========================================================================
// LF / CR (carried from milestone 1)
// ===========================================================================

test "golden: LF moves down, preserves column" {
    try expectSnapshot(3, 3, "A\nB",
        "A  \n" ++
        " B \n" ++
        "   \n");
}

test "golden: CR returns to column 0" {
    try expectSnapshot(2, 4, "AB\rC",
        "CB  \n" ++
        "    \n");
}

test "golden: CR LF together makes a traditional newline" {
    try expectSnapshot(3, 4, "AB\r\nCD",
        "AB  \n" ++
        "CD  \n" ++
        "    \n");
}

// ===========================================================================
// Backspace (carried from milestone 1)
// ===========================================================================

test "golden: backspace moves cursor left without erasing" {
    try expectSnapshot(2, 4, "AB\x08C",
        "AC  \n" ++
        "    \n");
}

test "golden: backspace clamps at column 0" {
    try expectSnapshot(2, 4, "\x08A",
        "A   \n" ++
        "    \n");
}

// ===========================================================================
// TAB (carried from milestone 1)
// ===========================================================================

test "golden: tab advances to next 8-column stop" {
    try expectSnapshot(2, 16, "A\tB",
        "A       B       \n" ++
        "                \n");
}

test "golden: tab clamps at last column" {
    try expectSnapshot(2, 8, "AAAAAAA\tB",
        "AAAAAAAB\n" ++
        "        \n");
}

// ===========================================================================
// Scrolling (carried from milestone 1)
// ===========================================================================

test "golden: scroll drops top row when LF at bottom" {
    try expectSnapshot(3, 4, "AAA\r\nBBB\r\nCCC\r\nDDD",
        "BBB \n" ++
        "CCC \n" ++
        "DDD \n");
}

test "golden: multiple scrolls" {
    try expectSnapshot(2, 3, "AB\r\nCD\r\nEF",
        "CD \n" ++
        "EF \n");
}

// ===========================================================================
// Escape sequence framing (carried from milestone 2)
// ===========================================================================

test "golden: ESC consumes the following byte as escape sequence" {
    try expectSnapshot(2, 4, "A\x1bBC",
        "AC  \n" ++
        "    \n");
}

test "golden: ESC non-bracket is ignored" {
    try expectSnapshot(2, 10, "\x1bXHello",
        "Hello     \n" ++
        "          \n");
}

// ===========================================================================
// Incremental parsing (carried from milestone 2)
// ===========================================================================

test "golden: ESC split across chunks" {
    try expectChunkedSnapshot(2, 10, &.{ "\x1b", "[2J", "Hello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: CSI params split across chunks" {
    try expectChunkedSnapshot(2, 10, &.{ "\x1b[31", "mHello" },
        "Hello     \n" ++
        "          \n");
}

test "golden: text interleaved with split CSI" {
    try expectChunkedSnapshot(2, 10, &.{ "AB\x1b[", "1mCD" },
        "ABCD      \n" ++
        "          \n");
}

test "golden: single-byte-at-a-time feeding" {
    try expectChunkedSnapshot(1, 5, &.{ "\x1b", "[", "3", "1", "m", "H", "i" },
        "Hi   \n");
}

// ===========================================================================
// CSI Cursor Position — CUP (NEW in milestone 3)
// ===========================================================================

test "golden: CUP moves cursor to absolute position" {
    // ESC[3;4H → row 3, col 4 (1-based) → (2,3) 0-based
    try expectSnapshot(4, 6, "\x1b[3;4HA",
        "      \n" ++
        "      \n" ++
        "   A  \n" ++
        "      \n");
}

test "golden: CUP with no params defaults to home" {
    try expectSnapshot(2, 5, "ABCDE\x1b[HX",
        "XBCDE\n" ++
        "     \n");
}

test "golden: CUP clamps to screen bounds" {
    // Move back 1 after clamping to avoid wrap at last cell
    try expectSnapshot(3, 5, "\x1b[99;99H\x1b[DX",
        "     \n" ++
        "     \n" ++
        "   X \n");
}

test "golden: CUP with f final byte" {
    try expectSnapshot(3, 5, "\x1b[2;3fX",
        "     \n" ++
        "  X  \n" ++
        "     \n");
}

// ===========================================================================
// CSI Cursor Movement — CUU/CUD/CUF/CUB (NEW in milestone 3)
// ===========================================================================

test "golden: CUF moves cursor right" {
    try expectSnapshot(2, 6, "A\x1b[2CB",
        "A  B  \n" ++
        "      \n");
}

test "golden: CUB moves cursor left" {
    try expectSnapshot(1, 6, "ABCDE\x1b[3DX",
        "ABXDE \n");
}

test "golden: CUU moves cursor up" {
    try expectSnapshot(3, 4, "A\r\nB\r\nC\x1b[2AX",
        "AX  \n" ++
        "B   \n" ++
        "C   \n");
}

test "golden: CUD moves cursor down" {
    try expectSnapshot(3, 4, "A\x1b[2BX",
        "A   \n" ++
        "    \n" ++
        " X  \n");
}

test "golden: cursor movement defaults n to 1" {
    // CUB with no param defaults to 1. X overwrites the char at cursor.
    try expectSnapshot(1, 6, "ABC\x1b[DX",
        "ABX   \n");
}

test "golden: cursor movement clamps at boundaries" {
    try expectSnapshot(2, 4, "\x1b[99AX\x1b[99DY",
        "Y   \n" ++
        "    \n");
}

// ===========================================================================
// CSI Erase in Display — ED (NEW in milestone 3)
// ===========================================================================

test "golden: erase display to end (default)" {
    try expectSnapshot(3, 5, "AAA\r\nBBB\r\nCCC\x1b[2;3H\x1b[J",
        "AAA  \n" ++
        "BB   \n" ++
        "     \n");
}

test "golden: erase display to start" {
    try expectSnapshot(3, 5, "AAAA\r\nBBBB\r\nCCCC\x1b[2;3H\x1b[1J",
        "     \n" ++
        "   B \n" ++
        "CCCC \n");
}

test "golden: erase entire display" {
    try expectSnapshot(2, 5, "AB\r\nCD\x1b[2J",
        "     \n" ++
        "     \n");
}

// ===========================================================================
// CSI Erase in Line — EL (NEW in milestone 3)
// ===========================================================================

test "golden: erase line to end (default)" {
    try expectSnapshot(2, 7, "Hello!\r\nWorld!\x1b[1;4H\x1b[K",
        "Hel    \n" ++
        "World! \n");
}

test "golden: erase line to start" {
    // Clears from col 0 to cursor col (inclusive): cols 0-3 become spaces
    try expectSnapshot(2, 7, "Hello!\r\nWorld!\x1b[1;4H\x1b[1K",
        "    o! \n" ++
        "World! \n");
}

test "golden: erase entire line" {
    try expectSnapshot(2, 6, "ABCDE\r\nFGHIJ\x1b[1;3H\x1b[2K",
        "      \n" ++
        "FGHIJ \n");
}

// ===========================================================================
// CSI SGR — colors and attributes (NEW in milestone 3)
// ===========================================================================

test "golden: SGR does not affect character output" {
    try expectSnapshot(2, 4, "\x1b[31mAB\x1b[0mCD",
        "ABCD\n" ++
        "    \n");
}

test "golden: multiple CSI sequences with text" {
    try expectSnapshot(1, 12, "\x1b[1m\x1b[31mHello\x1b[0m World",
        "Hello World \n");
}

// -- Attribute tests (inspect cell styles directly) --

test "attr: SGR 31m sets foreground to red" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[31mA\x1b[0mB");

    const cell_a = engine.state.grid.getCell(0, 0);
    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
}

test "attr: SGR 0m resets all attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[1;31;4mA\x1b[0mB");

    const cell_a = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expect(cell_a.style.bold);
    try std.testing.expect(cell_a.style.underline);

    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
    try std.testing.expect(!cell_b.style.bold);
    try std.testing.expect(!cell_b.style.underline);
}

test "attr: SGR sets foreground and background independently" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[32;43mA");

    const cell = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.green, cell.style.fg);
    try std.testing.expectEqual(Color.yellow, cell.style.bg);
}

test "attr: SGR 39 resets fg, 49 resets bg" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[31;42mA\x1b[39mB\x1b[49mC");

    const cell_a = engine.state.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell_a.style.fg);
    try std.testing.expectEqual(Color.green, cell_a.style.bg);

    const cell_b = engine.state.grid.getCell(0, 1);
    try std.testing.expectEqual(Color.default, cell_b.style.fg);
    try std.testing.expectEqual(Color.green, cell_b.style.bg);

    const cell_c = engine.state.grid.getCell(0, 2);
    try std.testing.expectEqual(Color.default, cell_c.style.fg);
    try std.testing.expectEqual(Color.default, cell_c.style.bg);
}

test "attr: bold and underline flags" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 10);
    defer engine.deinit();

    engine.feed("\x1b[1mB\x1b[4mU\x1b[0mN");

    const cell_b = engine.state.grid.getCell(0, 0);
    try std.testing.expect(cell_b.style.bold);
    try std.testing.expect(!cell_b.style.underline);

    const cell_u = engine.state.grid.getCell(0, 1);
    try std.testing.expect(cell_u.style.bold);
    try std.testing.expect(cell_u.style.underline);

    const cell_n = engine.state.grid.getCell(0, 2);
    try std.testing.expect(!cell_n.style.bold);
    try std.testing.expect(!cell_n.style.underline);
}

// ===========================================================================
// Incremental CSI with semantics (NEW in milestone 3)
// ===========================================================================

test "golden: CSI cursor movement split across chunks" {
    try expectChunkedSnapshot(3, 5, &.{ "A\x1b[3", ";2HB" },
        "A    \n" ++
        "     \n" ++
        " B   \n");
}

test "golden: CSI SGR split across chunks preserves color" {
    const alloc = std.testing.allocator;
    const snap = try runner.runChunked(alloc, 1, 4, &.{ "\x1b[3", "1mAB" });
    defer alloc.free(snap);
    try std.testing.expectEqualStrings("AB  \n", snap);

    // Also verify the color was applied by running through Engine directly
    var engine = try Engine.init(alloc, 1, 4);
    defer engine.deinit();
    engine.feed("\x1b[3");
    engine.feed("1mAB");
    try std.testing.expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
}

// ===========================================================================
// DECSTBM scroll regions (NEW in milestone 4)
// ===========================================================================

test "attr: scroll region set and reset" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 6);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);

    engine.feed("\x1b[2;4r");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);

    engine.feed("\x1b[r");
    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);
}

test "attr: invalid scroll region is ignored" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 6);
    defer engine.deinit();

    engine.feed("\x1b[2;4r");
    engine.feed("\x1b[4;2r"); // top > bottom → ignored
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);

    engine.feed("\x1b[3;3r"); // top == bottom → ignored
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);
}

test "golden: LF at region bottom scrolls within region" {
    // 5×6 grid, fill rows, set region 2..4 (1-based), LF at bottom of region.
    // Rows outside region (0 and 4) must be untouched.
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\nX",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "X     \n" ++
        "EEEEE \n");
}

test "golden: multiple LFs scroll within region repeatedly" {
    try expectSnapshot(5, 4,
        "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\nX\r\nY",
        "AAA \n" ++
        "DDD \n" ++
        "X   \n" ++
        "Y   \n" ++
        "EEE \n");
}

test "golden: wrap at region bottom triggers region scroll" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;5H" ++
        "XY",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDXY\n" ++
        "      \n" ++
        "EEEEE \n");
}

test "golden: ESC[r resets scroll region to full screen" {
    try expectSnapshot(3, 4,
        "AAA\r\nBBB\r\nCCC" ++
        "\x1b[2;3r" ++
        "\x1b[r" ++
        "\x1b[3;1H\n" ++
        "X",
        "BBB \n" ++
        "CCC \n" ++
        "X   \n");
}

test "golden: LF outside region does not trigger region scroll" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;3r" ++
        "\x1b[5;1H\n",
        "AAAAA \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "EEEEE \n");
}

test "golden: CUP moves cursor outside scroll region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[1;1HX" ++
        "\x1b[5;1HY",
        "XAAAA \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "YEEEE \n");
}

// ===========================================================================
// IND / RI — Index and Reverse Index (NEW in milestone 4)
// ===========================================================================

test "golden: IND at region bottom scrolls within region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[4;1H" ++
        "\x1bDX",
        "AAAAA \n" ++
        "CCCCC \n" ++
        "DDDDD \n" ++
        "X     \n" ++
        "EEEEE \n");
}

test "golden: RI at region top scrolls down within region" {
    try expectSnapshot(5, 6,
        "AAAAA\r\nBBBBB\r\nCCCCC\r\nDDDDD\r\nEEEEE" ++
        "\x1b[2;4r" ++
        "\x1b[2;1H" ++
        "\x1bMX",
        "AAAAA \n" ++
        "X     \n" ++
        "BBBBB \n" ++
        "CCCCC \n" ++
        "EEEEE \n");
}

test "golden: RI outside region just moves cursor up" {
    try expectSnapshot(3, 4,
        "\x1b[2;3r" ++
        "\x1b[3;1HA\r" ++
        "\x1bMB",
        "    \n" ++
        "B   \n" ++
        "A   \n");
}

// ===========================================================================
// Alternate screen (NEW in milestone 5)
// ===========================================================================

test "golden: alt screen preserves main buffer" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen is cleared on each entry" {
    try expectSnapshot(2, 5,
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l" ++
        "\x1b[?1049h",
        "     \n" ++
        "     \n");
}

test "golden: alt screen with ?47h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?47h" ++
        "ALT" ++
        "\x1b[?47l",
        "MAIN \n" ++
        "     \n");
}

test "golden: alt screen with ?1047h variant" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1047h" ++
        "ALT" ++
        "\x1b[?1047l",
        "MAIN \n" ++
        "     \n");
}

test "golden: entering alt twice is idempotent" {
    try expectSnapshot(2, 5,
        "MAIN" ++
        "\x1b[?1049h" ++
        "\x1b[?1049h" ++
        "ALT" ++
        "\x1b[?1049l",
        "MAIN \n" ++
        "     \n");
}

test "attr: cursor restored when leaving alt screen" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);

    engine.feed("\x1b[?1049h");
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), engine.state.cursor.col);

    engine.feed("\x1b[?1049l");
    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

// ===========================================================================
// Cursor save / restore (NEW in milestone 5)
// ===========================================================================

test "golden: DECSC/DECRC save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b7" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b8" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "golden: CSI s/u save and restore cursor" {
    try expectSnapshot(2, 5,
        "AB" ++
        "\x1b[s" ++
        "\x1b[2;4H" ++
        "X" ++
        "\x1b[u" ++
        "C",
        "ABC  \n" ++
        "   X \n");
}

test "attr: save/restore preserves pen attributes" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 2, 5);
    defer engine.deinit();

    engine.feed("\x1b[31m");
    engine.feed("\x1b7");
    engine.feed("\x1b[0m");
    engine.feed("\x1b8");
    engine.feed("X");

    try std.testing.expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
}

test "attr: saved cursor is per-buffer" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 3, 5);
    defer engine.deinit();

    engine.feed("\x1b[2;3H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049h");
    engine.feed("\x1b[1;5H");
    engine.feed("\x1b7");

    engine.feed("\x1b[?1049l");
    engine.feed("\x1b8");

    try std.testing.expectEqual(@as(usize, 1), engine.state.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), engine.state.cursor.col);
}

test "attr: save/restore also captures scroll region" {
    const alloc = std.testing.allocator;
    var engine = try Engine.init(alloc, 5, 4);
    defer engine.deinit();

    engine.feed("\x1b[2;4r");
    engine.feed("\x1b7");

    engine.feed("\x1b[r");
    try std.testing.expectEqual(@as(usize, 0), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), engine.state.scroll_bottom);

    engine.feed("\x1b8");
    try std.testing.expectEqual(@as(usize, 1), engine.state.scroll_top);
    try std.testing.expectEqual(@as(usize, 3), engine.state.scroll_bottom);
}
