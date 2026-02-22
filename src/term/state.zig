const std = @import("std");
const grid_mod = @import("grid.zig");
const actions_mod = @import("actions.zig");

pub const Grid = grid_mod.Grid;
pub const Cell = grid_mod.Cell;
pub const Color = grid_mod.Color;
pub const Style = grid_mod.Style;
pub const Action = actions_mod.Action;
pub const ControlCode = actions_mod.ControlCode;

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
};

/// Snapshot of cursor + attributes, captured by DECSC / CSI s.
pub const SavedCursor = struct {
    cursor: Cursor,
    pen: Style,
    scroll_top: usize,
    scroll_bottom: usize,
};

pub const TerminalState = struct {
    // -- Active buffer state (the currently displayed screen) ---------------
    grid: Grid,
    cursor: Cursor = .{},
    pen: Style = .{},
    scroll_top: usize = 0,
    scroll_bottom: usize = 0,
    saved_cursor: ?SavedCursor = null,

    // -- Inactive buffer state (swapped on alt screen toggle) --------------
    inactive_grid: Grid,
    inactive_cursor: Cursor = .{},
    inactive_pen: Style = .{},
    inactive_scroll_top: usize = 0,
    inactive_scroll_bottom: usize = 0,
    inactive_saved_cursor: ?SavedCursor = null,

    /// True when the alternate screen is the active buffer.
    alt_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !TerminalState {
        var main_grid = try Grid.init(allocator, rows, cols);
        errdefer main_grid.deinit();
        const alt_grid = try Grid.init(allocator, rows, cols);
        return .{
            .grid = main_grid,
            .scroll_bottom = rows - 1,
            .inactive_grid = alt_grid,
            .inactive_scroll_bottom = rows - 1,
        };
    }

    pub fn deinit(self: *TerminalState) void {
        self.grid.deinit();
        self.inactive_grid.deinit();
    }

    /// Apply a single Action to the terminal state.
    pub fn apply(self: *TerminalState, action: Action) void {
        switch (action) {
            .print => |byte| self.printChar(byte),
            .control => |code| switch (code) {
                .lf => self.lineFeed(),
                .cr => self.carriageReturn(),
                .bs => self.backspace(),
                .tab => self.tab(),
            },
            .nop => {},
            .cursor_abs => |abs| self.cursorAbsolute(abs),
            .cursor_rel => |rel| self.cursorRelative(rel),
            .erase_display => |mode| self.eraseInDisplay(mode),
            .erase_line => |mode| self.eraseInLine(mode),
            .sgr => |sgr| self.applySgr(sgr),
            .set_scroll_region => |region| self.setScrollRegion(region),
            .index => self.cursorDown(),
            .reverse_index => self.reverseIndex(),
            .enter_alt_screen => self.enterAltScreen(),
            .leave_alt_screen => self.leaveAltScreen(),
            .save_cursor => self.saveCursor(),
            .restore_cursor => self.restoreCursor(),
        }
    }

    // -- Text output -------------------------------------------------------

    fn printChar(self: *TerminalState, char: u8) void {
        self.grid.setCell(self.cursor.row, self.cursor.col, .{
            .char = char,
            .style = self.pen,
        });
        self.cursor.col += 1;
        if (self.cursor.col >= self.grid.cols) {
            self.cursor.col = 0;
            self.cursorDown();
        }
    }

    // -- C0 control characters ---------------------------------------------

    fn lineFeed(self: *TerminalState) void {
        self.cursorDown();
    }

    fn carriageReturn(self: *TerminalState) void {
        self.cursor.col = 0;
    }

    fn backspace(self: *TerminalState) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        }
    }

    fn tab(self: *TerminalState) void {
        const next_stop = ((self.cursor.col / 8) + 1) * 8;
        self.cursor.col = @min(next_stop, self.grid.cols - 1);
    }

    fn cursorDown(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_bottom) {
            self.grid.scrollUpRegion(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row < self.grid.rows - 1) {
            self.cursor.row += 1;
        }
    }

    fn reverseIndex(self: *TerminalState) void {
        if (self.cursor.row == self.scroll_top) {
            self.grid.scrollDownRegion(self.scroll_top, self.scroll_bottom);
        } else if (self.cursor.row > 0) {
            self.cursor.row -= 1;
        }
    }

    // -- CSI cursor positioning --------------------------------------------

    fn cursorAbsolute(self: *TerminalState, abs: actions_mod.CursorAbs) void {
        self.cursor.row = @min(@as(usize, abs.row), self.grid.rows - 1);
        self.cursor.col = @min(@as(usize, abs.col), self.grid.cols - 1);
    }

    fn cursorRelative(self: *TerminalState, rel: actions_mod.CursorRel) void {
        const n: usize = @intCast(rel.n);
        switch (rel.dir) {
            .up => self.cursor.row -|= n,
            .down => self.cursor.row = @min(self.cursor.row +| n, self.grid.rows - 1),
            .right => self.cursor.col = @min(self.cursor.col +| n, self.grid.cols - 1),
            .left => self.cursor.col -|= n,
        }
    }

    // -- CSI erase ---------------------------------------------------------

    fn eraseInDisplay(self: *TerminalState, mode: actions_mod.EraseMode) void {
        const cols = self.grid.cols;
        switch (mode) {
            .to_end => {
                const start = self.cursor.row * cols + self.cursor.col;
                @memset(self.grid.cells[start..], Cell{});
            },
            .to_start => {
                const end = self.cursor.row * cols + self.cursor.col + 1;
                @memset(self.grid.cells[0..end], Cell{});
            },
            .all => {
                @memset(self.grid.cells, Cell{});
            },
        }
    }

    fn eraseInLine(self: *TerminalState, mode: actions_mod.EraseMode) void {
        const cols = self.grid.cols;
        const row_start = self.cursor.row * cols;
        switch (mode) {
            .to_end => {
                @memset(self.grid.cells[row_start + self.cursor.col .. row_start + cols], Cell{});
            },
            .to_start => {
                @memset(self.grid.cells[row_start .. row_start + self.cursor.col + 1], Cell{});
            },
            .all => {
                self.grid.clearRow(self.cursor.row);
            },
        }
    }

    // -- CSI SGR -----------------------------------------------------------

    fn applySgr(self: *TerminalState, sgr: actions_mod.Sgr) void {
        for (sgr.params[0..sgr.len]) |param| {
            switch (param) {
                0 => self.pen = .{},
                1 => self.pen.bold = true,
                4 => self.pen.underline = true,
                30...37 => self.pen.fg = @enumFromInt(param - 29),
                39 => self.pen.fg = .default,
                40...47 => self.pen.bg = @enumFromInt(param - 39),
                49 => self.pen.bg = .default,
                else => {},
            }
        }
    }

    // -- DECSTBM -----------------------------------------------------------

    fn setScrollRegion(self: *TerminalState, region: actions_mod.ScrollRegion) void {
        const rows = self.grid.rows;
        const top_1: usize = if (region.top == 0) 1 else @intCast(@min(region.top, @as(u16, @intCast(rows))));
        const bottom_1: usize = if (region.bottom == 0) rows else @intCast(@min(region.bottom, @as(u16, @intCast(rows))));

        const top = top_1 - 1;
        const bottom = bottom_1 - 1;

        if (top >= bottom) return;

        self.scroll_top = top;
        self.scroll_bottom = bottom;
    }

    // -- Alternate screen --------------------------------------------------

    fn swapBuffers(self: *TerminalState) void {
        std.mem.swap(Grid, &self.grid, &self.inactive_grid);
        std.mem.swap(Cursor, &self.cursor, &self.inactive_cursor);
        std.mem.swap(Style, &self.pen, &self.inactive_pen);
        std.mem.swap(usize, &self.scroll_top, &self.inactive_scroll_top);
        std.mem.swap(usize, &self.scroll_bottom, &self.inactive_scroll_bottom);
        std.mem.swap(?SavedCursor, &self.saved_cursor, &self.inactive_saved_cursor);
    }

    fn enterAltScreen(self: *TerminalState) void {
        if (self.alt_active) return;
        self.swapBuffers();
        @memset(self.grid.cells, Cell{});
        self.cursor = .{};
        self.pen = .{};
        self.scroll_top = 0;
        self.scroll_bottom = self.grid.rows - 1;
        self.saved_cursor = null;
        self.alt_active = true;
    }

    fn leaveAltScreen(self: *TerminalState) void {
        if (!self.alt_active) return;
        self.swapBuffers();
        self.alt_active = false;
    }

    // -- Cursor save / restore ---------------------------------------------

    fn saveCursor(self: *TerminalState) void {
        self.saved_cursor = .{
            .cursor = self.cursor,
            .pen = self.pen,
            .scroll_top = self.scroll_top,
            .scroll_bottom = self.scroll_bottom,
        };
    }

    fn restoreCursor(self: *TerminalState) void {
        if (self.saved_cursor) |saved| {
            self.cursor = saved.cursor;
            self.pen = saved.pen;
            self.scroll_top = saved.scroll_top;
            self.scroll_bottom = saved.scroll_bottom;
        }
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "apply print writes to grid and advances cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u8, 'A'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.bs clamps at column 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .control = .bs });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
}

