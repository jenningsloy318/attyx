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
    cursor_abs: CursorAbs,     // CSI H / f — absolute cursor position
    cursor_rel: CursorRel,     // CSI A/B/C/D — relative cursor movement
    erase_display: EraseMode,  // CSI J — erase in display
    erase_line: EraseMode,     // CSI K — erase in line
    sgr: Sgr,                  // CSI m — colors, bold, underline
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

- Owns a `Grid`, a `Cursor`, and a `pen` (current `Style`).
- `apply(action)` — the only way state changes.
- Private helpers: `printChar`, `lineFeed`, `carriageReturn`, `backspace`,
  `tab`, `cursorDown`, `cursorAbsolute`, `cursorRelative`, `eraseInDisplay`,
  `eraseInLine`, `applySgr`.

### Cell + Style (`term/grid.zig`)

- `Color` enum: `default`, `black`, `red`, `green`, `yellow`, `blue`,
  `magenta`, `cyan`, `white`.
- `Style` struct: `fg: Color`, `bg: Color`, `bold: bool`, `underline: bool`.
- `Cell` struct: `char: u8`, `style: Style`.

### Grid (`term/grid.zig`)

- Fixed-size 2D array of `Cell` values (row-major, flat allocation).
- `getCell(row, col)`, `setCell(row, col, cell)`, `clearRow(row)`, `scrollUp()`.

### Engine (`term/engine.zig`)

- Owns Parser + TerminalState.
- `feed(bytes)` — the high-level API: parse bytes → apply actions.
