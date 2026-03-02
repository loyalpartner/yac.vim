" ============================================================================
" Test: Folding Range — fold level 计算单元测试
" ============================================================================
" 直接注入 mock ranges，验证 b:yac_fold_levels 计算结果，
" 不依赖 LSP/daemon，也不依赖 foldlevel() 在 headless 模式下的行为。

call yac_test#begin('folding')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" 辅助：读取 b:yac_fold_levels[lnum]
function! s:lvl(lnum) abort
  return exists('b:yac_fold_levels') ? get(b:yac_fold_levels, a:lnum, -1) : -1
endfunction

" ============================================================================
" Test 1: 基本折叠 — 单个 range (0-based 0..5 → 1-based 1..6)
" ============================================================================
function! s:test_basic_fold() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 5}
    \ ])
  call yac_test#assert_eq(s:lvl(1), 1, 'line 1: level 1')
  call yac_test#assert_eq(s:lvl(3), 1, 'line 3: level 1')
  call yac_test#assert_eq(s:lvl(6), 1, 'line 6 (end): level 1')
  call yac_test#assert_eq(s:lvl(7), 0, 'line 7 (outside): level 0')
endfunction
call yac_test#run_case('Basic single fold', {-> s:test_basic_fold()})

" ============================================================================
" Test 2: 正确嵌套 — fn(0..19) + if-block(5..10)
" ============================================================================
function! s:test_nested_folds() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 19},
    \ {'start_line': 5, 'end_line': 10}
    \ ])
  call yac_test#assert_eq(s:lvl(1),  1, 'fn start: level 1')
  call yac_test#assert_eq(s:lvl(4),  1, 'inside fn, before if: level 1')
  call yac_test#assert_eq(s:lvl(6),  2, 'inside if block: level 2')
  call yac_test#assert_eq(s:lvl(11), 2, 'if end line: level 2')
  call yac_test#assert_eq(s:lvl(12), 1, 'after if, inside fn: level 1')
  call yac_test#assert_eq(s:lvl(21), 0, 'outside fn: level 0')
endfunction
call yac_test#run_case('Nested fold levels', {-> s:test_nested_folds()})

" ============================================================================
" Test 3: 冗余相邻 range — fn(0..19) + fn-body(1..18)
" ============================================================================
" 不做去重时，fn 体内层级会变成 2；做去重后应为 1。
function! s:test_redundant_ranges() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 19},
    \ {'start_line': 1, 'end_line': 18}
    \ ])
  call yac_test#assert_eq(s:lvl(1),  1, 'fn start: level 1')
  call yac_test#assert_eq(s:lvl(2),  1, 'fn body first line: level 1 (not 2)')
  call yac_test#assert_eq(s:lvl(18), 1, 'fn body last line: level 1')
  call yac_test#assert_eq(s:lvl(21), 0, 'outside fn: level 0')
endfunction
call yac_test#run_case('Redundant adjacent ranges deduped', {-> s:test_redundant_ranges()})

" ============================================================================
" Test 4: 冗余 range + 真实嵌套 — fn(0..19) + fn-body(1..18) + if(5..10)
" ============================================================================
function! s:test_redundant_with_nesting() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 19},
    \ {'start_line': 1, 'end_line': 18},
    \ {'start_line': 5, 'end_line': 10}
    \ ])
  call yac_test#assert_eq(s:lvl(1),  1, 'fn start: level 1')
  call yac_test#assert_eq(s:lvl(2),  1, 'fn body (not if): level 1')
  call yac_test#assert_eq(s:lvl(6),  2, 'inside if block: level 2')
  call yac_test#assert_eq(s:lvl(12), 1, 'after if, inside fn: level 1')
endfunction
call yac_test#run_case('Redundant ranges with real nesting', {-> s:test_redundant_with_nesting()})

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
