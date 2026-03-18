" ============================================================================
" Test: TypeScript Tree-sitter Folding — E2E (daemon integration)
" ============================================================================
" Verifies that opening a .ts file triggers tree-sitter folding via the daemon.
" Flow: BufReadPost → ensure_language → load_language → handle_response → folding_range

call yac_test#begin('ts_folding')
call yac_test#setup()

" ============================================================================
" Test 1: TypeScript file gets fold levels after open
" ============================================================================
function! s:test_ts_fold_on_open() abort
  " Open TypeScript file — BufReadPost triggers:
  "   yac_check_language → ensure_language → load_language
  "   load_language callback → folding_range → ts_folding
  execute 'edit! test_data/src/test_fold.ts'

  " Wait for b:yac_fold_levels to be populated by the daemon response.
  let l:got_folds = yac_test#wait_for(
    \ {-> exists('b:yac_fold_levels') && len(b:yac_fold_levels) > 0}, 10000)

  if !l:got_folds
    " Daemon may have restarted (crash/reconnect) — re-ensure language and retry
    " Reset loaded_langs so ensure_language sends load_language to new daemon
    call yac#_reset_loaded_langs()
    call yac#ensure_language(b:yac_lang_dir)
    sleep 1000m
    call yac#folding_range()
    let l:got_folds = yac_test#wait_for(
      \ {-> exists('b:yac_fold_levels') && len(b:yac_fold_levels) > 0}, 5000)
  endif

  call yac_test#assert_eq(l:got_folds, 1, 'TypeScript file should have fold levels')

  " Verify specific fold: globalTeardown function body (lines 3-10)
  if exists('b:yac_fold_levels')
    let l:lvl4 = get(b:yac_fold_levels, 4, 0)
    call yac_test#assert_eq(l:lvl4 >= 1, 1,
      \ printf('line 4 (inside function body) should be fold level >= 1, got %d', l:lvl4))
  endif
endfunction
call yac_test#run_case('TypeScript auto-fold on open', {-> s:test_ts_fold_on_open()})

" ============================================================================
" Test 2: Multiple fold regions detected
" ============================================================================
function! s:test_ts_multiple_folds() abort
  if !exists('b:yac_fold_start_lines')
    call yac_test#skip('Multiple TypeScript fold regions', 'No fold data available')
    return
  endif

  " test_fold.ts has at least 3 fold regions:
  " globalTeardown body, normalFunction body, arrowFn body
  call yac_test#assert_eq(len(b:yac_fold_start_lines) >= 3, 1,
    \ printf('should have >= 3 fold regions, got %d', len(b:yac_fold_start_lines)))
endfunction
call yac_test#run_case('Multiple TypeScript fold regions', {-> s:test_ts_multiple_folds()})

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
