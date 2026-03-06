" ============================================================================
" E2E Test: Tree-Sitter Symbols for C++ (.h) Files
" ============================================================================

call yac_test#begin('ts_symbols_cpp')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/example.h', 8000)

" ============================================================================
" Test 1: Extract symbols — snapshot all names and kinds
" ============================================================================
call yac_test#log('INFO', 'Test 1: Extract symbols from C++ header')

YacTsSymbols
call yac_test#wait_qflist(5000)

let qflist = getqflist()
call yac_test#log('INFO', 'Total symbols: ' . len(qflist))

" Log every symbol for snapshot
for item in qflist
  call yac_test#log('INFO', 'SYMBOL: ' . item.text)
endfor

" Dump symbols to snapshot file for debugging
let snapshot_lines = ['=== C++ Symbol Snapshot ===']
let snapshot_lines += ['Total: ' . len(qflist)]
for item in qflist
  call add(snapshot_lines, item.text)
endfor
call writefile(snapshot_lines, '/tmp/yac_cpp_symbols_snapshot.txt')

" ============================================================================
" Test 2: Expected symbols present
" ============================================================================
call yac_test#log('INFO', 'Test 2: Verify expected symbols')

let symbol_texts = join(map(copy(qflist), 'v:val.text'), "\n")

" Namespace
call yac_test#assert_true(match(symbol_texts, 'app') >= 0,
      \ 'Should contain namespace app')

" Class
call yac_test#assert_true(match(symbol_texts, 'User') >= 0,
      \ 'Should contain class User')
call yac_test#assert_true(match(symbol_texts, 'Container') >= 0,
      \ 'Should contain class Container')

" Struct
call yac_test#assert_true(match(symbol_texts, 'Point') >= 0,
      \ 'Should contain struct Point')

" Enum
call yac_test#assert_true(match(symbol_texts, 'Color') >= 0,
      \ 'Should contain enum Color')

" Typedef
call yac_test#assert_true(match(symbol_texts, 'UserId') >= 0,
      \ 'Should contain typedef UserId')

" Methods
call yac_test#assert_true(match(symbol_texts, 'getName') >= 0,
      \ 'Should contain method getName')
call yac_test#assert_true(match(symbol_texts, 'getId') >= 0,
      \ 'Should contain method getId')
call yac_test#assert_true(match(symbol_texts, 'add') >= 0,
      \ 'Should contain method add')
call yac_test#assert_true(match(symbol_texts, 'get') >= 0,
      \ 'Should contain method get')

" Fields
call yac_test#assert_true(match(symbol_texts, 'm_id') >= 0,
      \ 'Should contain field m_id')
call yac_test#assert_true(match(symbol_texts, 'm_name') >= 0,
      \ 'Should contain field m_name')
call yac_test#assert_true(match(symbol_texts, 'm_data') >= 0,
      \ 'Should contain pointer field m_data')

" Macros
call yac_test#assert_true(match(symbol_texts, 'MAX_USERS') >= 0,
      \ 'Should contain macro MAX_USERS')
call yac_test#assert_true(match(symbol_texts, 'MAKE_ID') >= 0,
      \ 'Should contain macro MAKE_ID')

" Constructor
call yac_test#assert_true(match(symbol_texts, 'User.*Method') >= 0,
      \ 'Should contain constructor User')

" Forward declaration
call yac_test#assert_true(match(symbol_texts, 'processUser') >= 0,
      \ 'Should contain forward-declared processUser')

" ============================================================================
" Test 3: No duplicates and correct count
" ============================================================================
call yac_test#log('INFO', 'Test 3: No duplicates and correct count')

let total = len(qflist)
call yac_test#assert_eq(total, 20, 'Should have exactly 20 symbols')

" Verify no duplicate Container (template dedup)
let container_count = 0
for item in qflist
  if match(item.text, '^Container') >= 0
    let container_count += 1
  endif
endfor
call yac_test#assert_eq(container_count, 1, 'Container should appear exactly once (template dedup)')

" ============================================================================
" Cleanup
" ============================================================================
call setqflist([])
call yac_test#teardown()
call yac_test#end()
