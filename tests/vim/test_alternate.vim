" test_alternate.vim — C/C++ header/implementation switching
call yac_test#begin('alternate')
call yac_test#setup()

let s:dir = getcwd() . '/test_data'

" Create test file pairs
call writefile(['// foo.h'], s:dir . '/foo.h')
call writefile(['// foo.c'], s:dir . '/foo.c')
call writefile(['// bar.hpp'], s:dir . '/bar.hpp')
call writefile(['// bar.cpp'], s:dir . '/bar.cpp')
call writefile(['// baz.h — no .c exists'], s:dir . '/baz.h')
call writefile(['// baz.cpp'], s:dir . '/baz.cpp')
call writefile(['// qux.h — no impl exists'], s:dir . '/qux.h')

" Test 1: .c → .h
execute 'edit ' . s:dir . '/foo.c'
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'foo.h', '.c should switch to .h')

" Test 2: .h → .c
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'foo.c', '.h should switch back to .c')

" Test 3: .cpp → .hpp
execute 'edit ' . s:dir . '/bar.cpp'
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'bar.hpp', '.cpp should switch to .hpp')

" Test 4: .hpp → .cpp
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'bar.cpp', '.hpp should switch back to .cpp')

" Test 5: .h → .cpp when no .c exists
execute 'edit ' . s:dir . '/baz.h'
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'baz.cpp', '.h should find .cpp when no .c')

" Test 6: no alternate found — should not crash, stays on same file
execute 'edit ' . s:dir . '/qux.h'
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:t'), 'qux.h', 'no alternate: should stay on same file')

" Test 7: non-C file — should not crash
execute 'edit ' . s:dir . '/src/main.zig'
call yac_alternate#switch()
call yac_test#assert_eq(expand('%:e'), 'zig', 'non-C file: should stay on same file')

call yac_test#teardown()
call yac_test#end()
