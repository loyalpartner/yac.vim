" ============================================================================
" Batch Test Runner - 所有测试共享一个 Vim session + LSP
"
" 好处：LSP 只启动一次，后续测试直接复用
" ============================================================================

call yac_test#set_batch_mode()

" 全局设置：允许切换未保存 buffer
set hidden

" 收集所有测试文件
let s:test_dir = expand('<sfile>:p:h')
let s:test_files = sort(glob(s:test_dir . '/test_*.vim', 0, 1))

for s:test_file in s:test_files
  try
    execute 'source ' . fnameescape(s:test_file)
  catch
    " 如果某个测试文件崩溃，记录错误并继续
    let s:suite = fnamemodify(s:test_file, ':t:r')
    echo '::YAC_TEST_RESULT::' . json_encode({
          \ 'suite': s:suite,
          \ 'total': 1,
          \ 'passed': 0,
          \ 'failed': 1,
          \ 'duration': 0,
          \ 'tests': [{'name': 'source ' . s:suite, 'status': 'fail',
          \            'reason': v:exception . ' at ' . v:throwpoint}],
          \ 'success': 0
          \ })
  endtry

  " 每个测试之间清理状态：关闭所有 buffer，回到干净状态
  call popup_clear()
  silent! %bwipeout!
endfor

call yac_test#finish()
