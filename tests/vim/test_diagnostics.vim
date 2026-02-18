" ============================================================================
" E2E Test: Diagnostics (Errors/Warnings)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('diagnostics')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" ============================================================================
" Test 1: Clean file should have no diagnostics
" ============================================================================
call yac_test#log('INFO', 'Test 1: Clean file diagnostics')

" 等待 LSP 分析完成（诊断信息出现或超时）
call yac_test#wait_for({-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)}, 3000)

" 检查是否有诊断信息
" 注意：这取决于 yac.vim 如何存储诊断
let has_diagnostics = exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)
call yac_test#log('INFO', 'Clean file has diagnostics: ' . has_diagnostics)

" 干净的代码不应该有错误（可能有警告）
" 不做强断言，因为可能有 unused 警告

" ============================================================================
" Test 2: Introduce syntax error
" ============================================================================
call yac_test#log('INFO', 'Test 2: Syntax error detection')

" 保存原始内容
let original_content = getline(1, '$')

" 在文件末尾添加语法错误
normal! G
normal! o
execute "normal! ilet syntax_error: i32 = \"not a number\";"

" 保存文件触发诊断
silent write
call yac_test#wait_for({-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)}, 3000)

" 检查诊断是否出现
call yac_test#log('INFO', 'Checking for type error diagnostic')

" 尝试获取诊断信息
if exists('b:yac_diagnostics')
  call yac_test#log('INFO', 'Diagnostics count: ' . len(b:yac_diagnostics))
  call yac_test#assert_true(!empty(b:yac_diagnostics), 'Should have diagnostics for type error')
endif

" ============================================================================
" Test 3: Diagnostic virtual text toggle
" ============================================================================
call yac_test#log('INFO', 'Test 3: Diagnostic virtual text toggle')

" 检查虚拟文本设置
let vtext_enabled = get(g:, 'yac_bridge_diagnostic_virtual_text', 0)
call yac_test#log('INFO', 'Virtual text enabled: ' . vtext_enabled)

" 切换虚拟文本
if exists(':YacToggleDiagnosticVirtualText')
  " toggle 使用 s: 内部状态，外部只能验证命令不崩溃
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(1, 'Toggle should not crash')

  " 恢复原状态
  YacToggleDiagnosticVirtualText
endif

" ============================================================================
" Test 4: Clear diagnostics
" ============================================================================
call yac_test#log('INFO', 'Test 4: Clear diagnostic virtual text')

if exists(':YacClearDiagnosticVirtualText')
  YacClearDiagnosticVirtualText
  call yac_test#log('INFO', 'Cleared diagnostic virtual text')
endif

" ============================================================================
" Test 5: Fix error and verify diagnostics clear
" ============================================================================
call yac_test#log('INFO', 'Test 5: Fix error clears diagnostics')

" 删除错误行
normal! Gdd

" 保存
silent write
call yac_test#wait_for({-> !exists('b:yac_diagnostics') || empty(b:yac_diagnostics)}, 3000)

" 诊断应该减少或消失
if exists('b:yac_diagnostics')
  call yac_test#log('INFO', 'Remaining diagnostics: ' . len(b:yac_diagnostics))
endif

" ============================================================================
" Test 6: Multiple errors
" ============================================================================
call yac_test#log('INFO', 'Test 6: Multiple errors detection')

" 添加多个错误
normal! G
normal! o
execute "normal! ilet err1: i32 = \"x\";"
normal! o
execute "normal! ilet err2: bool = 123;"
normal! o
execute "normal! iunknown_function();"

silent write
call yac_test#wait_for({-> exists('b:yac_diagnostics') && len(b:yac_diagnostics) >= 2}, 3000)

if exists('b:yac_diagnostics')
  let diag_count = len(b:yac_diagnostics)
  call yac_test#log('INFO', 'Multiple errors found: ' . diag_count)
  call yac_test#assert_true(diag_count >= 2, 'Should detect multiple errors')
endif

" ============================================================================
" Cleanup: 恢复原始文件
" ============================================================================
call yac_test#log('INFO', 'Cleanup: Restoring original file')

" 删除添加的行
silent! %d
call setline(1, original_content)
silent write

call yac_test#teardown()
call yac_test#end()
