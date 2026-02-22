# Attyx Milestones

## Status

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Headless terminal core (text-only) | ✅ Done |
| 2 | Action stream + parser skeleton | ✅ Done |
| 3 | Minimal CSI support (cursor, erase, SGR) | ✅ Done |
| 4 | Scroll + scrollback | Planned |
| 5 | Alternate screen | Planned |
| 6 | Damage tracking | Planned |

---

## Milestone 1: Headless Terminal Core

**Goal:** Build a fixed-size grid with a cursor that processes plain text
and basic control characters. No escape sequences, no PTY, no rendering.

**What was built:**

- `Cell` type (stores one ASCII byte, default space).
- `Grid` type (flat row-major `[]Cell` array, single allocation).
- `TerminalState` with cursor and `feed(bytes)` (later refactored in M2).
- Snapshot serialization to plain text for golden testing.
- Headless runner for test convenience.

**Byte handling:**

| Byte | Name | Behavior |
|------|------|----------|
| 0x20–0x7E | Printable ASCII | Write to grid at cursor, advance cursor |
| 0x0A | LF (line feed) | Move cursor down one row (does NOT reset column) |
| 0x0D | CR (carriage return) | Move cursor to column 0 |
| 0x08 | BS (backspace) | Move cursor left by 1, clamp at 0, no erase |
| 0x09 | TAB | Advance to next 8-column tab stop, clamp at last column |
| Everything else | — | Ignored |

**Line wrapping:** When a printable character is written at the last column,
the cursor wraps to column 0 of the next row. If that row is past the bottom,
the grid scrolls up.

**Scrolling:** Drop top row, shift all rows up by one, clear new bottom row.
No scrollback buffer — scrolled-off content is lost.

**Tests added:** 28 (grid unit tests, state unit tests, snapshot tests,
golden behavior tests).

---

## Milestone 2: Action Stream + Parser Skeleton

**Goal:** Decouple parsing from state mutation. Introduce an Action type
so the parser emits actions and the state only applies them.

**Architecture change:**

```
Before:  bytes → TerminalState.feed() → grid (parsing + mutation coupled)
After:   bytes → Parser.next() → Action → TerminalState.apply() → grid
```

**What was built:**

- `Action` tagged union: `print(u8)`, `control(ControlCode)`, `nop`.
- `Parser` — incremental 3-state machine (ground / escape / CSI).
- `TerminalState.apply(action)` — replaces old `feed(bytes)`.
- `Engine` — owns Parser + TerminalState, provides `feed(bytes)` API.
- `runChunked()` for testing sequences split across chunk boundaries.

**Parser states:**

| State | Entered by | Exits on |
|-------|------------|----------|
| Ground | Default / after sequence | ESC → Escape; printable/control → emit action |
| Escape | ESC byte | `[` → CSI; any other → Nop, back to Ground |
| CSI | ESC + `[` | Final byte (0x40–0x7E) → Nop, back to Ground |

**Key design decisions:**

- `next(byte) → ?Action`: one byte in, zero or one action out.
  Null means "byte consumed, no complete action yet" (e.g., ESC entering escape state).
- CSI sequences are fully consumed but emit Nop (semantics deferred to M3).
- CSI parameter bytes are buffered in a fixed [64]u8 for future use and tracing.
- Parser is zero-allocation and fully incremental across chunk boundaries.

**Behavioral change from M1:**
ESC is no longer simply skipped. It enters escape state and consumes the
following byte as part of the escape sequence. This matches real VT100 behavior
where ESC is always at least a two-byte sequence.

**Tests added:** 20 new (48 total). Covers parser unit tests, ESC/CSI golden
tests, and incremental chunk-splitting tests.

---

## Milestone 3: Minimal CSI Semantics

**Goal:** CSI sequences actually do things. Extend the parser to produce
structured actions with parsed parameters, and implement them in the state.

**What was built:**

- `Color` enum (8 standard ANSI colors + default).
- `Style` struct (fg, bg, bold, underline) attached to every `Cell`.
- The "pen" — current text attributes in `TerminalState`, stamped onto every printed cell.
- CSI parameter parsing: `"31;1"` → `[31, 1]`. Handles semicolons, missing params, overflow.
- Structured CSI dispatch in the parser for 5 CSI command types.
- State implementation for all 5 CSI commands.

**Supported CSI sequences:**

| Sequence | Name | Behavior |
|----------|------|----------|
| `ESC[{r};{c}H` | CUP (Cursor Position) | Move cursor to absolute position (1-based, default 1;1) |
| `ESC[{r};{c}f` | HVP | Same as CUP |
| `ESC[{n}A` | CUU (Cursor Up) | Move cursor up by n (default 1), clamp at row 0 |
| `ESC[{n}B` | CUD (Cursor Down) | Move cursor down by n, clamp at last row |
| `ESC[{n}C` | CUF (Cursor Forward) | Move cursor right by n, clamp at last col |
| `ESC[{n}D` | CUB (Cursor Back) | Move cursor left by n, clamp at col 0 |
| `ESC[{n}J` | ED (Erase in Display) | 0: cursor→end, 1: start→cursor, 2: all |
| `ESC[{n}K` | EL (Erase in Line) | 0: cursor→EOL, 1: BOL→cursor, 2: full line |
| `ESC[{...}m` | SGR (Select Graphic Rendition) | See below |

**SGR codes supported:**

| Code | Effect |
|------|--------|
| 0 | Reset all attributes |
| 1 | Bold |
| 4 | Underline |
| 30–37 | Set foreground (black, red, green, yellow, blue, magenta, cyan, white) |
| 39 | Reset foreground to default |
| 40–47 | Set background (same 8 colors) |
| 49 | Reset background to default |

**New Action variants:**

```zig
cursor_abs: CursorAbs,    // CSI H / f
cursor_rel: CursorRel,    // CSI A/B/C/D
erase_display: EraseMode,  // CSI J
erase_line: EraseMode,     // CSI K
sgr: Sgr,                  // CSI m
```

**Data model change:** `Cell` now stores `Style` alongside `char`. Snapshot
format remains text-only (characters only) — style is verified through
programmatic attribute tests.

**Tests added:** 33 new (81 total). Includes golden snapshot tests for all
CSI commands, SGR attribute tests (direct cell inspection), and incremental
parsing tests for CSI with parameters split across chunks.
