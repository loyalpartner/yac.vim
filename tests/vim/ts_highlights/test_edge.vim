" ============================================================================
" E2E Test: Tree-sitter Highlights — Error line, deletion, scroll-up
" ============================================================================

call yac_test#begin('ts_highlights_edge')
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
  call yac_test#skip('ts_highlights_edge', 'Feature not available')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

" ============================================================================
" Test 5: Syntax error line should not break surrounding highlights
" ============================================================================
call yac_test#log('INFO', 'Test 5: Syntax error line should not break surrounding highlights')

call s:reload_and_wait()

let s:try32_before = get(s:get_prop_at(32, 5), 'type', '')

call append(31, '    users')
call cursor(33, 1)
normal! zz
call yac#ts_highlights_invalidate()
call yac_test#wait_for({-> !empty(s:get_ts_props(33)) && !empty(s:get_ts_props(35))}, 5000)

let s:try33_err = get(s:get_prop_at(33, 5), 'type', '')
let s:try34_err = get(s:get_prop_at(34, 5), 'type', '')
let s:try35_err = get(s:get_prop_at(35, 5), 'type', '')

call yac_test#assert_eq(s:try33_err, s:try34_err,
  \ 'With syntax error above, "try" on line 33 and 34 should match')
call yac_test#assert_eq(s:try33_err, s:try35_err,
  \ 'With syntax error above, "try" on line 33 and 35 should match')

let s:users33_err = get(s:get_prop_at(33, 9), 'type', '')
let s:users34_err = get(s:get_prop_at(34, 9), 'type', '')
let s:users35_err = get(s:get_prop_at(35, 9), 'type', '')

call yac_test#assert_eq(s:users33_err, s:users34_err,
  \ 'With syntax error above, "users" on line 33 and 34 should match')
call yac_test#assert_eq(s:users33_err, s:users35_err,
  \ 'With syntax error above, "users" on line 33 and 35 should match')

call yac_test#assert_true(!empty(s:try33_err),
  \ '"try" should still have highlights despite syntax error above')

" ============================================================================
" Test 6: After line deletion + invalidate, highlights correct
" ============================================================================
call yac_test#log('INFO', 'Test 6: After line deletion + invalidate, highlights correct')

call s:reload_and_wait()

call yac_test#wait_for({-> !empty(s:get_ts_props(34))}, 5000)
let s:sig34_orig = s:props_signature(34)

execute '32d'
call cursor(33, 1)
normal! zz
call yac#ts_highlights_invalidate()
call yac_test#wait_for({-> !empty(s:get_ts_props(32)) && !empty(s:get_ts_props(33))}, 5000)

let s:sig33_after_del = s:props_signature(33)
call yac_test#assert_eq(s:sig33_after_del, s:sig34_orig,
  \ 'After deleting line above, shifted line should keep same highlight signature')

" ============================================================================
" Test 7: scroll-up branch min() regression (E118)
" ============================================================================
call yac_test#log('INFO', 'Test 7: scroll-up branch min() regression (E118)')

call s:reload_and_wait()

call cursor(1, 1)
normal! zt

call yac#ts_highlights_disable()

let b:yac_ts_highlights_enabled = 1
let b:yac_ts_hl_lo = 20
let b:yac_ts_hl_hi = line('$')

call yac#ts_highlights_request('scroll')

call yac_test#wait_assert(
  \ {-> !empty(s:get_ts_props(1))},
  \ 3000, 'scroll-up: line 1 should get ts props after scroll-up request (E118 regression)')

call yac#ts_highlights_disable()
call yac_test#teardown()
call yac_test#end()
