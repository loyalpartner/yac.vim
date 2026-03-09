" ============================================================================
" E2E Test: Picker — file search via Ctrl+P
" ============================================================================

call yac_test#begin('picker')
call yac_test#setup()

" Wait for daemon connection
sleep 1000m

" ============================================================================
" Unit tests: file display label (no daemon needed)
" ============================================================================
call yac_test#log('INFO', 'Unit: picker_file_label')

" Root file: no directory part
call yac_test#assert_eq(
  \ yac#picker_file_label('build.zig'),
  \ 'build.zig',
  \ 'file_label: root file has no dir suffix')

" Single-level dir
call yac_test#assert_eq(
  \ yac#picker_file_label('src/main.zig'),
  \ 'main.zig  src/',
  \ 'file_label: single-level dir')

" Multi-level dir
call yac_test#assert_eq(
  \ yac#picker_file_label('src/handlers/picker.zig'),
  \ 'picker.zig  src/handlers/',
  \ 'file_label: multi-level dir')

" Hidden dir (github workflows)
call yac_test#assert_eq(
  \ yac#picker_file_label('.github/workflows/ci.yml'),
  \ 'ci.yml  .github/workflows/',
  \ 'file_label: hidden dir')

" ============================================================================
" Unit tests: file highlight column positions (no daemon needed)
" ============================================================================
call yac_test#log('INFO', 'Unit: picker_file_match_cols')

" Root file: display '  build.zig', pfx=2
" build.zig: b(0)u(1)i(2)l(3)d(4) → 'b'→col3, 'l'→col6, 'd'→col7
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('build.zig', 'bld', 2),
  \ [3, 6, 7],
  \ 'match_cols: root file query in fname')

" Single-level dir: display '  main.zig  src/', pfx=2
" fname='main.zig'(8), dir='src'(3)
" 's'→2+8+0+3=13, 'r'→14, 'c'→15, '/'(==dir_len)→16
" 'm'→2+4-3=3, 'a'→4, 'i'→5, 'n'→6
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('src/main.zig', 'src/main', 2),
  \ [13, 14, 15, 16, 3, 4, 5, 6],
  \ 'match_cols: query spans both dir and fname')

" Multi-level dir: display '  picker.zig  src/handlers/', pfx=2
" fname='picker.zig'(10), dir='src/handlers'(12)
" 'p'(at rel[13])→2+13-12=3, 'i'(14)→4, 'c'(15)→5, 'k'(16)→6
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('src/handlers/picker.zig', 'pick', 2),
  \ [3, 4, 5, 6],
  \ 'match_cols: multi-level dir, fname-only query')

" 'h' in 'handlers' → dir side; 'z' in 'picker.zig' → fname side
" 'h'(at rel[4])→2+10+4+3=19, 'z'(at rel[20] in 'picker.zig')→2+20-12=10
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('src/handlers/picker.zig', 'hz', 2),
  \ [19, 10],
  \ 'match_cols: h in dir, z in fname')

" No match: query chars absent from path ('src/build.rs' has no q/x/w)
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('src/build.rs', 'qxw', 2),
  \ [],
  \ 'match_cols: no match returns empty list')

" Case-insensitive matching
call yac_test#assert_eq(
  \ yac#picker_file_match_cols('src/Main.zig', 'MAIN', 2),
  \ [3, 4, 5, 6],
  \ 'match_cols: case-insensitive')

" ============================================================================
" Test 1: picker function exists
" ============================================================================
call yac_test#log('INFO', 'Test 1: picker function exists')
call yac_test#assert_true(exists('*yac#picker_open'), 'yac#picker_open function should exist')

" ============================================================================
" Test 2: Picker open creates popups
" ============================================================================
call yac_test#log('INFO', 'Test 2: Picker open creates popups')

" Open the picker
call yac#picker_open()

" Wait for picker to appear (precise check, ignores toast popups)
let picker_opened = yac_test#wait_picker(3000)
call yac_test#assert_true(picker_opened, 'Picker popups should appear')

" Check that we have at least one popup
let popups = popup_list()
call yac_test#assert_true(len(popups) >= 2, 'Should have at least 2 popups (input + results)')

" ============================================================================
" Test 3: Picker close via Esc
" ============================================================================
call yac_test#log('INFO', 'Test 3: Picker close via Esc')

" Close the picker
call feedkeys("\<Esc>", 'xt')

" Wait for picker to close (precise check)
let picker_closed = yac_test#wait_picker_closed(2000)
call yac_test#assert_true(picker_closed, 'All popups should be closed after Esc')

" ============================================================================
" Test 4: Picker toggle (open then open again closes)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Picker toggle')

call yac#picker_open()
let picker_opened = yac_test#wait_picker(3000)
call yac_test#assert_true(picker_opened, 'Picker should open')

" Call again to toggle off
call yac#picker_open()
let picker_closed = yac_test#wait_picker_closed(2000)
call yac_test#assert_true(picker_closed, 'Picker should toggle off')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
