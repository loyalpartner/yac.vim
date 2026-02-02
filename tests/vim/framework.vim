" ============================================================================
" YAC E2E Test Framework
" ============================================================================
" 提供断言函数、智能等待、结果收集等测试基础设施
"
" 用法:
"   source tests/vim/framework.vim
"   call yac_test#begin('test_suite_name')
"   call yac_test#assert_eq(actual, expected, 'test description')
"   call yac_test#end()
" ============================================================================

let s:test_results = []
let s:test_suite = ''
let s:passed = 0
let s:failed = 0
let s:start_time = 0

" ----------------------------------------------------------------------------
" 测试生命周期
" ----------------------------------------------------------------------------

" 开始测试套件
function! yac_test#begin(suite_name) abort
  let s:test_suite = a:suite_name
  let s:test_results = []
  let s:passed = 0
  let s:failed = 0
  let s:start_time = localtime()

  call s:log('INFO', 'Starting test suite: ' . a:suite_name)
endfunction

" 结束测试套件并输出结果
function! yac_test#end() abort
  let elapsed = localtime() - s:start_time
  let total = s:passed + s:failed

  call s:log('INFO', '----------------------------------------')
  call s:log('INFO', 'Test Suite: ' . s:test_suite)
  call s:log('INFO', 'Total: ' . total . ' | Passed: ' . s:passed . ' | Failed: ' . s:failed)
  call s:log('INFO', 'Duration: ' . elapsed . 's')
  call s:log('INFO', '----------------------------------------')

  " 输出 JSON 格式结果（供外部解析）
  let result = {
        \ 'suite': s:test_suite,
        \ 'total': total,
        \ 'passed': s:passed,
        \ 'failed': s:failed,
        \ 'duration': elapsed,
        \ 'tests': s:test_results,
        \ 'success': s:failed == 0
        \ }

  echo '::YAC_TEST_RESULT::' . json_encode(result)

  return s:failed == 0
endfunction

" ----------------------------------------------------------------------------
" 断言函数
" ----------------------------------------------------------------------------

" 断言相等
function! yac_test#assert_eq(actual, expected, description) abort
  if a:actual ==# a:expected
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description,
          \ 'Expected: ' . string(a:expected) . ', Got: ' . string(a:actual))
    return 0
  endif
endfunction

" 断言不相等
function! yac_test#assert_neq(actual, not_expected, description) abort
  if a:actual !=# a:not_expected
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description,
          \ 'Expected not to be: ' . string(a:not_expected))
    return 0
  endif
endfunction

" 断言为真
function! yac_test#assert_true(value, description) abort
  if a:value
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description, 'Expected true, got false')
    return 0
  endif
endfunction

" 断言为假
function! yac_test#assert_false(value, description) abort
  if !a:value
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description, 'Expected false, got true')
    return 0
  endif
endfunction

" 断言包含
function! yac_test#assert_contains(haystack, needle, description) abort
  if type(a:haystack) == v:t_string
    let found = stridx(a:haystack, a:needle) >= 0
  elseif type(a:haystack) == v:t_list
    let found = index(a:haystack, a:needle) >= 0
  else
    let found = 0
  endif

  if found
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description,
          \ 'Expected to contain: ' . string(a:needle))
    return 0
  endif
endfunction

" 断言匹配正则
function! yac_test#assert_match(value, pattern, description) abort
  if match(a:value, a:pattern) >= 0
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description,
          \ 'Expected to match: ' . a:pattern . ', Got: ' . string(a:value))
    return 0
  endif
endfunction

" 断言行号变化（用于 goto 测试）
function! yac_test#assert_line_changed(start_line, description) abort
  let current_line = line('.')
  if current_line != a:start_line
    call s:record_pass(a:description . ' (jumped from ' . a:start_line . ' to ' . current_line . ')')
    return 1
  else
    call s:record_fail(a:description, 'Line did not change, stayed at ' . a:start_line)
    return 0
  endif
endfunction

