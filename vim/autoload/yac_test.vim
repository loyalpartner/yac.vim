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
let s:output_file = '/tmp/yac_test_output.txt'
let s:batch_mode = 0
let s:lsp_ready = 0
let s:term_mode = 0

" 检测运行模式
if $YAC_TEST_OUTPUT != ''
  let s:output_file = $YAC_TEST_OUTPUT
endif
if $YAC_TEST_SIGNAL != ''
  let s:term_mode = 1
endif

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
  " 最终 v:errmsg 检测
  call yac_test#check_errors()

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

  let result_line = '::YAC_TEST_RESULT::' . json_encode(result)

  " 用 writefile 输出结果（避免 redir / -- More -- 问题）
  call writefile([result_line], s:output_file)

  " 通知 driver 测试完成
  if s:term_mode && $YAC_TEST_SIGNAL != ''
    call writefile(['DONE'], $YAC_TEST_SIGNAL)
  endif

  " term_start 模式下不自己 qa!，由 driver 控制退出（先 dump 屏幕）
  if !s:term_mode
    qa!
  endif

  return s:failed == 0
endfunction

" ----------------------------------------------------------------------------
" 组合断言：等待 + 断言（消除样板代码）
" ----------------------------------------------------------------------------

" 等待条件满足，成功记录 PASS，超时记录 FAIL（含超时时间）
function! yac_test#wait_assert(condition, timeout_ms, description) abort
  let result = yac_test#wait_for(a:condition, a:timeout_ms)
  if result
    call s:record_pass(a:description)
  else
    call s:record_fail(a:description,
          \ printf('Timed out after %dms', a:timeout_ms))
  endif
  return result
endfunction

" 等待条件满足，超时时仅记录 SKIP 而非 FAIL（用于可选功能探测）
function! yac_test#wait_or_skip(condition, timeout_ms, description) abort
  let result = yac_test#wait_for(a:condition, a:timeout_ms)
  if !result
    call yac_test#skip(a:description, printf('Not available (waited %dms)', a:timeout_ms))
  endif
  return result
endfunction

" ----------------------------------------------------------------------------
" 测试用例包装器
" ----------------------------------------------------------------------------

" 运行单个测试用例，自动捕获异常
" Func: Funcref 或字符串表达式（字符串会在调用者脚本上下文中 execute）
function! yac_test#run_case(name, Func) abort
  call s:log('INFO', 'Test: ' . a:name)
  call popup_clear()
  try
    if type(a:Func) == v:t_string
      execute 'call ' . a:Func
    else
      call a:Func()
    endif
  catch
    call s:record_fail(a:name, 'Exception: ' . v:exception . ' at ' . v:throwpoint)
  endtry
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
  let interval_ms = a:0 >= 1 ? a:1 : 50
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

" 等待 LSP 就绪 — 通过 lsp_status 查询 daemon 内部状态
function! yac_test#wait_lsp_ready(timeout_ms) abort
  if s:lsp_ready
    call s:log('INFO', 'LSP already ready, skipping wait')
    return 1
  endif

  call s:log('INFO', 'Probing LSP readiness via lsp_status...')

  let l:ready = yac_test#wait_for({-> s:probe_lsp_status()}, a:timeout_ms)

  if l:ready
    let s:lsp_ready = 1
    call s:log('INFO', 'LSP ready')
  else
    call s:log('WARN', 'LSP not ready after ' . (a:timeout_ms / 1000) . 's')
  endif
  return l:ready
endfunction

function! s:probe_lsp_status() abort
  " Check result from previous async callback (processed during sleep interval)
  let l:ready = get(g:yac_lsp_status, 'ready', 0)
  " Fire next async query for the following poll cycle
  call yac#lsp_status(expand('%:p'))
  return l:ready
endfunction

" 等待浮窗出现
function! yac_test#wait_popup(timeout_ms) abort
  return yac_test#wait_for({-> !empty(popup_list())}, a:timeout_ms)
endfunction

" 等待补全菜单
function! yac_test#wait_completion(timeout_ms) abort
  return yac_test#wait_for({-> pumvisible()}, a:timeout_ms)
endfunction

" 等待光标位置变化（用于 goto 测试）
function! yac_test#wait_cursor_move(start_line, start_col, timeout_ms) abort
  let l:start_line = a:start_line
  let l:start_col = a:start_col
  return yac_test#wait_for({-> line('.') != l:start_line || col('.') != l:start_col}, a:timeout_ms)
endfunction

" 等待行变化
function! yac_test#wait_line_change(start_line, timeout_ms) abort
  let l:start_line = a:start_line
  return yac_test#wait_for({-> line('.') != l:start_line}, a:timeout_ms)
endfunction

" 等待文件变化（跨文件跳转）
function! yac_test#wait_file_change(start_file, timeout_ms) abort
  let l:start_file = a:start_file
  return yac_test#wait_for({-> expand('%:p') != l:start_file}, a:timeout_ms)
endfunction

" 等待 quickfix 列表有内容
function! yac_test#wait_qflist(timeout_ms) abort
  return yac_test#wait_for({-> !empty(getqflist())}, a:timeout_ms)