test "apply control.cr resets column to 0" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .print = 'B' });
    t.apply(.{ .control = .cr });
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
}

test "apply control.lf moves down, preserves column" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.apply(.{ .print = 'A' });
    t.apply(.{ .control = .lf });
    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 1), t.cursor.col);
}

test "apply control.tab advances to next 8-column stop" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 20);
    defer t.deinit();

    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 8), t.cursor.col);
    t.apply(.{ .control = .tab });
    try std.testing.expectEqual(@as(usize, 16), t.cursor.col);
}

test "apply nop has no effect" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    const row_before = t.cursor.row;
    const col_before = t.cursor.col;
    t.apply(.{ .nop = {} });
    try std.testing.expectEqual(row_before, t.cursor.row);
    try std.testing.expectEqual(col_before, t.cursor.col);
    try std.testing.expectEqual(@as(u8, 'X'), t.grid.getCell(0, 0).char);
}

test "printed cells carry current pen style" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.pen = .{ .fg = .red, .bold = true };
    t.apply(.{ .print = 'A' });
    const cell = t.grid.getCell(0, 0);
    try std.testing.expectEqual(Color.red, cell.style.fg);
    try std.testing.expect(cell.style.bold);
}

test "default scroll region is full screen" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 5, 4);
    defer t.deinit();

    try std.testing.expectEqual(@as(usize, 0), t.scroll_top);
    try std.testing.expectEqual(@as(usize, 4), t.scroll_bottom);
}

