" ============================================================================
" Unit Test: Auto-pairs — test the return values of mapping functions
" ============================================================================

call yac_test#begin('autopairs')

" ============================================================================
" Test 1: yac_autopairs#open() returns open+close+Left
" ============================================================================
call yac_test#log('INFO', 'Test 1: open() return value')

call yac_test#assert_eq(
  \ yac_autopairs#open('('), "()\<Left>",
  \ 'open("(") should return "()\\<Left>"')

call yac_test#assert_eq(
  \ yac_autopairs#open('['), "[]\<Left>",
  \ 'open("[") should return "[]\\<Left>"')

call yac_test#assert_eq(
  \ yac_autopairs#open('{'), "{}\<Left>",
  \ 'open("{") should return "{}\\<Left>"')

" ============================================================================
" Test 2: yac_autopairs#close() skips over existing closer
" ============================================================================
call yac_test#log('INFO', 'Test 2: close() skip logic')

" Set up: cursor between ( and )
call setline(1, '()')
call cursor(1, 2)
" In insert mode at col 2, next char is ')'
call yac_test#assert_eq(
  \ yac_autopairs#close(')'), "\<Right>",
  \ 'close(")") should return \\<Right> when next char is )')

" Set up: cursor not before closer
call setline(1, '(x')
call cursor(1, 2)
call yac_test#assert_eq(
  \ yac_autopairs#close(')'), ')',
  \ 'close(")") should return literal ")" when next char is not )')

" ============================================================================
" Test 3: yac_autopairs#quote() returns paired quotes
" ============================================================================
call yac_test#log('INFO', 'Test 3: quote() pairing')

call setline(1, '')
call cursor(1, 1)
call yac_test#assert_eq(
  \ yac_autopairs#quote('"'), "\"\"\<Left>",
  \ 'quote("\"") should return ""\\<Left>')

call yac_test#assert_eq(
  \ yac_autopairs#quote("'"), "''\<Left>",
  \ "quote(\"'\") should return ''\\<Left>")

" ============================================================================
" Test 4: yac_autopairs#quote() skips over existing quote
" ============================================================================
call yac_test#log('INFO', 'Test 4: quote() skip')

call setline(1, '""')
call cursor(1, 2)
call yac_test#assert_eq(
  \ yac_autopairs#quote('"'), "\<Right>",
  \ 'quote("\"") should skip over existing "')

" ============================================================================
" Test 5: yac_autopairs#quote() inside word does not pair
" ============================================================================
call yac_test#log('INFO', 'Test 5: quote() inside word')

call setline(1, "it")
call cursor(1, 3)
" col 3 means after 't', prev char is 't' (a word char)
call yac_test#assert_eq(
  \ yac_autopairs#quote("'"), "'",
  \ "quote(\"'\") after word char should return single quote")

" ============================================================================
" Test 6: yac_autopairs#bs() deletes pair
" ============================================================================
call yac_test#log('INFO', 'Test 6: bs() pair deletion')

call setline(1, '()')
call cursor(1, 2)
" cursor at col 2 (between ( and )), prev='(' next=')'
call yac_test#assert_eq(
  \ yac_autopairs#bs(), "\<BS>\<Del>",
  \ 'bs() between () should return BS+Del')

call setline(1, '""')
call cursor(1, 2)
call yac_test#assert_eq(
  \ yac_autopairs#bs(), "\<BS>\<Del>",
  \ 'bs() between "" should return BS+Del')

" Not between a pair
call setline(1, '(x')
call cursor(1, 2)
call yac_test#assert_eq(
  \ yac_autopairs#bs(), "\<BS>",
  \ 'bs() not between pair should return plain BS')

" ============================================================================
" Test 7: Disabled via g:yac_auto_pairs
" ============================================================================
call yac_test#log('INFO', 'Test 7: disable flag')

let g:yac_auto_pairs = 0
call yac_test#assert_eq(
  \ yac_autopairs#open('('), '(',
  \ 'disabled: open("(") should return literal (')
call yac_test#assert_eq(
  \ yac_autopairs#quote('"'), '"',
  \ 'disabled: quote("\"") should return literal "')
call yac_test#assert_eq(
  \ yac_autopairs#bs(), "\<BS>",
  \ 'disabled: bs() should return plain BS')
let g:yac_auto_pairs = 1

" ============================================================================
" Test 8: setup() creates buffer-local mappings
" ============================================================================
call yac_test#log('INFO', 'Test 8: setup creates mappings')

call yac_autopairs#setup()
call yac_test#assert_true(
  \ !empty(maparg('(', 'i')),
  \ 'setup() should create imap for (')
call yac_test#assert_true(
  \ !empty(maparg(')', 'i')),
  \ 'setup() should create imap for )')
call yac_test#assert_true(
  \ !empty(maparg('"', 'i')),
  \ 'setup() should create imap for "')
call yac_test#assert_true(
  \ !empty(maparg('<BS>', 'i')),
  \ 'setup() should create imap for <BS>')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
