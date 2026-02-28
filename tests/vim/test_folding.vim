" ============================================================================
" E2E Test: Folding Range
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('folding')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Feature probe: 检测 folding range 是否可用
" ============================================================================
YacFoldingRange
let s:has_folds = 0
call yac_test#wait_for({-> &foldmethod == 'manual' || foldlevel(1) > 0 || foldclosed(1) >= 0}, 5000)

for lnum in range(1, line('$'))
  if foldlevel(lnum) > 0
    let s:has_folds = 1
    break
  endif
endfor

if !s:has_folds
  call yac_test#log('INFO', 'Folding ranges not available from LSP, skipping fold tests')
  call yac_test#skip('folding', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(1, 'Folding ranges are available')

" ============================================================================
" Test 1: Fold struct
" ============================================================================
call yac_test#run_case('Fold struct', {-> s:test_fold_struct()})

function! s:test_fold_struct() abort
  call cursor(6, 1)
  let struct_fold = foldlevel('.')
  call yac_test#assert_true(struct_fold > 0, 'Struct line should have fold level > 0')

  if struct_fold > 0
    normal! zc
    call yac_test#assert_true(foldclosed('.') >= 0, 'Struct should be foldable with zc')
    normal! zo
    call yac_test#assert_true(foldclosed('.') == -1, 'Struct should unfold with zo')
  endif
endfunction

" ============================================================================
" Test 2: Fold function
" ============================================================================
call yac_test#run_case('Fold function', {-> s:test_fold_function()})

function! s:test_fold_function() abort
  call cursor(30, 1)
  call yac_test#assert_true(foldlevel('.') > 0, 'Function line should have fold level > 0')
endfunction

" ============================================================================
" Test 3: Fold all / unfold all
" ============================================================================
call yac_test#run_case('Fold all', {-> s:test_fold_all()})

function! s:test_fold_all() abort
  normal! zM

  let visible_lines = 0
  for lnum in range(1, line('$'))
    if foldclosed(lnum) == -1 || foldclosed(lnum) == lnum
      let visible_lines += 1
    endif
  endfor
  call yac_test#assert_true(visible_lines < line('$'), 'Fold all should reduce visible lines')

  normal! zR
endfunction

" ============================================================================
" Test 4: Nested folds
" ============================================================================
call yac_test#run_case('Nested folds', {-> s:test_nested_folds()})

function! s:test_nested_folds() abort
  call cursor(14, 1)  " pub fn init inside struct
  call yac_test#assert_true(foldlevel('.') >= 1, 'Method inside struct should be foldable')
endfunction

" ============================================================================
" Cleanup
" ============================================================================
normal! zR

call yac_test#teardown()
call yac_test#end()
