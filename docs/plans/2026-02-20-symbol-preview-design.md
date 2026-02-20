# Symbol Preview + Line Number Alignment

**Date:** 2026-02-20
**File:** `vim/autoload/yac.vim` only — no daemon changes.

## Problem

The picker's symbol modes (`workspace_symbol`, `document_symbol`) display results but don't preview the symbol location while navigating. Line numbers are also absent, making it hard to tell where in a file a symbol lives.

## Design

### New State Fields

Two fields added to `s:picker`:

```vim
'preview': 0,    " 1 = call s:picker_preview() after each navigation step
'lnum_width': 0, " >0 = prepend right-aligned line number of this width
```

Both reset to `0` in `s:picker_close_popups()`.

### When Fields Are Set

In `s:picker_update_results(items)`, after storing items:

- If `s:picker.mode` is `workspace_symbol` or `document_symbol`:
  - Scan items for max `line + 1`, compute digit count → `s:picker.lnum_width`
  - Set `s:picker.preview = 1`
- Otherwise: both remain `0` (file mode unchanged, references mode uses its own path)

### Rendering (`s:picker_highlight_selected`)

In flat (non-grouped) mode, if `lnum_width > 0`, prepend the line number:

```
  {lnum}: symbolName  file.zig    ← normal item
> {lnum}: symbolName  file.zig    ← selected item
```

Format: `printf('%*d: ', s:picker.lnum_width, get(item, 'line', 0) + 1)`

If `lnum_width == 0` (file mode), rendering is unchanged.

### Navigation

After updating selection in flat mode (`s:picker_select_next` / `s:picker_select_prev`):

```vim
call s:picker_highlight_selected()
if s:picker.preview
  call s:picker_preview()
endif
```

`s:picker_preview()` requires no changes — it already reads `file`/`line`/`column` from the selected item.

## Symmetry

| Field       | Set by              | Governs                        |
|-------------|---------------------|--------------------------------|
| `grouped`   | `picker_open_references` | grouped display + header-skip nav |
| `preview`   | `picker_update_results` (symbol modes) | auto-preview on navigate |
| `lnum_width`| `picker_update_results` (symbol modes) | line number column width       |

## Out of Scope

- File mode preview (items have `line: 0`, no meaningful jump target)
- References line numbers (already rendered as `lnum: text` in label)
- Position restore for symbol preview (Esc already closes picker without navigate)
