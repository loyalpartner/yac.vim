" ============================================================================
" E2E Test: Tree-sitter Navigation (]f / [f)
" ============================================================================
" Verifies that ]f (next function) and [f (prev function) navigate correctly
" using tree-sitter ts_navigate RPC.

call yac_test#begin('ts_navigation')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for tree-sitter to be ready
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 3000)

" main.zig function layout (1-based lines):
"   14: pub fn init(...)         (User method)
"   19: pub fn getName(...)      (User method)
"   24: pub fn getEmail(...)     (User method)
"   30: pub fn createUserMap(...)
"   39: pub fn getUserById(...)
"   44: pub fn processUser(...)
"   49: pub fn main(...)
"   59: test "user creation"     (tree-sitter treats test decls as functions)
"   65: test "create user map"
"   72: test "process user"

" ============================================================================
" Test 1: ]f from file top -> jump to first function (User.init)
" ============================================================================
function! s:test_next_from_top() abort
  call cursor(1, 1)
  let start_line = line('.')

  call yac#ts_next_function()
  let moved = yac_test#wait_line_change(start_line, 5000)

  call yac_test#assert_true(moved, ']f from line 1 should move cursor')
  if moved
    call yac_test#assert_eq(line('.'), 14,
      \ ']f from top should jump to first function (User.init at line 14)')
  endif
endfunction
call yac_test#run_case(']f from file top to first function', {-> s:test_next_from_top()})

" ============================================================================
" Test 2: ]f from User.init -> jump to User.getName
" ============================================================================
function! s:test_next_from_init() abort
  call cursor(14, 1)
  let start_line = line('.')

  call yac#ts_next_function()
  let moved = yac_test#wait_line_change(start_line, 5000)

  call yac_test#assert_true(moved, ']f from User.init should move cursor')
  if moved
    call yac_test#assert_eq(line('.'), 19,
      \ ']f from User.init should jump to User.getName at line 19')
  endif
endfunction
call yac_test#run_case(']f from User.init to User.getName', {-> s:test_next_from_init()})

" ============================================================================
" Test 3: [f from User.getName -> jump back to User.init
" ============================================================================
function! s:test_prev_from_getname() abort
  call cursor(19, 1)
  let start_line = line('.')

  call yac#ts_prev_function()
  let moved = yac_test#wait_line_change(start_line, 5000)

  call yac_test#assert_true(moved, '[f from User.getName should move cursor')
  if moved
    call yac_test#assert_eq(line('.'), 14,
      \ '[f from User.getName should jump back to User.init at line 14')
  endif
endfunction
call yac_test#run_case('[f from User.getName to User.init', {-> s:test_prev_from_getname()})

" ============================================================================
" Test 4: [f from line 1 -> should not move (no previous function)
" ============================================================================
function! s:test_prev_from_top() abort
  call cursor(1, 1)
  let start_line = line('.')

  call yac#ts_prev_function()

  " Give daemon time to respond (even if no movement expected)
  sleep 200m
  redraw

  call yac_test#assert_eq(line('.'), start_line,
    \ '[f from line 1 should not move (no previous function)')
endfunction
call yac_test#run_case('[f from file top stays put', {-> s:test_prev_from_top()})

" ============================================================================
" Test 5: ]f from last function -> should not move (no next function)
" ============================================================================
" tree-sitter treats Zig test declarations as function nodes, so the
" last "function" is actually test "process user" at line 72.
function! s:test_next_from_last() abort
  call cursor(72, 1)
  let start_line = line('.')

  call yac#ts_next_function()

  " Give daemon time to respond (even if no movement expected)
  sleep 200m
  redraw

  call yac_test#assert_eq(line('.'), start_line,
    \ ']f from last function (test "process user") should not move')
endfunction
call yac_test#run_case(']f from last function stays put', {-> s:test_next_from_last()})

" ============================================================================
" Test 6: multiple ]f -> traverse all functions in order
" ============================================================================
function! s:test_traverse_all() abort
  " Expected function definition lines in order
  " (includes test declarations — tree-sitter treats them as function nodes)
  let expected = [14, 19, 24, 30, 39, 44, 49, 59, 65, 72]

  call cursor(1, 1)
  let visited = []

  for i in range(len(expected))
    let prev_line = line('.')
    call yac#ts_next_function()
    let moved = yac_test#wait_line_change(prev_line, 5000)
    if !moved
      call yac_test#log('INFO', printf('Stopped traversal at step %d, line %d', i, line('.')))
      break
    endif
    call add(visited, line('.'))
  endfor

  call yac_test#assert_eq(len(visited), len(expected),
    \ printf('Should visit %d functions, visited %d', len(expected), len(visited)))

  " Verify each visited line matches expected
  for i in range(min([len(visited), len(expected)]))
    call yac_test#assert_eq(visited[i], expected[i],
      \ printf(']f step %d: expected line %d, got %d', i + 1, expected[i], visited[i]))
  endfor
endfunction
call yac_test#run_case(']f traverse all functions in order', {-> s:test_traverse_all()})

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
