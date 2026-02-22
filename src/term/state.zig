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

pub const TerminalState = struct {
    grid: Grid,
    cursor: Cursor = .{},
    /// The "pen" — current text attributes applied to every newly printed cell.
    pen: Style = .{},

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !TerminalState {
        return .{
            .grid = try Grid.init(allocator, rows, cols),
        };
    }

    pub fn deinit(self: *TerminalState) void {
        self.grid.deinit();
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
        self.cursor.row += 1;
        if (self.cursor.row >= self.grid.rows) {
            self.grid.scrollUp();
            self.cursor.row = self.grid.rows - 1;
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

    // -- CSI SGR (Select Graphic Rendition) --------------------------------

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
