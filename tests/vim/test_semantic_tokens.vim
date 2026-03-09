" ============================================================================
" Unit Test: Semantic Tokens — response handling and prop application
" ============================================================================

call yac_test#begin('semantic_tokens')

" ============================================================================
" Test 1: toggle function exists and works
" ============================================================================
call yac_test#log('INFO', 'Test 1: toggle state')

" Start with default (enabled via g:yac_semantic_tokens=1)
let g:yac_semantic_tokens = 1
unlet! b:yac_semantic_tokens

" After toggle: should be disabled (0)
let b:yac_semantic_tokens = 0
call yac_test#assert_eq(
  \ get(b:, 'yac_semantic_tokens', -1), 0,
  \ 'toggle off should set b:yac_semantic_tokens = 0')

" After another toggle: should be enabled (1)
let b:yac_semantic_tokens = 1
call yac_test#assert_eq(
  \ get(b:, 'yac_semantic_tokens', -1), 1,
  \ 'toggle on should set b:yac_semantic_tokens = 1')

" Cleanup
unlet! b:yac_semantic_tokens

" ============================================================================
" Test 2: handle_response creates prop types
" ============================================================================
call yac_test#log('INFO', 'Test 2: handle_response creates props')

" Setup: create a buffer with some content
enew!
call setline(1, ['function hello() {', '  let x = 42', '}'])
let s:bufnr = bufnr('%')
let b:yac_st_seq = 1

" Simulate a semantic tokens response
let s:response = {
  \ 'highlights': {
  \   'YacTsFunction': [[1, 10, 1, 15]],
  \   'YacTsVariable': [[2, 7, 2, 8]],
  \ },
  \ 'range': [0, 3],
  \ }

call yac_semantic_tokens#_handle_response(v:null, s:response, 1, s:bufnr)

" Should have created prop types in buffer
let s:types = getbufvar(s:bufnr, 'yac_st_prop_types', [])
call yac_test#assert_true(
  \ len(s:types) >= 2,
  \ 'should have at least 2 prop types after response')

" Cleanup
call yac_semantic_tokens#clear()
bwipeout!

" ============================================================================
" Test 3: stale seq is ignored
" ============================================================================
call yac_test#log('INFO', 'Test 3: stale seq ignored')

enew!
call setline(1, ['test'])
let s:bufnr = bufnr('%')
let b:yac_st_seq = 5

" Send response with old seq=3 — should be ignored
call yac_semantic_tokens#_handle_response(v:null, {
  \ 'highlights': {'YacTsKeyword': [[1, 1, 1, 5]]},
  \ 'range': [0, 1],
  \ }, 3, s:bufnr)

let s:types = getbufvar(s:bufnr, 'yac_st_prop_types', [])
call yac_test#assert_eq(len(s:types), 0, 'stale seq should not apply props')

bwipeout!

" ============================================================================
" Test 4: clear removes all props
" ============================================================================
call yac_test#log('INFO', 'Test 4: clear removes props')

enew!
call setline(1, ['let foo = bar'])
let s:bufnr = bufnr('%')
let b:yac_st_seq = 1

" Apply props
call yac_semantic_tokens#_handle_response(v:null, {
  \ 'highlights': {'YacTsVariable': [[1, 5, 1, 8]]},
  \ 'range': [0, 1],
  \ }, 1, s:bufnr)

let s:types_before = getbufvar(s:bufnr, 'yac_st_prop_types', [])
call yac_test#assert_true(len(s:types_before) > 0, 'should have props before clear')

" Clear
call yac_semantic_tokens#clear()

let s:types_after = getbufvar(s:bufnr, 'yac_st_prop_types', [])
call yac_test#assert_eq(len(s:types_after), 0, 'should have no props after clear')

bwipeout!

" ============================================================================
" Test 5: double-buffered generation swap
" ============================================================================
call yac_test#log('INFO', 'Test 5: generation swap')

enew!
call setline(1, ['abc def ghi'])
let s:bufnr = bufnr('%')
let b:yac_st_seq = 1

" First response → gen 1 (flips from default 0)
call yac_semantic_tokens#_handle_response(v:null, {
  \ 'highlights': {'YacTsKeyword': [[1, 1, 1, 4]]},
  \ 'range': [0, 1],
  \ }, 1, s:bufnr)

let s:gen1 = getbufvar(s:bufnr, 'yac_st_gen', -1)
call yac_test#assert_eq(s:gen1, 1, 'first response should flip to gen 1')

" Second response → gen 0 (flips back)
let b:yac_st_seq = 2
call yac_semantic_tokens#_handle_response(v:null, {
  \ 'highlights': {'YacTsFunction': [[1, 5, 1, 8]]},
  \ 'range': [0, 1],
  \ }, 2, s:bufnr)

let s:gen2 = getbufvar(s:bufnr, 'yac_st_gen', -1)
call yac_test#assert_eq(s:gen2, 0, 'second response should flip to gen 0')

bwipeout!

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
