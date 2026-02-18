" ============================================================================
" Batch Test Runner - 所有测试共享一个 Vim session + LSP
"
" 好处：LSP 只启动一次，后续测试直接复用
" ============================================================================

call yac_test#set_batch_mode()

" 全局设置：允许切换未保存 buffer
set hidden

" Pre-warm: 启动 LSP 并等待就绪，避免第一个测试浪费时间探测
call yac_test#setup()
call yac_test#open_test_file('test_data/src/lib.rs', 30000)
call popup_clear()
silent! %bwipeout!

" 记录 test_data/src/lib.rs 的原始路径（用于测试间恢复）
let s:project_root = getcwd()
let s:test_file_path = s:project_root . '/test_data/src/lib.rs'

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

  " 每个测试之间清理状态
  call popup_clear()
  silent! cclose
  call setqflist([])
  silent! %bwipeout!

  " 恢复 test_data/src/lib.rs（某些测试会 write 修改到磁盘）
  call system('git checkout -- test_data/src/lib.rs')
endfor

call yac_test#finish()