endfunction

" 等待 signs 出现
function! yac_test#wait_signs(timeout_ms, ...) abort
  let l:group = a:0 >= 1 ? a:1 : ''
  if l:group != ''
    return yac_test#wait_for({-> !empty(sign_getplaced('%', {'group': l:group})[0].signs)}, a:timeout_ms)
  endif
  return yac_test#wait_for({-> !empty(sign_getplaced('%')[0].signs)}, a:timeout_ms)
endfunction

" 等待 popup 关闭
function! yac_test#wait_no_popup(timeout_ms) abort
  return yac_test#wait_for({-> empty(popup_list())}, a:timeout_ms)
endfunction

" 等待 hover popup 出现（排除 toast 通知干扰）
function! yac_test#wait_hover_popup(timeout_ms) abort
  return yac_test#wait_for({-> yac#get_hover_popup_id() != -1}, a:timeout_ms)
endfunction

" 等待 picker 打开（精确判断，不被 toast 干扰）
function! yac_test#wait_picker(timeout_ms) abort
  return yac_test#wait_for({-> yac#picker_is_open()}, a:timeout_ms)
endfunction

" 等待 picker 关闭
function! yac_test#wait_picker_closed(timeout_ms) abort
  return yac_test#wait_for({-> !yac#picker_is_open()}, a:timeout_ms)
endfunction

" 清除所有 yac popup（包括重置内部 popup id 状态）
function! yac_test#clear_popups() abort
  call popup_clear()
  silent! call yac#close_hover()
  silent! call yac#close_signature()
endfunction

" 获取 hover popup 内容（精确定位，不会拿到 toast 内容）
function! yac_test#get_hover_content() abort
  let l:pid = yac#get_hover_popup_id()
  if l:pid == -1
    return ''
  endif
  let l:bufnr = winbufnr(l:pid)
  if l:bufnr <= 0
    return ''
  endif
  return join(getbufline(l:bufnr, 1, '$'), "\n")
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

" 日志输出（silent echom 写入 :messages，不显示在屏幕上，避免 -- More --）
function! s:log(level, message) abort
  let timestamp = strftime('%H:%M:%S')
  let prefix = '[' . timestamp . '] [' . a:level . '] '
  silent echom prefix . a:message
endfunction

" 公开日志函数
function! yac_test#log(level, message) abort
  call s:log(a:level, a:message)
endfunction

" 检测 Vim 运行时错误
" ignore_patterns: channel 关闭时的异步竞争条件（E716 channel_pool）
let s:errmsg_ignore = [
      \ 'E716:.*channel_pool',
      \ 'E716:.*"local"',
      \ 'LSP server.*not found',
      \ ]

function! yac_test#check_errors() abort
  if !empty(v:errmsg)
    let l:ignore = 0
    for pat in s:errmsg_ignore
      if v:errmsg =~# pat
        let l:ignore = 1
        break
      endif
    endfor
    if !l:ignore
      call s:record_fail('Vim error detected', v:errmsg)
    endif
    let v:errmsg = ''
  endif
endfunction

" 跳过测试
function! yac_test#skip(description, reason) abort
  call add(s:test_results, {'name': a:description, 'status': 'skip', 'reason': a:reason})
  call s:log('SKIP', a:description . ' - ' . a:reason)
endfunction

" ----------------------------------------------------------------------------
" 测试装置 (Fixtures)
" ----------------------------------------------------------------------------

" 启用批量模式：所有测试共享一个 Vim session + LSP
function! yac_test#set_batch_mode() abort
  let s:batch_mode = 1
endfunction

" 设置测试环境
function! yac_test#setup() abort
  set noswapfile
  set nobackup
  set nowritebackup
  set hidden
  " 抑制 "Press ENTER" 提示和文件信息消息
  set cmdheight=10
  set shortmess+=F

  " 启动 YAC（ensure_job 内部是幂等的）
  if exists(':YacStart')
    YacStart
  endif
endfunction

" 清理测试环境
function! yac_test#teardown() abort
  " 检测测试过程中的 Vim 错误
  call yac_test#check_errors()

  " 关闭所有 popup
  call popup_clear()

  " 批量模式下不停止 YAC，由 finish() 负责
  if !s:batch_mode && exists(':YacStop')
    silent! YacStop
    " YacStop 可能触发 v:errmsg（异步回调竞争），不算测试失败
    let v:errmsg = ''
  endif
endfunction

" 批量模式结束：停止 YAC
function! yac_test#finish() abort
  if exists(':YacStop')
    silent! YacStop
  endif
endfunction

" 重置 LSP 就绪标志（用于 YacStop/YacStart 测试场景）
function! yac_test#reset_lsp_ready() abort
  let s:lsp_ready = 0
  let g:yac_lsp_status = {}
endfunction

" 打开测试文件并等待 LSP
function! yac_test#open_test_file(file, wait_ms) abort
  execute 'edit! ' . a:file
  " 发送 file_open 触发 LSP 初始化
  if exists('*yac#open_file')
    call yac#open_file()
  endif
  call yac_test#wait_lsp_ready(a:wait_ms)
endfunction
