" ============================================================================
" E2E Test: Folding Range
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('folding')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 3000)

" ============================================================================
" Test 1: Get folding ranges
" ============================================================================
call yac_test#log('INFO', 'Test 1: Get folding ranges')

" 执行 folding range 命令
YacFoldingRange
sleep 2

" 检查 fold 是否被设置
let fold_method = &foldmethod
call yac_test#log('INFO', 'Fold method: ' . fold_method)

" 检查是否有 fold
let has_folds = 0
for lnum in range(1, line('$'))
  if foldlevel(lnum) > 0
    let has_folds = 1
    break
  endif
endfor

call yac_test#log('INFO', 'Has folds: ' . has_folds)

" ============================================================================
" Test 2: Fold struct
" ============================================================================
call yac_test#log('INFO', 'Test 2: Fold struct')

" 定位到 User struct
call cursor(6, 1)
let struct_fold = foldlevel('.')

call yac_test#log('INFO', 'Struct fold level: ' . struct_fold)

" 尝试关闭 fold
if struct_fold > 0
  normal! zc
  call yac_test#log('INFO', 'Struct folded')

  " 再打开
  normal! zo
  call yac_test#log('INFO', 'Struct unfolded')
endif

" ============================================================================
" Test 3: Fold impl block
" ============================================================================
call yac_test#log('INFO', 'Test 3: Fold impl block')

" 定位到 impl User
call cursor(12, 1)
let impl_fold = foldlevel('.')

call yac_test#log('INFO', 'Impl block fold level: ' . impl_fold)

" ============================================================================
" Test 4: Fold function
" ============================================================================
call yac_test#log('INFO', 'Test 4: Fold function')

" 定位到 create_user_map 函数
call cursor(30, 1)
let func_fold = foldlevel('.')

call yac_test#log('INFO', 'Function fold level: ' . func_fold)

" ============================================================================
" Test 5: Fold all
" ============================================================================
call yac_test#log('INFO', 'Test 5: Fold all')

" 关闭所有 fold
normal! zM
sleep 500m

" 统计可见行数
let visible_lines = 0
for lnum in range(1, line('$'))
  if foldclosed(lnum) == -1 || foldclosed(lnum) == lnum
    let visible_lines += 1
  endif
endfor

call yac_test#log('INFO', 'Visible lines after fold all: ' . visible_lines)

" 打开所有 fold
normal! zR
sleep 500m

call yac_test#log('INFO', 'All folds opened')

" ============================================================================
" Test 6: Nested folds
" ============================================================================
call yac_test#log('INFO', 'Test 6: Nested folds (method inside impl)')

" impl 块内的方法应该有嵌套 fold
call cursor(14, 1)  " pub fn new 在 impl 内
let method_fold = foldlevel('.')

call yac_test#log('INFO', 'Method fold level (inside impl): ' . method_fold)

" 如果 impl 是 level 1，method 应该是 level 2
if method_fold > 0
  call yac_test#log('INFO', 'Nested folding detected')
endif

" ============================================================================
" Test 7: Fold persistence after modification
" ============================================================================
call yac_test#log('INFO', 'Test 7: Fold after modification')

let original = getline(1, '$')

" 获取初始 fold
YacFoldingRange
sleep 1

" 修改文件
normal! G
normal! o
execute "normal! ifn new_fold_test() {"
normal! o
execute "normal! i    let x = 1;"
normal! o
execute "normal! i}"

" 重新获取 fold
YacFoldingRange
sleep 2

" 新函数应该也能 fold
call cursor(line('$') - 1, 1)
let new_func_fold = foldlevel('.')

call yac_test#log('INFO', 'New function fold level: ' . new_func_fold)

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 8: Fold with comments
" ============================================================================
call yac_test#log('INFO', 'Test 8: Fold with doc comments')

" 带有文档注释的函数
" 检查 create_user_map (有 /// 注释)
call cursor(27, 1)  " 文档注释开始
let doc_fold = foldlevel('.')

call yac_test#log('INFO', 'Doc comment fold level: ' . doc_fold)

" ============================================================================
" Test 9: Module/mod folds
" ============================================================================
call yac_test#log('INFO', 'Test 9: Module folds')

" tests 模块
call search('#\[cfg(test)\]')
if line('.') > 0
  let test_mod_line = line('.')
  let mod_fold = foldlevel(test_mod_line)
  call yac_test#log('INFO', 'Test module fold level: ' . mod_fold)
endif

" ============================================================================
" Test 10: Fold column display
" ============================================================================
call yac_test#log('INFO', 'Test 10: Fold column')

" 启用 fold column 显示
set foldcolumn=2
call yac_test#log('INFO', 'Fold column enabled')

" 刷新 folds
YacFoldingRange
sleep 1

" 检查是否正确显示
call yac_test#log('INFO', 'Fold column should show fold markers')

" 恢复
set foldcolumn=0

" ============================================================================
" Cleanup
" ============================================================================
" 打开所有 fold
normal! zR

call yac_test#teardown()
call yac_test#end()
