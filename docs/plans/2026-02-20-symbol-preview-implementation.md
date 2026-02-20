# Symbol Preview + Line Number Alignment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add live preview (jump to symbol while navigating) and aligned line numbers for `workspace_symbol` and `document_symbol` picker modes.

**Architecture:** All changes are Vim-side only in `vim/autoload/yac.vim`. Two new flags on the `s:picker` state dict (`preview`, `lnum_width`) control behaviour. `s:picker_update_results` detects symbol mode and sets them; `s:picker_highlight_selected` reads `lnum_width` for rendering; `s:picker_select_next/prev` call the already-existing `s:picker_preview()` when `preview == 1`.

**Tech Stack:** VimScript, Vim popup API (`popup_settext`, `win_execute`, `matchaddpos`).

---

### Task 1: Add `preview` and `lnum_width` to `s:picker` state dict

**Files:**
- Modify: `vim/autoload/yac.vim:98-111` (the `s:picker` dict literal)

**Step 1: Add the two fields**

Find this block (lines 98–111):
```vim
let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'items': [],
  \ 'selected': 0,
  \ 'timer_id': -1,
  \ 'last_query': '',
  \ 'mode': '',
  \ 'grouped': 0,
  \ 'all_locations': [],
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ }
```

Replace with:
```vim
let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'items': [],
  \ 'selected': 0,
  \ 'timer_id': -1,
  \ 'last_query': '',
  \ 'mode': '',
  \ 'grouped': 0,
  \ 'preview': 0,
  \ 'lnum_width': 0,
  \ 'all_locations': [],
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ }
```

**Step 2: Reset the new fields in `s:picker_close_popups()`**

Find `s:picker_close_popups()` (around line 2707). The end of that function currently resets `grouped` and other fields. Add two lines after `let s:picker.grouped = 0`:

```vim
  let s:picker.preview = 0
  let s:picker.lnum_width = 0
```

**Step 3: Verify the file loads without error**

```bash
vim --clean -u vim/autoload/yac.vim -c 'echo "OK"' -c 'qa!'
```
Expected: prints `OK`, no error messages.

**Step 4: Commit**

```bash
git add vim/autoload/yac.vim
git commit -m "feat(picker): add preview and lnum_width state fields"
```

---

### Task 2: Set `preview` and `lnum_width` in `s:picker_update_results`

**Files:**
- Modify: `vim/autoload/yac.vim:2546-2556` (`s:picker_update_results`)

**Step 1: Replace the function body**

Current body:
```vim
function! s:picker_update_results(items) abort
  let s:picker.items = a:items
  let s:picker.selected = 0

  if empty(a:items)
    call popup_settext(s:picker.results_popup, ['  (no results)'])
    return
  endif

  call s:picker_highlight_selected()
endfunction
```

Replace with:
```vim
function! s:picker_update_results(items) abort
  let s:picker.items = a:items
  let s:picker.selected = 0

  if empty(a:items)
    call popup_settext(s:picker.results_popup, ['  (no results)'])
    let s:picker.preview = 0
    let s:picker.lnum_width = 0
    return
  endif

  if s:picker.mode ==# 'workspace_symbol' || s:picker.mode ==# 'document_symbol'
    let max_line = max(map(copy(a:items), 'get(v:val, "line", 0) + 1'))
    let s:picker.lnum_width = len(string(max_line))
    let s:picker.preview = 1
  else
    let s:picker.lnum_width = 0
    let s:picker.preview = 0
  endif

  call s:picker_highlight_selected()
endfunction
```

**Step 2: Verify no syntax error**

```bash
vim --clean -u vim/autoload/yac.vim -c 'echo "OK"' -c 'qa!'
```
Expected: `OK`, no errors.

**Step 3: Commit**

```bash
git add vim/autoload/yac.vim
git commit -m "feat(picker): compute preview flag and lnum_width for symbol modes"
```

---

### Task 3: Render line numbers in `s:picker_highlight_selected`

**Files:**
- Modify: `vim/autoload/yac.vim:2558-2596` (`s:picker_highlight_selected`)

**Step 1: Replace the flat (non-grouped) rendering branches**

In `s:picker_highlight_selected`, the flat mode branches are the two `else` / `elseif i == s:picker.selected` blocks that do NOT check `s:picker.grouped`. They currently look like:

