" ============================================================================
" YAC E2E Test Driver — term_start mode
" ============================================================================
" 外层 Vim 用 term_start() 启动内层 Vim，等待测试完成，
" 失败时 dump 屏幕快照。
"
" 环境变量:
"   YAC_TEST_FILE     — 测试脚本路径
"   YAC_TEST_OUTPUT   — 结果输出文件
"   YAC_TEST_SIGNAL   — 完成信号文件
"   YAC_TEST_SCREEN   — 屏幕快照输出文件
"   YAC_DRIVER_TIMEOUT — 超时时间（毫秒）
"   YAC_DRIVER_VIMRC  — 内层 Vim 的 vimrc 路径
"   YAC_DRIVER_CWD    — 内层 Vim 的工作目录
" ============================================================================

let s:test_file = $YAC_TEST_FILE
let s:output_file = $YAC_TEST_OUTPUT
let s:signal_file = $YAC_TEST_SIGNAL
let s:screen_file = $YAC_TEST_SCREEN
let s:timeout_ms = str2nr($YAC_DRIVER_TIMEOUT)
let s:vimrc = $YAC_DRIVER_VIMRC
let s:cwd = $YAC_DRIVER_CWD

if s:timeout_ms <= 0
  let s:timeout_ms = 120000
endif

" 清理残留信号文件
if filereadable(s:signal_file)
  call delete(s:signal_file)
endif

" 构建内层 Vim 命令
let s:inner_cmd = ['vim', '-N', '-u', s:vimrc, '-U', 'NONE',
      \ '-c', 'set noswapfile',
      \ '-c', 'set nobackup',
      \ '-c', 'source ' . s:test_file]

" 启动内层 Vim
let s:buf = term_start(s:inner_cmd, {
      \ 'term_rows': 24,
      \ 'term_cols': 80,
      \ 'term_finish': 'open',
      \ 'cwd': s:cwd,
      \ })

if s:buf <= 0
  call writefile(['::YAC_TEST_RESULT::{"suite":"driver","failed":1,"passed":0,"success":false,"tests":[{"name":"term_start","status":"fail","reason":"Failed to start inner Vim"}]}'], s:output_file)
  if !empty(s:signal_file)
    call writefile(['DONE'], s:signal_file)
  endif
  qa!
endif

" 等待内层 Vim 完成
let s:elapsed = 0
let s:poll_interval = 500

while s:elapsed < s:timeout_ms
  call term_wait(s:buf, s:poll_interval)
  let s:elapsed += s:poll_interval

  " 检查信号文件（内层测试完成后写入）
  if filereadable(s:signal_file)
    " 给内层一点时间完成写入
    call term_wait(s:buf, 200)
    break
  endif

  " 检查内层 Vim 是否已退出
  if term_getstatus(s:buf) !~# 'running'
    break
  endif
endwhile

" 如果超时且内层仍在运行
let s:timed_out = 0
if s:elapsed >= s:timeout_ms && !filereadable(s:signal_file)
  let s:timed_out = 1
endif

" 检查结果，如果有失败或超时就 dump 屏幕
let s:need_dump = s:timed_out
if !s:timed_out && filereadable(s:output_file)
  let s:result_text = join(readfile(s:output_file), '')
  if s:result_text =~# '"failed":\s*[1-9]' || s:result_text =~# '"success":\s*false'
    let s:need_dump = 1
  endif
endif

" 超时时写一个错误结果
if s:timed_out && !filereadable(s:output_file)
  let s:timeout_result = '::YAC_TEST_RESULT::{"suite":"driver","failed":1,"passed":0,"success":false,"tests":[{"name":"timeout","status":"fail","reason":"Driver timed out after ' . s:timeout_ms . 'ms"}]}'
  call writefile([s:timeout_result], s:output_file)
endif

" Dump 屏幕快照
if s:need_dump && !empty(s:screen_file)
  let s:screen = []
  for s:i in range(1, 24)
    let s:line = term_getline(s:buf, s:i)
    call add(s:screen, printf('%2d|%s', s:i, s:line))
  endfor
  call writefile(s:screen, s:screen_file)
endif

" 终止内层 Vim（如果还在运行）
if term_getstatus(s:buf) =~# 'running'
  call term_sendkeys(s:buf, "\<C-\>\<C-N>:qa!\<CR>")
  call term_wait(s:buf, 1000)
  " 如果还没退出就强杀
  if term_getstatus(s:buf) =~# 'running'
    let s:job = term_getjob(s:buf)
    if type(s:job) == v:t_job
      call job_stop(s:job, 'kill')
    endif
  endif
endif

qa!
