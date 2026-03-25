" ============================================================================
" E2E Test: Document Highlight (LSP + tree-sitter fallback)
" ============================================================================

call yac_test#begin('doc_highlight')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file, wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" Helper: count matches with YacDocHighlight* groups
function! s:get_doc_hl_matches() abort
  return filter(getmatches(), {_, m -> m.group =~# '^YacDocHighlight'})
endfunction

" ============================================================================
" Test 1: inject document_highlight response → matchaddpos creates highlights
" ============================================================================
call yac_test#log('INFO', 'Test 1: inject response creates highlights')

call cursor(5, 10)

" Mock response: 3 highlights
let s:mock_response = {
  \ 'highlights': [
  \   {'line': 4, 'col': 9, 'end_line': 4, 'end_col': 14, 'kind': 1},
  \   {'line': 10, 'col': 4, 'end_line': 10, 'end_col': 9, 'kind': 1},
  \   {'line': 15, 'col': 4, 'end_line': 15, 'end_col': 9, 'kind': 1},
  \ ]}

call yac#test_inject_response('document_highlight', s:mock_response)

let s:matches = s:get_doc_hl_matches()
call yac_test#assert_eq(len(s:matches), 3,
  \ 'Should have 3 document highlight matches')

" Mock uses kind=1 so all should be YacDocHighlightText
for s:m in s:matches
  call yac_test#assert_eq(s:m.group, 'YacDocHighlightText',
    \ 'All highlights should use YacDocHighlightText')
endfor

" ============================================================================
" Test 2: clear_document_highlights removes all matches
" ============================================================================
call yac_test#log('INFO', 'Test 2: clear removes all highlights')

call yac#clear_document_highlights()

let s:matches_after = s:get_doc_hl_matches()
call yac_test#assert_eq(len(s:matches_after), 0,
  \ 'Should have 0 matches after clear')

" ============================================================================
" Test 3: new response replaces old highlights
" ============================================================================
call yac_test#log('INFO', 'Test 3: new response replaces old')

" First response
call yac#test_inject_response('document_highlight', {
  \ 'highlights': [
  \   {'line': 4, 'col': 0, 'end_line': 4, 'end_col': 5, 'kind': 1},
  \   {'line': 8, 'col': 0, 'end_line': 8, 'end_col': 5, 'kind': 1},
  \ ]})
call yac_test#assert_eq(len(s:get_doc_hl_matches()), 2,
  \ 'First response: 2 matches')

" Second response should replace
call yac#test_inject_response('document_highlight', {
  \ 'highlights': [
  \   {'line': 20, 'col': 0, 'end_line': 20, 'end_col': 3, 'kind': 1},
  \ ]})
call yac_test#assert_eq(len(s:get_doc_hl_matches()), 1,
  \ 'Second response should replace: 1 match')

call yac#clear_document_highlights()

" ============================================================================
" Test 4: empty response clears highlights
" ============================================================================
call yac_test#log('INFO', 'Test 4: empty response clears highlights')

" Add some highlights first
call yac#test_inject_response('document_highlight', s:mock_response)
call yac_test#assert_true(len(s:get_doc_hl_matches()) > 0,
  \ 'Should have highlights before empty response')

" Empty response
call yac#test_inject_response('document_highlight', {'highlights': []})
call yac_test#assert_eq(len(s:get_doc_hl_matches()), 0,
  \ 'Empty response should clear all highlights')

" ============================================================================
" Cleanup
" ============================================================================
call yac#clear_document_highlights()
call yac_test#teardown()
call yac_test#end()
