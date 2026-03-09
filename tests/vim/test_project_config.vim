" ============================================================================
" Unit Test: Project config — .yac.json loading and merging
" ============================================================================

call yac_test#begin('project_config')

" ============================================================================
" Test 1: parse valid .yac.json
" ============================================================================
call yac_test#log('INFO', 'Test 1: parse valid config')

let s:tmpdir = tempname()
call mkdir(s:tmpdir, 'p')

" Write a .yac.json
call writefile([json_encode({
  \ 'auto_complete': 0,
  \ 'ts_highlights': 0,
  \ 'theme': 'gruvbox-dark',
  \ })], s:tmpdir . '/.yac.json')

let s:config = yac_config#load(s:tmpdir)
call yac_test#assert_eq(type(s:config), v:t_dict, 'should return a dict')
call yac_test#assert_eq(s:config.auto_complete, 0, 'auto_complete should be 0')
call yac_test#assert_eq(s:config.ts_highlights, 0, 'ts_highlights should be 0')
call yac_test#assert_eq(s:config.theme, 'gruvbox-dark', 'theme should be gruvbox-dark')

" ============================================================================
" Test 2: missing .yac.json returns empty dict
" ============================================================================
call yac_test#log('INFO', 'Test 2: missing config')

let s:tmpdir2 = tempname()
call mkdir(s:tmpdir2, 'p')
let s:config2 = yac_config#load(s:tmpdir2)
call yac_test#assert_eq(s:config2, {}, 'missing .yac.json should return {}')

" ============================================================================
" Test 3: invalid JSON returns empty dict (no crash)
" ============================================================================
call yac_test#log('INFO', 'Test 3: invalid JSON')

let s:tmpdir3 = tempname()
call mkdir(s:tmpdir3, 'p')
call writefile(['not valid json {{{'], s:tmpdir3 . '/.yac.json')
let s:config3 = yac_config#load(s:tmpdir3)
call yac_test#assert_eq(s:config3, {}, 'invalid JSON should return {}')

" ============================================================================
" Test 4: apply config overrides buffer-local settings
" ============================================================================
call yac_test#log('INFO', 'Test 4: apply config')

" Save original
let s:orig_auto_complete = get(g:, 'yac_auto_complete', 1)

call yac_config#apply({'auto_complete': 0})
call yac_test#assert_eq(
  \ get(b:, 'yac_auto_complete', -1), 0,
  \ 'apply should set b:yac_auto_complete = 0')

" Restore
let g:yac_auto_complete = s:orig_auto_complete
unlet! b:yac_auto_complete

" ============================================================================
" Test 5: apply with empty config does nothing
" ============================================================================
call yac_test#log('INFO', 'Test 5: apply empty config')

unlet! b:yac_auto_complete
call yac_config#apply({})
call yac_test#assert_true(
  \ !exists('b:yac_auto_complete'),
  \ 'apply({}) should not set any b: vars')

" Clean up
call delete(s:tmpdir, 'rf')
call delete(s:tmpdir2, 'rf')
call delete(s:tmpdir3, 'rf')

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