test "reverse index at top of region scrolls down" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 5, 2);
    defer t.deinit();

    t.grid.setCell(1, 0, .{ .char = 'B' });
    t.grid.setCell(2, 0, .{ .char = 'C' });
    t.grid.setCell(3, 0, .{ .char = 'D' });
    t.scroll_top = 1;
    t.scroll_bottom = 3;
    t.cursor.row = 1;
    t.apply(.reverse_index);

    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(u8, ' '), t.grid.getCell(1, 0).char);
    try std.testing.expectEqual(@as(u8, 'B'), t.grid.getCell(2, 0).char);
    try std.testing.expectEqual(@as(u8, 'C'), t.grid.getCell(3, 0).char);
}

test "enter alt screen clears grid and resets cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'X' });
    t.apply(.enter_alt_screen);

    try std.testing.expect(t.alt_active);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), t.cursor.col);
    try std.testing.expectEqual(@as(u8, ' '), t.grid.getCell(0, 0).char);
}

test "leave alt screen restores main buffer" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 2, 4);
    defer t.deinit();

    t.apply(.{ .print = 'M' });
    const saved_col = t.cursor.col;
    t.apply(.enter_alt_screen);
    t.apply(.{ .print = 'A' });
    t.apply(.leave_alt_screen);

    try std.testing.expect(!t.alt_active);
    try std.testing.expectEqual(@as(u8, 'M'), t.grid.getCell(0, 0).char);
    try std.testing.expectEqual(saved_col, t.cursor.col);
}

test "save and restore cursor" {
    const alloc = std.testing.allocator;
    var t = try TerminalState.init(alloc, 3, 4);
    defer t.deinit();

    t.cursor = .{ .row = 1, .col = 2 };
    t.pen = .{ .fg = .red };
    t.apply(.save_cursor);

    t.cursor = .{ .row = 0, .col = 0 };
    t.pen = .{};
    t.apply(.restore_cursor);

    try std.testing.expectEqual(@as(usize, 1), t.cursor.row);
    try std.testing.expectEqual(@as(usize, 2), t.cursor.col);
    try std.testing.expectEqual(Color.red, t.pen.fg);
}