```vim
    elseif i == s:picker.selected
      if s:picker.grouped
        call add(lines, '>>  ' . get(item, 'label', ''))
      else
        let label = fnamemodify(get(item, 'label', ''), ':.')
        let detail = get(item, 'detail', '')
        call add(lines, !empty(detail) ? ('> ' . label . '  ' . detail) : ('> ' . label))
      endif
    else
      if s:picker.grouped
        call add(lines, '    ' . get(item, 'label', ''))
      else
        let label = fnamemodify(get(item, 'label', ''), ':.')
        let detail = get(item, 'detail', '')
        call add(lines, !empty(detail) ? ('  ' . label . '  ' . detail) : ('  ' . label))
      endif
```

Replace those two `else` (flat) branches so that when `lnum_width > 0`, a line number prefix is prepended:

```vim
    elseif i == s:picker.selected
      if s:picker.grouped
        call add(lines, '>>  ' . get(item, 'label', ''))
      else
        let label = fnamemodify(get(item, 'label', ''), ':.')
        let detail = get(item, 'detail', '')
        let prefix = s:picker.lnum_width > 0
          \ ? printf('> %*d: ', s:picker.lnum_width, get(item, 'line', 0) + 1)
          \ : '> '
        call add(lines, !empty(detail) ? (prefix . label . '  ' . detail) : (prefix . label))
      endif
    else
      if s:picker.grouped
        call add(lines, '    ' . get(item, 'label', ''))
      else
        let label = fnamemodify(get(item, 'label', ''), ':.')
        let detail = get(item, 'detail', '')
        let prefix = s:picker.lnum_width > 0
          \ ? printf('  %*d: ', s:picker.lnum_width, get(item, 'line', 0) + 1)
          \ : '  '
        call add(lines, !empty(detail) ? (prefix . label . '  ' . detail) : (prefix . label))
      endif
```

**Step 2: Verify no syntax error**

```bash
vim --clean -u vim/autoload/yac.vim -c 'echo "OK"' -c 'qa!'
```

**Step 3: Commit**

```bash
git add vim/autoload/yac.vim
git commit -m "feat(picker): show aligned line numbers in symbol modes"
```

---

### Task 4: Trigger preview on navigation

**Files:**
- Modify: `vim/autoload/yac.vim:2598-2616` (`s:picker_select_next`, `s:picker_select_prev`)

**Step 1: Add preview call after flat navigation**

Current `s:picker_select_next`:
```vim
function! s:picker_select_next() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(1)
  else
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call s:picker_highlight_selected()
  endif
endfunction
```

Replace with:
```vim
function! s:picker_select_next() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(1)
  else
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call s:picker_highlight_selected()
    if s:picker.preview
      call s:picker_preview()
    endif
  endif
endfunction
```

Current `s:picker_select_prev`:
```vim
function! s:picker_select_prev() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(-1)
  else
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call s:picker_highlight_selected()
  endif
endfunction
```

Replace with:
```vim
function! s:picker_select_prev() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(-1)
  else
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call s:picker_highlight_selected()
    if s:picker.preview
      call s:picker_preview()
    endif
  endif
endfunction
```

**Step 2: Verify no syntax error**

```bash
vim --clean -u vim/autoload/yac.vim -c 'echo "OK"' -c 'qa!'
```

**Step 3: Commit**

```bash
git add vim/autoload/yac.vim
git commit -m "feat(picker): preview symbol location on navigation"
```

---

### Task 5: Manual smoke test

Open Vim in the project root and verify:

1. **Symbol preview** — type `#` in picker input → results appear → press `j`/`k` → the buffer behind the popups should jump to the symbol's location in real time.

2. **Line numbers** — symbol results should show aligned line numbers: e.g.
   ```
   >   42: functionName  src/main.zig
      137: anotherFunc   src/handlers.zig
   ```
   Numbers right-aligned to the same width across all results.

3. **File mode unchanged** — open picker without prefix → no line numbers, no preview.

4. **References unchanged** — trigger `gr` on a symbol → references picker opens with grouped format, no line number column, preview still works.

5. **Esc closes cleanly** — after previewing a symbol, Esc closes the picker. No cursor restore (symbol mode has no `orig_*` — this is correct, Esc just closes).

**Step 1: Run existing picker tests to catch regressions**

```bash
vim -u tests/vim/run_tests.vim tests/vim/test_picker.vim
```
Expected: all assertions pass.