" 断言光标位置
function! yac_test#assert_cursor(expected_line, expected_col, description) abort
  let actual_line = line('.')
  let actual_col = col('.')
  if actual_line == a:expected_line && actual_col == a:expected_col
    call s:record_pass(a:description)
    return 1
  else
    call s:record_fail(a:description,
          \ printf('Expected (%d,%d), Got (%d,%d)',
          \        a:expected_line, a:expected_col, actual_line, actual_col))
    return 0
  endif
endfunction

" ----------------------------------------------------------------------------
" 智能等待
" ----------------------------------------------------------------------------

" 等待条件满足（带超时）
" condition: 返回 0/1 的函数引用或表达式字符串
" timeout_ms: 超时时间（毫秒）
" interval_ms: 检查间隔（毫秒）
function! yac_test#wait_for(condition, timeout_ms, ...) abort
  let interval_ms = a:0 >= 1 ? a:1 : 100
  let elapsed = 0

  while elapsed < a:timeout_ms
    if type(a:condition) == v:t_func
      let result = a:condition()
    else
      let result = eval(a:condition)
    endif

    if result
      return 1
    endif

    execute 'sleep ' . interval_ms . 'm'
    let elapsed += interval_ms
  endwhile

  return 0
endfunction

" 等待 LSP 就绪
function! yac_test#wait_lsp_ready(timeout_ms) abort
  call s:log('INFO', 'Waiting for LSP to be ready...')

  " 简单策略：等待固定时间让 rust-analyzer 初始化
  let wait_seconds = a:timeout_ms / 1000
  execute 'sleep ' . wait_seconds

  call s:log('INFO', 'LSP ready (waited ' . wait_seconds . 's)')
  return 1
endfunction

" 等待浮窗出现
function! yac_test#wait_popup(timeout_ms) abort
  return yac_test#wait_for({-> !empty(popup_list())}, a:timeout_ms)
endfunction

" 等待补全菜单
function! yac_test#wait_completion(timeout_ms) abort
  return yac_test#wait_for({-> pumvisible()}, a:timeout_ms)
endfunction

" ----------------------------------------------------------------------------
" 辅助函数
" ----------------------------------------------------------------------------

" 记录测试通过
function! s:record_pass(description) abort
  let s:passed += 1
  call add(s:test_results, {'name': a:description, 'status': 'pass'})
  call s:log('PASS', a:description)
endfunction

" 记录测试失败
function! s:record_fail(description, reason) abort
  let s:failed += 1
  call add(s:test_results, {'name': a:description, 'status': 'fail', 'reason': a:reason})
  call s:log('FAIL', a:description . ' - ' . a:reason)
endfunction

" 日志输出
function! s:log(level, message) abort
  let timestamp = strftime('%H:%M:%S')
  let prefix = '[' . timestamp . '] [' . a:level . '] '
  echo prefix . a:message
endfunction

" 公开日志函数
function! yac_test#log(level, message) abort
  call s:log(a:level, a:message)
endfunction

" 跳过测试
function! yac_test#skip(description, reason) abort
  call add(s:test_results, {'name': a:description, 'status': 'skip', 'reason': a:reason})
  call s:log('SKIP', a:description . ' - ' . a:reason)
endfunction

" ----------------------------------------------------------------------------
" 测试装置 (Fixtures)
" ----------------------------------------------------------------------------

" 设置测试环境
function! yac_test#setup() abort
  " 禁用 swap 和 backup
  set noswapfile
  set nobackup
  set nowritebackup

  " 启动 YAC
  if exists(':YacStart')
    YacStart
  endif
endfunction

" 清理测试环境
function! yac_test#teardown() abort
  " 关闭所有 popup
  call popup_clear()

  " 停止 YAC
  if exists(':YacStop')
    silent! YacStop
  endif
endfunction

" 打开测试文件并等待 LSP
function! yac_test#open_test_file(file, wait_ms) abort
  execute 'edit ' . a:file
  call yac_test#wait_lsp_ready(a:wait_ms)
endfunction
