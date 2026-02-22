# Attyx Architecture

## Overview

Attyx is a deterministic VT-compatible terminal state machine written in Zig.
The design follows strict layer separation: parsing, state, and rendering
are fully independent.

## Data Flow

```
Raw bytes ─▸ Parser ─▸ Action ─▸ TerminalState.apply() ─▸ Grid mutation
              │                        │
              │  (no side effects)     │  (no parsing)
              ▼                        ▼
         Incremental              Pure state
         state machine            transitions
```

The **Parser** converts raw bytes into **Actions**. The **TerminalState** applies
Actions to the **Grid**. The **Engine** glues them together with a simple
`feed(bytes)` API.

## Directory Structure

```
src/
  term/              Pure terminal engine (no side effects)
    actions.zig        Action union + ControlCode enum
    parser.zig         Incremental VT parser (ground/escape/CSI states)
    state.zig          TerminalState — grid + cursor + apply(Action)
    grid.zig           Cell + Grid — 2D character storage
    snapshot.zig       Serialize grid to plain text for testing
    engine.zig         Glue layer: Parser + TerminalState
  headless/          Deterministic runner + tests
    runner.zig         Convenience functions for test harness
    tests.zig          Golden snapshot tests
  root.zig           Library root — re-exports public API
  main.zig           Executable entry point (placeholder)
```

## Layer Rules

- `term/` must not depend on PTY, windowing, rendering, clipboard, or platform APIs.
- `term/` must be fully deterministic and pure.
- Parser must never modify state directly.
- Renderer must never influence parsing or state.

## Key Types

### Action (`term/actions.zig`)

```zig
pub const Action = union(enum) {
    print: u8,                 // Write a printable ASCII byte at cursor
    control: ControlCode,      // Execute a C0 control code (LF/CR/BS/TAB)
    nop,                       // Ignored byte or unsupported sequence
    cursor_abs: CursorAbs,           // CSI H / f — absolute cursor position
    cursor_rel: CursorRel,           // CSI A/B/C/D — relative cursor movement
    erase_display: EraseMode,        // CSI J — erase in display
    erase_line: EraseMode,           // CSI K — erase in line
    sgr: Sgr,                        // CSI m — colors, bold, underline
    set_scroll_region: ScrollRegion, // CSI r — DECSTBM
    index,                           // ESC D — move down / scroll within region
    reverse_index,                   // ESC M — move up / scroll within region
    enter_alt_screen,                // ESC[?1049h — switch to alt buffer
    leave_alt_screen,                // ESC[?1049l — switch to main buffer
    save_cursor,                     // ESC 7 / CSI s — save cursor + pen
    restore_cursor,                  // ESC 8 / CSI u — restore cursor + pen
};
```

### Parser (`term/parser.zig`)

Three-state machine: Ground → Escape → CSI.

```
Ground ──ESC──▸ Escape ──[──▸ CSI
  ▲                │            │
  └──── any ◂──────┘   final ──┘
```

- `next(byte) → ?Action` — process one byte, return action or null.
- Zero allocations. All state in fixed-size struct fields.
- Handles partial sequences across `feed()` chunk boundaries.
- CSI dispatch: parses parameter bytes into integers, recognizes final byte,
  emits structured Action with parsed data (e.g., CursorAbs with row/col).

### TerminalState (`term/state.zig`)

- Owns **two** `Grid`s (main + alt) plus per-buffer cursor, pen, scroll region,
  and saved cursor. Only the "active" set of fields is used by `apply()`.
- `apply(action)` — the only way state changes.
- Scroll region (`scroll_top`, `scroll_bottom`) bounds scrolling to a subset of rows.
  Default = full screen. Only LF/IND/RI/wrap respect the region; cursor movement is screen-wide.
- **Alternate screen:** `swapBuffers()` exchanges all 6 per-buffer field pairs
  using `std.mem.swap` (zero-copy for grids). Enter clears the alt grid;
  leave restores main as-is.
- **SavedCursor:** captures cursor, pen, and scroll region. Stored per-buffer
  (swapped with the rest), so main/alt saves are isolated.

### Cell + Style (`term/grid.zig`)

- `Color` enum: `default`, `black`, `red`, `green`, `yellow`, `blue`,
  `magenta`, `cyan`, `white`.
- `Style` struct: `fg: Color`, `bg: Color`, `bold: bool`, `underline: bool`.
- `Cell` struct: `char: u8`, `style: Style`.

### Grid (`term/grid.zig`)

- Fixed-size 2D array of `Cell` values (row-major, flat allocation).
- `getCell(row, col)`, `setCell(row, col, cell)`, `clearRow(row)`, `scrollUp()`.
- `scrollUpRegion(top, bottom)`, `scrollDownRegion(top, bottom)` for DECSTBM.

### Engine (`term/engine.zig`)

- Owns Parser + TerminalState.
- `feed(bytes)` — the high-level API: parse bytes → apply actions.

### Parser DEC Private Mode

DEC private mode sequences (`ESC[?...h` / `ESC[?...l`) are recognized by
detecting a `?` prefix in the CSI parameter buffer. Supported modes:

| Mode | Set (h) | Reset (l) |
|------|---------|-----------|
| 47 / 1047 / 1049 | Enter alt screen | Leave alt screen |

Unsupported modes emit `nop`.
