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
" Test 5: fold_start_lines 正确设置
" ============================================================================
function! s:test_fold_start_lines() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 19},
    \ {'start_line': 5, 'end_line': 10},
    \ {'start_line': 25, 'end_line': 35}
    \ ])
  call yac_test#assert_eq(len(b:yac_fold_start_lines), 3, 'should have 3 fold start lines')
  call yac_test#assert_eq(b:yac_fold_start_lines[0], 1,  'first fold at line 1 (1-based)')
  call yac_test#assert_eq(b:yac_fold_start_lines[1], 6,  'second fold at line 6 (1-based)')
  call yac_test#assert_eq(b:yac_fold_start_lines[2], 26, 'third fold at line 26 (1-based)')
endfunction
call yac_test#run_case('Fold start lines correct', {-> s:test_fold_start_lines()})

" ============================================================================
" Test 6: headless 模式 sign API 基础验证（含 Unicode text）
" ============================================================================
function! s:test_sign_api_basic() abort
  " ASCII text
  call sign_define('yac_test_ascii', {'text': '>'})
  let id = sign_place(0, 'yac_test_grp', 'yac_test_ascii', bufnr('%'), {'lnum': 1})
  call yac_test#assert_eq(id > 0, 1, 'sign_place (ascii) returns valid id')
  call sign_unplace('yac_test_grp', {'buffer': bufnr('%')})

  " Unicode text（模拟实际 fold sign）
  let define_ok = sign_define('yac_test_uni', {'text': '▾', 'texthl': 'FoldColumn'})
  call yac_test#assert_eq(define_ok, 0, 'sign_define unicode returns 0 (success)')
  let id2 = sign_place(0, 'yac_test_grp', 'yac_test_uni', bufnr('%'), {'lnum': 1})
  call yac_test#assert_eq(id2 > 0, 1, 'sign_place (unicode) returns valid id')
  let placed = sign_getplaced(bufnr('%'), {'group': 'yac_test_grp'})[0].signs
  call yac_test#assert_eq(len(placed), 1, 'unicode sign placed')
  call sign_unplace('yac_test_grp', {'buffer': bufnr('%')})
endfunction
call yac_test#run_case('Sign API basic works in headless', {-> s:test_sign_api_basic()})

" ============================================================================
" Test 7: signs 放置在折叠起始行
" ============================================================================
function! s:test_fold_signs_placed() abort
  call yac#apply_folding_ranges_test([
    \ {'start_line': 0, 'end_line': 10},
    \ {'start_line': 20, 'end_line': 30}
    \ ])
  let placed = sign_getplaced(bufnr('%'), {'group': 'yac_folds'})[0].signs
  let lnums = sort(map(copy(placed), {_, s -> s.lnum}), 'n')
  call yac_test#assert_eq(len(placed), 2, 'should have 2 signs placed')
  call yac_test#assert_eq(lnums[0], 1,  'first sign at line 1')
  call yac_test#assert_eq(lnums[1], 21, 'second sign at line 21')
endfunction
call yac_test#run_case('Fold signs placed on start lines', {-> s:test_fold_signs_placed()})

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
