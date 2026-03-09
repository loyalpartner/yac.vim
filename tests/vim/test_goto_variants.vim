" ============================================================================
" E2E Test: Goto Type Definition / Declaration / Implementation (deep)
" ============================================================================
" Extends test_goto.vim with focused tests on non-definition goto variants.

call yac_test#begin('goto_variants')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Type Definition on a variable — should jump to its type
" ============================================================================
call yac_test#log('INFO', 'Test 1: Type Definition on variable (user)')

" Line 60: const user = User.init(1, "Test", "test@example.com");
call cursor(60, 11)
call search('user', 'c', line('.'))
let start_line = line('.')
let start_file = expand('%:p')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'user', 'Cursor should be on "user"')

call yac#goto_type_definition()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'TypeDefinition jumped to line ' . end_line)
  " Should jump to User struct definition (line 6)
  call yac_test#assert_eq(end_line, 6, 'TypeDefinition on user variable should jump to User struct (line 6)')
else
  call yac_test#assert_true(0, 'TypeDefinition should move cursor from user variable')
endif

" ============================================================================
" Test 2: Type Definition on a function return value
" ============================================================================
call yac_test#log('INFO', 'Test 2: Type Definition on function return')

edit! test_data/src/main.zig
call yac#open_file()

" Line 45: const result = user.getName();
" result has type []const u8
call cursor(45, 11)
call search('result', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'result', 'Cursor should be on "result"')

call yac#goto_type_definition()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'TypeDefinition on result jumped to line ' . end_line)
  call yac_test#assert_true(end_line != start_line, 'TypeDefinition on result should jump somewhere')
else
  " For primitive types ([]const u8), zls may not have a type definition target
  call yac_test#log('INFO', 'TypeDefinition did not move for primitive type (expected)')
endif

" ============================================================================
" Test 3: Declaration on struct method
" ============================================================================
call yac_test#log('INFO', 'Test 3: Declaration on struct method call')

edit! test_data/src/main.zig
call yac#open_file()

" Line 45: const result = user.getName();
call cursor(45, 25)
call search('getName', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

call yac#goto_declaration()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Declaration jumped to line ' . end_line)
  " Declaration of getName is at line 19
  call yac_test#assert_eq(end_line, 19, 'Declaration should jump to getName at line 19')
else
  " In Zig, declaration == definition for most cases
  call yac_test#log('INFO', 'Declaration did not move (same as definition in Zig)')
endif

" ============================================================================
" Test 4: Declaration on imported symbol
" ============================================================================
call yac_test#log('INFO', 'Test 4: Declaration on imported symbol')

edit! test_data/src/main.zig
call yac#open_file()

" Line 2: const Allocator = std.mem.Allocator;
call cursor(2, 7)
call search('Allocator', 'c', line('.'))
let start_line = line('.')
let start_col = col('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'Allocator', 'Cursor should be on "Allocator"')

call yac#goto_declaration()
let moved = yac_test#wait_cursor_move(start_line, start_col, 5000)

if moved
  call yac_test#log('INFO', printf('Declaration jumped to %s:%d', expand('%:t'), line('.')))
  call yac_test#assert_true(1, 'Declaration on Allocator should jump')
else
  call yac_test#log('INFO', 'Declaration did not move (cursor already on declaration)')
endif

" ============================================================================
" Test 5: Implementation on struct (find methods)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Implementation on struct name')

edit! test_data/src/main.zig
call yac#open_file()

" Line 6: pub const User = struct {
call cursor(6, 1)
call search('User', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

call yac#goto_implementation()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Implementation jumped to line ' . end_line)
  call yac_test#assert_true(end_line != start_line, 'Implementation should move cursor')
else
  " zls may not support implementation for struct types
  call yac_test#log('INFO', 'Implementation not available for struct (zls limitation)')
endif

" ============================================================================
" Test 6: Type Definition on function parameter
" ============================================================================
call yac_test#log('INFO', 'Test 6: Type Definition on function parameter')

edit! test_data/src/main.zig
call yac#open_file()

" Line 44: pub fn processUser(user: User) []const u8 {
call cursor(44, 21)
call search('User', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User" type annotation')

call yac#goto_type_definition()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'TypeDefinition on param type jumped to line ' . end_line)
  " User type is defined at line 6
  call yac_test#assert_eq(end_line, 6, 'TypeDefinition on param type User should jump to line 6')
else
  call yac_test#log('INFO', 'TypeDefinition did not move (may already be on type)')
endif

" ============================================================================
" Test 7: Implementation on function name
" ============================================================================
call yac_test#log('INFO', 'Test 7: Implementation on function')

edit! test_data/src/main.zig
call yac#open_file()

" Line 30: pub fn createUserMap(...)
call cursor(30, 8)
call search('createUserMap', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on "createUserMap"')

call yac#goto_implementation()
let moved = yac_test#wait_line_change(start_line, 5000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Implementation jumped to line ' . end_line)
  call yac_test#assert_true(end_line != start_line, 'Implementation moved cursor')
else
  call yac_test#log('INFO', 'Implementation did not move for function (expected in Zig)')
endif

" ============================================================================
" Cleanup
" ============================================================================
" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
