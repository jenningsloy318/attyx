# Testing

## How to Run Tests

```bash
zig build test                # run all tests
zig build test --summary all  # run with detailed summary
```

## Test Strategy

All tests run in **headless mode** — no PTY, no window, no OS interaction.
The terminal core is fully deterministic, so given the same input bytes,
it always produces the same grid state.

### Test Layers

1. **Unit tests** (colocated in each module)
   - `grid.zig`: Cell creation, get/set, clearRow, scrollUp.
   - `parser.zig`: State transitions, action emission, buffering.
   - `state.zig`: Individual `apply()` calls for each action type.
   - `snapshot.zig`: Serialization correctness.

2. **Golden snapshot tests** (`headless/tests.zig`)
   - Create a terminal of known size.
   - Feed specific bytes.
   - Compare the grid snapshot against an exact expected string.
   - If even one space is wrong, the test fails with a diff.

3. **Incremental chunk tests** (`headless/tests.zig`)
   - Feed the same input split across multiple `feed()` calls.
   - Verifies the parser handles partial sequences correctly.

### Snapshot Format

The snapshot is a plain text string: exactly `rows` lines, each exactly `cols`
characters wide. Trailing spaces are preserved (not trimmed). Each row ends
with `\n`.

Example: a 3×5 grid with "Hi" at position (0,0):

```
Hi   
     
     
```

Total bytes: `3 × (5 + 1) = 18` (5 chars + newline per row).

### Test Helper Functions

```zig
// Feed input to a terminal of given size, compare snapshot
fn expectSnapshot(rows, cols, input, expected) !void

// Feed input as separate chunks, compare snapshot
fn expectChunkedSnapshot(rows, cols, chunks, expected) !void
```

### Attribute tests (`headless/tests.zig`)

SGR tests cannot rely on snapshots (snapshots are text-only, no style info).
Instead, these tests create an `Engine`, feed input, and inspect `Cell.style`
directly:

```zig
var engine = try Engine.init(alloc, 2, 10);
engine.feed("\x1b[31mA\x1b[0mB");
try expectEqual(Color.red, engine.state.grid.getCell(0, 0).style.fg);
try expectEqual(Color.default, engine.state.grid.getCell(0, 1).style.fg);
```

## Current Test Count

| Module | Tests |
|--------|-------|
| grid.zig | 7 |
| parser.zig | 30 |
| state.zig | 12 |
| snapshot.zig | 2 |
| engine.zig | 1 |
| runner.zig | 2 |
| tests.zig (golden + attr) | 68 |
| **Total** | **122** |
