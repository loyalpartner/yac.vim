" ============================================================================
" E2E Test: Tree-sitter Text Objects (vaf/vif)
" ============================================================================
" Verifies that tree-sitter text objects select the correct ranges:
"   vaf (function.outer) — entire function including signature
"   vif (function.inner) — function body only (between { and })
"
" The daemon's ts_textobjects method is synchronous (ch_evalexpr), so
" we call yac#ts_select() directly and inspect the visual selection marks.

call yac_test#begin('ts_textobjects')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for LSP + tree-sitter parse
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" Give tree-sitter time to parse after LSP handshake.
" The daemon parses the file on first file_open / did_change.
sleep 1000m

" Helper: call ts_select, exit visual mode, return [start_line, end_line].
" Returns [0, 0] if no selection was made (response had start_line < 0).
function! s:select_and_get_range(target) abort
  " Reset visual marks to known state
  call setpos("'<", [0, 0, 0, 0])
  call setpos("'>", [0, 0, 0, 0])

  " Call text object selection (synchronous — daemon returns immediately)
  call yac#ts_select(a:target)

  " If selection was made, we're in visual mode — exit to set marks
  if mode() ==# 'v' || mode() ==# 'V' || mode() ==# "\<C-v>"
    execute "normal! \<Esc>"
  endif

  let start = getpos("'<")[1]
  let end = getpos("'>")[1]
  return [start, end]
endfunction

" ============================================================================
" Test 1: vaf on function signature line — select entire function
" ============================================================================
function! s:test_vaf_on_signature() abort
  " processUser function: pub fn processUser(...) ... { ... }
  " Signature at line 44, closing brace at line 47
  call cursor(44, 5)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.outer')
  call yac_test#log('INFO', printf('vaf on signature: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vaf should produce a selection')
  call yac_test#assert_eq(start, 44, 'vaf start should be line 44 (pub fn processUser)')
  call yac_test#assert_eq(end, 47, 'vaf end should be line 47 (closing brace)')
endfunction
call yac_test#run_case('vaf on function signature line', {-> s:test_vaf_on_signature()})

" ============================================================================
" Test 2: vaf inside function body — select entire function (incl. signature)
" ============================================================================
function! s:test_vaf_inside_body() abort
  " main function: line 49 (pub fn main) to line 57 (closing brace)
  " Place cursor inside the body at line 51
  call cursor(51, 5)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.outer')
  call yac_test#log('INFO', printf('vaf inside body: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vaf should produce a selection')
  call yac_test#assert_eq(start, 49, 'vaf start should be line 49 (pub fn main)')
  call yac_test#assert_eq(end, 57, 'vaf end should be line 57 (closing brace)')
endfunction
call yac_test#run_case('vaf inside function body', {-> s:test_vaf_inside_body()})

" ============================================================================
" Test 3: vif inside function body — select body only (between { and })
" ============================================================================
function! s:test_vif_inside_body() abort
  " processUser function body:
  "   line 44: pub fn processUser(user: User) []const u8 {
  "   line 45:     const result = user.getName();
  "   line 46:     return result;
  "   line 47: }
  " Inner should select the body lines (45-46), excluding { and }
  call cursor(45, 5)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.inner')
  call yac_test#log('INFO', printf('vif inside body: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vif should produce a selection')
  " Inner excludes the brace lines: body starts after { line, ends before } line
  call yac_test#assert_true(start >= 45, 'vif start should be >= 45 (first body line)')
  call yac_test#assert_true(end <= 46, 'vif end should be <= 46 (last body line)')
  call yac_test#assert_true(start > 44, 'vif start should exclude signature line 44')
  call yac_test#assert_true(end < 47, 'vif end should exclude closing brace line 47')
endfunction
call yac_test#run_case('vif inside function body', {-> s:test_vif_inside_body()})

" ============================================================================
" Test 4: vaf on struct method — select method (not entire struct)
" ============================================================================
function! s:test_vaf_struct_method() abort
  " User.init method: line 14 (pub fn init) to line 16 (closing brace)
  call cursor(15, 10)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.outer')
  call yac_test#log('INFO', printf('vaf struct method: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vaf should produce a selection')
  call yac_test#assert_eq(start, 14, 'vaf start should be line 14 (pub fn init)')
  call yac_test#assert_eq(end, 16, 'vaf end should be line 16 (closing brace)')
endfunction
call yac_test#run_case('vaf on struct method (User.init)', {-> s:test_vaf_struct_method()})

" ============================================================================
" Test 5: vaf on non-function line (file header) — no selection
" ============================================================================
function! s:test_vaf_no_function() abort
  " Line 1: const std = @import("std");  — not inside any function
  call cursor(1, 1)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  " Reset marks
  call setpos("'<", [0, 0, 0, 0])
  call setpos("'>", [0, 0, 0, 0])

  call yac#ts_select('function.outer')

  " Should NOT enter visual mode (daemon returns start_line: -1)
  let in_visual = mode() ==# 'v' || mode() ==# 'V' || mode() ==# "\<C-v>"
  if in_visual
    execute "normal! \<Esc>"
  endif

  let start = getpos("'<")[1]
  call yac_test#log('INFO', printf('vaf on non-function: start mark = %d', start))

  " Mark should be 0 (not set) since no selection was made
  call yac_test#assert_eq(start, 0, 'vaf on non-function line should not set selection marks')
endfunction
call yac_test#run_case('vaf on non-function line (no selection)', {-> s:test_vaf_no_function()})

" ============================================================================
" Test 6: vaf on another top-level function (createUserMap)
" ============================================================================
function! s:test_vaf_create_user_map() abort
  " createUserMap: line 30 (pub fn createUserMap) to line 36 (closing brace)
  call cursor(33, 5)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.outer')
  call yac_test#log('INFO', printf('vaf createUserMap: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vaf should produce a selection')
  call yac_test#assert_eq(start, 30, 'vaf start should be line 30 (pub fn createUserMap)')
  call yac_test#assert_eq(end, 36, 'vaf end should be line 36 (closing brace)')
endfunction
call yac_test#run_case('vaf on createUserMap', {-> s:test_vaf_create_user_map()})

" ============================================================================
" Test 7: vif on multi-line function (main) — body selection
" ============================================================================
function! s:test_vif_main() abort
  " main function:
  "   line 49: pub fn main() !void {
  "   line 50:     const allocator = ...
  "   ...
  "   line 56:     }
  "   line 57: }
  " Inner should select lines 50-56 (body, excluding brace lines)
  call cursor(53, 5)
  call yac_test#log('INFO', 'cursor at line ' . line('.') . ', word: ' . expand('<cword>'))

  let [start, end] = s:select_and_get_range('function.inner')
  call yac_test#log('INFO', printf('vif main: [%d, %d]', start, end))

  call yac_test#assert_true(start > 0, 'vif should produce a selection')
  call yac_test#assert_true(start > 49, 'vif start should be after signature line 49')
  call yac_test#assert_true(end < 57, 'vif end should be before closing brace line 57')
  " Body should span multiple lines
  call yac_test#assert_true(end - start >= 2,
    \ printf('vif should span at least 3 body lines, got %d', end - start + 1))
endfunction
call yac_test#run_case('vif on main function body', {-> s:test_vif_main()})

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
