" ============================================================================
" E2E Test: Tree-sitter Highlights — C++ Token Coloring Regression
" ============================================================================
" Verifies that specific C++ tokens get the correct highlight groups,
" preventing regressions like @constant.builtin overriding @function.

call yac_test#begin('ts_highlights_cpp')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/example.h', 8000)

" ============================================================================
" Helper functions (same pattern as test_basic.vim)
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

function! s:normalize_prop_type(type) abort
  return substitute(a:type, '^yac_ts_\d\+_', 'yac_ts_', '')
endfunction

function! s:get_hl_group_at(lnum, col) abort
  let p = s:get_prop_at(a:lnum, a:col)
  if empty(p) | return '' | endif
  let type_info = prop_type_get(p.type)
  return get(type_info, 'highlight', '')
endfunction

" ============================================================================
" Enable ts highlights and wait for them to load
" ============================================================================
call yac#ts_highlights_enable()
let s:hl_available = yac_test#wait_for(
  \ {-> !empty(s:get_ts_props(1))}, 5000)

if !s:hl_available
  call yac_test#skip('ts_highlights_cpp', 'Feature not available')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(s:hl_available, 'Tree-sitter highlights available for C++')

" ============================================================================
" Test 1: #define MAX_USERS — MAX_USERS should be constant, not variable
" Line 4: #define MAX_USERS 100
" ============================================================================
call yac_test#log('INFO', 'Test 1: Macro constant vs variable')

" MAX_USERS starts at col 9
let s:max_users_hl = s:get_hl_group_at(4, 9)
call yac_test#log('INFO', 'MAX_USERS highlight: ' . s:max_users_hl)
" Should NOT be plain YacTsVariable (that would mean @constant.builtin failed)
call yac_test#assert_neq(s:max_users_hl, 'YacTsVariable',
  \ 'MAX_USERS should not be plain variable (should be constant or function.special)')

" ============================================================================
" Test 2: class keyword should be keyword
" Line 22: class User {
" ============================================================================
call yac_test#log('INFO', 'Test 2: class keyword coloring')

let s:class_hl = s:get_hl_group_at(22, 1)
call yac_test#log('INFO', 'class highlight: ' . s:class_hl)
call yac_test#assert_eq(s:class_hl, 'YacTsKeyword',
  \ '"class" keyword should be YacTsKeyword')

" ============================================================================
" Test 3: User type should be type, not constant
" Line 22: class User {
" ============================================================================
call yac_test#log('INFO', 'Test 3: Type identifier coloring')

" "User" starts at col 7
let s:user_hl = s:get_hl_group_at(22, 7)
call yac_test#log('INFO', 'User highlight: ' . s:user_hl)
call yac_test#assert_eq(s:user_hl, 'YacTsType',
  \ '"User" type identifier should be YacTsType')

" ============================================================================
" Test 4: getName should be function, NOT constant.builtin
" Line 25:     std::string getName() const;
" This is the critical regression test — simplePatternMatch returning true
" for unknown patterns caused ALL identifiers to be @constant.builtin.
" ============================================================================
call yac_test#log('INFO', 'Test 4: Method name should be function (regression)')

" "getName" starts at col 17 (after "    std::string ")
let s:getname_hl = s:get_hl_group_at(25, 17)
call yac_test#log('INFO', 'getName highlight: ' . s:getname_hl)
call yac_test#assert_true(
  \ s:getname_hl ==# 'YacTsFunction' || s:getname_hl ==# 'YacTsFunctionMethod',
  \ 'getName should be YacTsFunction or YacTsFunctionMethod, got: ' . s:getname_hl)

" ============================================================================
" Test 5: Namespace identifier
" Line 7: namespace app {
" ============================================================================
call yac_test#log('INFO', 'Test 5: Namespace identifier coloring')

" "namespace" starts at col 1
let s:ns_kw_hl = s:get_hl_group_at(7, 1)
call yac_test#log('INFO', 'namespace keyword highlight: ' . s:ns_kw_hl)
call yac_test#assert_eq(s:ns_kw_hl, 'YacTsKeyword',
  \ '"namespace" keyword should be YacTsKeyword')

" ============================================================================
" Test 6: #include should be preproc
" Line 2: #include <string>
" ============================================================================
call yac_test#log('INFO', 'Test 6: Preprocessor directive coloring')

let s:include_hl = s:get_hl_group_at(2, 1)
call yac_test#log('INFO', '#include highlight: ' . s:include_hl)
call yac_test#assert_eq(s:include_hl, 'YacTsPreproc',
  \ '"#include" should be YacTsPreproc')

" ============================================================================
" Test 7: String literal coloring
" Line 2: #include <string>  — <string> is system_lib_string
" ============================================================================
call yac_test#log('INFO', 'Test 7: String literal coloring')

" "<string>" starts at col 10
let s:str_hl = s:get_hl_group_at(2, 10)
call yac_test#log('INFO', '<string> highlight: ' . s:str_hl)
call yac_test#assert_eq(s:str_hl, 'YacTsString',
  \ '"<string>" system lib string should be YacTsString')

" ============================================================================
" Snapshot: dump all highlight groups for reference
" ============================================================================
let s:snapshot = ['=== C++ Highlights Snapshot ===']
for lnum in range(1, line('$'))
  let props = s:get_ts_props(lnum)
  if empty(props) | continue | endif
  let line_text = getline(lnum)
  for p in props
    let hl = get(prop_type_get(p.type), 'highlight', '?')
    let token = strpart(line_text, p.col - 1, p.length)
    call add(s:snapshot, printf('L%d C%d: %-20s → %s', lnum, p.col, token, hl))
  endfor
endfor
call writefile(s:snapshot, '/tmp/yac_cpp_highlights_snapshot.txt')

" ============================================================================
" Cleanup
" ============================================================================
call yac#ts_highlights_disable()
call yac_test#teardown()
call yac_test#end()
