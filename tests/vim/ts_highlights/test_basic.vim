" ============================================================================
" E2E Test: Tree-sitter Highlights — Basic + Edit
" ============================================================================

call yac_test#begin('ts_highlights_basic')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Helper functions
" ============================================================================
function! s:get_ts_props(lnum) abort
  return filter(prop_list(a:lnum), {_, p -> get(p, 'type', '') =~# '^yac_ts_'})
endfunction

function! s:get_prop_at(lnum, col) abort
  for p in s:get_ts_props(a:lnum)
    if p.col <= a:col && a:col < p.col + p.length
      return p
    endif
  endfor
  return {}
endfunction

function! s:props_signature(lnum) abort
  return map(s:get_ts_props(a:lnum),
    \ {_, p -> [p.col, p.length, s:normalize_prop_type(p.type)]})
endfunction

function! s:normalize_prop_type(type) abort
  return substitute(a:type, '^yac_ts_\d\+_', 'yac_ts_', '')
endfunction

function! s:reload_and_wait() abort
  execute '%d'
  call setline(1, readfile('test_data/src/main.zig'))
  call cursor(32, 1)
  normal! zz
  call yac#ts_highlights_invalidate()
  call yac_test#wait_for({-> !empty(s:get_ts_props(32))}, 5000)
endfunction

" ============================================================================
" Feature probe
" ============================================================================
call yac#ts_highlights_enable()
let s:hl_available = yac_test#wait_for(
  \ {-> !empty(s:get_ts_props(1))}, 5000)

if !s:hl_available
  call yac_test#skip('ts_highlights', 'Feature not available')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(1, 'Tree-sitter highlights feature is available')

" ============================================================================
" Test 1: Basic highlights on known tokens
" ============================================================================
call yac_test#log('INFO', 'Test 1: Basic highlights on known tokens')
call yac_test#wait_assert(
  \ {-> !empty(s:get_prop_at(1, 1))},
  \ 3000, 'Line 1 col 1 (const) should have a ts prop')

" ============================================================================
" Test 2: Identical lines should have identical highlight signatures
" ============================================================================
call yac_test#log('INFO', 'Test 2: Identical lines should have identical highlight signatures')

call cursor(32, 1)
normal! zz
call yac#ts_highlights_invalidate()
call yac_test#wait_for({-> !empty(s:get_ts_props(32)) && !empty(s:get_ts_props(34))}, 5000)

let s:try32 = s:get_prop_at(32, 5)
let s:try33 = s:get_prop_at(33, 5)
let s:try34 = s:get_prop_at(34, 5)

call yac_test#assert_true(!empty(s:props_signature(32)), 'Line 32 should have ts props')

if !empty(s:try32) && !empty(s:try33)
  call yac_test#assert_eq(s:try32.type, s:try33.type,
    \ '"try" on line 32 and 33 should have same prop type')
endif
if !empty(s:try32) && !empty(s:try34)
  call yac_test#assert_eq(s:try32.type, s:try34.type,
    \ '"try" on line 32 and 34 should have same prop type')
endif

" ============================================================================
" Test 3: After edit + invalidate, highlights match new text
" ============================================================================
call yac_test#log('INFO', 'Test 3: After edit + invalidate, highlights match new text')

call s:reload_and_wait()

call yac_test#wait_for({-> !empty(s:get_ts_props(34))}, 5000)
let s:sig34_before = s:props_signature(34)

call append(31, '    var a: i32 = 0;')
call cursor(33, 1)
normal! zz
call yac#ts_highlights_invalidate()

call yac_test#wait_assert(
  \ {-> !empty(s:get_ts_props(32)) && !empty(s:get_ts_props(35))},
  \ 5000, 'New line 32 ("var a: i32 = 0;") should get ts props after invalidate')

let s:new_var_prop = s:get_prop_at(32, 5)
call yac_test#assert_true(!empty(s:new_var_prop),
  \ 'New line "var" keyword should have a ts prop')

let s:sig35_after = s:props_signature(35)
call yac_test#assert_eq(s:sig35_after, s:sig34_before,
  \ 'Shifted line should keep same highlight signature after invalidate')

" ============================================================================
" Test 4: All similar lines have consistent highlights after edit
" ============================================================================
call yac_test#log('INFO', 'Test 4: All similar lines have consistent highlights after edit')

let s:try33_type = get(s:get_prop_at(33, 5), 'type', '')
let s:try34_type = get(s:get_prop_at(34, 5), 'type', '')
let s:try35_type = get(s:get_prop_at(35, 5), 'type', '')

call yac_test#assert_eq(s:try33_type, s:try34_type,
  \ 'Line 33 and 34 "try" should have same prop type')
call yac_test#assert_eq(s:try33_type, s:try35_type,
  \ 'Line 33 and 35 "try" should have same prop type')

let s:users33_type = get(s:get_prop_at(33, 9), 'type', '')
let s:users34_type = get(s:get_prop_at(34, 9), 'type', '')
let s:users35_type = get(s:get_prop_at(35, 9), 'type', '')

call yac_test#assert_eq(s:users33_type, s:users34_type,
  \ 'Line 33 and 34 "users" should have same prop type')
call yac_test#assert_eq(s:users33_type, s:users35_type,
  \ 'Line 33 and 35 "users" should have same prop type')

call yac#ts_highlights_disable()
call yac_test#teardown()
call yac_test#end()
