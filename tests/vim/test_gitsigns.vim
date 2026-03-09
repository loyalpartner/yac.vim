" ============================================================================
" Unit Test: Git Signs — diff hunk parsing and sign data
" ============================================================================

call yac_test#begin('gitsigns')

" ============================================================================
" Test 1: parse_hunk_header parses @@ -a,b +c,d @@ format
" ============================================================================
call yac_test#log('INFO', 'Test 1: parse_hunk_header')

call yac_test#assert_eq(
  \ yac_gitsigns#parse_hunk_header('@@ -10,5 +12,7 @@'),
  \ {'old_start': 10, 'old_count': 5, 'new_start': 12, 'new_count': 7},
  \ 'should parse standard hunk header')

call yac_test#assert_eq(
  \ yac_gitsigns#parse_hunk_header('@@ -1 +1,3 @@'),
  \ {'old_start': 1, 'old_count': 1, 'new_start': 1, 'new_count': 3},
  \ 'should handle missing count (defaults to 1)')

call yac_test#assert_eq(
  \ yac_gitsigns#parse_hunk_header('@@ -5,0 +6,2 @@'),
  \ {'old_start': 5, 'old_count': 0, 'new_start': 6, 'new_count': 2},
  \ 'should handle zero count (pure addition)')

" ============================================================================
" Test 2: diff_to_signs converts hunks to sign data
" ============================================================================
call yac_test#log('INFO', 'Test 2: diff_to_signs')

" Pure addition: 2 lines added at line 6
let s:signs = yac_gitsigns#diff_to_signs([
  \ '@@ -5,0 +6,2 @@',
  \ '+added line 1',
  \ '+added line 2',
  \ ])
call yac_test#assert_eq(len(s:signs), 2, 'should have 2 add signs')
call yac_test#assert_eq(s:signs[0].type, 'add', 'first sign should be add')
call yac_test#assert_eq(s:signs[0].lnum, 6, 'first add at line 6')
call yac_test#assert_eq(s:signs[1].lnum, 7, 'second add at line 7')

" Pure deletion: 1 line deleted after line 3
let s:signs = yac_gitsigns#diff_to_signs([
  \ '@@ -3,1 +3,0 @@',
  \ '-deleted line',
  \ ])
call yac_test#assert_eq(len(s:signs), 1, 'should have 1 delete sign')
call yac_test#assert_eq(s:signs[0].type, 'delete', 'should be delete type')
call yac_test#assert_eq(s:signs[0].lnum, 3, 'delete marker at line 3')

" Modification: 1 line changed at line 10
let s:signs = yac_gitsigns#diff_to_signs([
  \ '@@ -10,1 +10,1 @@',
  \ '-old line',
  \ '+new line',
  \ ])
call yac_test#assert_eq(len(s:signs), 1, 'should have 1 change sign')
call yac_test#assert_eq(s:signs[0].type, 'change', 'should be change type')
call yac_test#assert_eq(s:signs[0].lnum, 10, 'change at line 10')

" ============================================================================
" Test 3: sign definitions exist
" ============================================================================
call yac_test#log('INFO', 'Test 3: sign definitions')

call yac_gitsigns#define_signs()
let s:defined = sign_getdefined()
let s:names = map(copy(s:defined), 'v:val.name')

call yac_test#assert_true(
  \ index(s:names, 'YacGitAdd') >= 0,
  \ 'YacGitAdd sign should be defined')
call yac_test#assert_true(
  \ index(s:names, 'YacGitDelete') >= 0,
  \ 'YacGitDelete sign should be defined')
call yac_test#assert_true(
  \ index(s:names, 'YacGitChange') >= 0,
  \ 'YacGitChange sign should be defined')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
