" ============================================================================
" Unit Test: Picker — pure VimScript tests, no daemon needed
" ============================================================================

call yac_test#begin('picker_unit')

" ============================================================================
" Test 1: Registry completeness — all expected modes are registered
" ============================================================================
call yac_test#log('INFO', 'Test 1: Registry completeness')

let s:modes = yac_picker#get_modes()
let s:expected_prefixes = ['', '>', '#', '@', '%', '!', '/', '?', ':']

for s:pfx in s:expected_prefixes
  call yac_test#assert_true(
    \ has_key(s:modes, s:pfx),
    \ 'mode registry should have prefix "' . (s:pfx ==# '' ? '<empty>' : s:pfx) . '"')
endfor

call yac_test#assert_eq(
  \ len(s:modes), len(s:expected_prefixes),
  \ 'mode count should match expected (' . len(s:expected_prefixes) . ')')

" ============================================================================
" Test 2: has_prefix — registered vs unregistered prefixes
" ============================================================================
call yac_test#log('INFO', 'Test 2: has_prefix')

" Registered prefixes should return true
for s:pfx in ['>', '@', '#', '%', '!', '/', '?', ':']
  call yac_test#assert_true(
    \ yac_picker#has_prefix(s:pfx . 'query'),
    \ 'has_prefix("' . s:pfx . 'query") should be true')
endfor

" Non-prefixes should return false
for s:ch in ['a', 'z', ' ']
  call yac_test#assert_true(
    \ !yac_picker#has_prefix(s:ch . 'query'),
    \ 'has_prefix("' . s:ch . 'query") should be false')
endfor

" Empty string should return false
call yac_test#assert_true(
  \ !yac_picker#has_prefix(''),
  \ 'has_prefix("") should be false')

" ============================================================================
" Test 3: file_label — display formatting
" ============================================================================
call yac_test#log('INFO', 'Test 3: file_label')

call yac_test#assert_eq(
  \ yac_picker#file_label('build.zig'),
  \ 'build.zig',
  \ 'file_label: root file, no dir suffix')

call yac_test#assert_eq(
  \ yac_picker#file_label('src/main.zig'),
  \ 'main.zig  src/',
  \ 'file_label: single-level dir')

call yac_test#assert_eq(
  \ yac_picker#file_label('src/handlers/picker.zig'),
  \ 'picker.zig  src/handlers/',
  \ 'file_label: multi-level dir')

" ============================================================================
" Test 4: file_match_cols — highlight positions
" ============================================================================
call yac_test#log('INFO', 'Test 4: file_match_cols')

" Root file: 'bld' in 'build.zig', pfx=2
call yac_test#assert_eq(
  \ yac_picker#file_match_cols('build.zig', 'bld', 2),
  \ [3, 6, 7],
  \ 'match_cols: root file query in fname')

" No match returns empty list
call yac_test#assert_eq(
  \ yac_picker#file_match_cols('src/build.rs', 'qxw', 2),
  \ [],
  \ 'match_cols: no match returns empty list')

" Case-insensitive matching
call yac_test#assert_eq(
  \ yac_picker#file_match_cols('src/Main.zig', 'MAIN', 2),
  \ [3, 4, 5, 6],
  \ 'match_cols: case-insensitive')

" ============================================================================
" Test 5: MRU injection — mode registry has '!' key after set
" ============================================================================
call yac_test#log('INFO', 'Test 5: MRU injection')

call yac_picker#test_set_mru(['a.zig', 'b.zig'])

let s:modes_after = yac_picker#get_modes()
call yac_test#assert_true(
  \ has_key(s:modes_after, '!'),
  \ 'mode registry should have "!" (MRU) key after test_set_mru')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
