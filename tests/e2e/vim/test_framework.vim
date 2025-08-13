" 简单的Vim测试框架
" 用于YAC.vim的自动化测试

let s:test_results = {
    \ 'passed': 0,
    \ 'failed': 0,
    \ 'total': 0,
    \ 'failures': []
    \ }

let s:current_test = ''

" 初始化测试环境
function! InitTests() abort
  let s:test_results.passed = 0
  let s:test_results.failed = 0
  let s:test_results.total = 0
  let s:test_results.failures = []
  
  " 设置测试环境
  set nocompatible
  filetype off
  
  " 禁用插件，除了我们要测试的YAC
  let &runtimepath = expand('<sfile>:p:h:h') . '/vim,' . &runtimepath
  
  echo "=== YAC.vim 简单测试框架 ==="
  echo "测试开始时间: " . strftime('%Y-%m-%d %H:%M:%S')
  echo ""
endfunction

" 断言函数：相等比较
function! AssertEqual(expected, actual, message) abort
  if a:expected ==# a:actual
    call s:test_pass()
  else
    call s:test_fail(printf('%s: 期望 "%s", 实际 "%s"', a:message, a:expected, a:actual))
  endif
endfunction

" 断言函数：真值测试
function! AssertTrue(value, message) abort
  if a:value
    call s:test_pass()
  else
    call s:test_fail(a:message . ': 期望为真，实际为假')
  endif
endfunction

" 断言函数：假值测试
function! AssertFalse(value, message) abort
  if !a:value
    call s:test_pass()
  else
    call s:test_fail(a:message . ': 期望为假，实际为真')
  endif
endfunction

" 断言函数：非空测试
function! AssertNotEmpty(value, message) abort
  if !empty(a:value)
    call s:test_pass()
  else
    call s:test_fail(a:message . ': 期望非空，实际为空')
  endif
endfunction

" 运行单个测试函数
function! RunTest(test_name) abort
  let s:current_test = a:test_name
  let s:test_results.total += 1
  
  echo printf("运行测试: %s", a:test_name)
  
  try
    " 执行测试函数
    execute 'call ' . a:test_name . '()'
    echo printf("✅ %s: PASS", a:test_name)
  catch
    call s:test_fail(printf("测试执行异常: %s", v:exception))
    echo printf("❌ %s: FAIL - %s", a:test_name, v:exception)
  endtry
  
  echo ""
endfunction

" 运行所有测试
function! RunAllTests(test_functions) abort
  call InitTests()
  
  for test_func in a:test_functions
    call RunTest(test_func)
    " 短暂停顿，避免测试过快
    sleep 100m
  endfor
  
  call ShowTestResults()
endfunction

" 显示测试结果
function! ShowTestResults() abort
  echo "=== 测试结果汇总 ==="
  echo printf("总计: %d 个测试", s:test_results.total)
  echo printf("通过: %d 个", s:test_results.passed)
  echo printf("失败: %d 个", s:test_results.failed)
  
  if s:test_results.failed > 0
    echo ""
    echo "失败详情:"
    for failure in s:test_results.failures
      echo "  - " . failure
    endfor
  endif
  
  echo ""
  echo "测试结束时间: " . strftime('%Y-%m-%d %H:%M:%S')
  
  if s:test_results.failed == 0
    echo "🎉 所有测试通过!"
    return 0
  else
    echo "❌ 有测试失败"
    return 1
  endif
endfunction

" 内部函数：测试通过
function! s:test_pass() abort
  let s:test_results.passed += 1
endfunction

" 内部函数：测试失败
function! s:test_fail(message) abort
  let s:test_results.failed += 1
  let failure_msg = printf('[%s] %s', s:current_test, a:message)
  call add(s:test_results.failures, failure_msg)
endfunction

" 辅助函数：等待条件成立或超时
function! WaitFor(condition, timeout_ms) abort
  let start_time = reltime()
  while !eval(a:condition)
    if str2float(reltimestr(reltime(start_time))) * 1000 > a:timeout_ms
      return 0
    endif
    sleep 50m
  endwhile
  return 1
endfunction

" 辅助函数：清理测试环境
function! CleanupTest() abort
  " 关闭所有缓冲区
  %bdelete!
  
  " 重置变量
  if exists('s:yac_channel')
    unlet s:yac_channel
  endif
  
  " 重置YAC状态
  try
    call yac#stop()
  catch
    " 忽略停止错误
  endtry
endfunction