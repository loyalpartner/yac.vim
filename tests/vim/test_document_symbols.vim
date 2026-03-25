" ============================================================================
" E2E Test: Tree-Sitter Document Symbols (ts_symbols)
" ============================================================================

call yac_test#begin('document_symbols')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Get tree-sitter symbols
" ============================================================================
call yac_test#log('INFO', 'Test 1: Get tree-sitter symbols')

call yac#ts_symbols()
call yac_test#wait_qflist(5000)

let qflist = getqflist()
call yac_test#log('INFO', 'Symbols found: ' . len(qflist))

call yac_test#assert_true(len(qflist) >= 5, 'Should have at least 5 symbols')

if !empty(qflist)
  for item in qflist
    call yac_test#log('INFO', 'SYMBOL: ' . item.text)
  endfor

  let symbol_texts = join(map(copy(qflist), 'v:val.text'), ' ')
  call yac_test#assert_true(match(symbol_texts, 'User') >= 0,
    \ 'Should contain User symbol')
  call yac_test#assert_true(match(symbol_texts, 'createUserMap') >= 0,
    \ 'Should contain createUserMap symbol')
endif

" ============================================================================
" Cleanup
" ============================================================================
call setqflist([])
call yac_test#teardown()
call yac_test#end()
