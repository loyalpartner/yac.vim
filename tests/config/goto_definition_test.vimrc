" Goto Definition E2E Test Configuration
set nocompatible
set runtimepath+=vim
set shortmess+=I
set nomore
set laststatus=0
set noshowmode
set noruler
set noshowcmd

" Load YAC plugin
runtime plugin/yac.vim
runtime autoload/yac.vim

" Configuration
let g:yac_debug = 1
let g:yac_auto_start = 0
let g:yac_server_host = '127.0.0.1'
let g:yac_server_port = 9527

" Test function for goto definition
function! RunGotoDefinitionTest()
  try
    " Start YAC
    call yac#start()
    sleep 2000m

    " Check connection
    if !yac#is_connected()
      call writefile(['FAILED:Cannot connect to YAC server'], 'goto_definition_result.tmp')
      return
    endif

    " Open test Rust file
    edit tests/fixtures/src/lib.rs

    " Test case 1: goto definition of 'add' function call
    " Position cursor on 'add' function call at line 59
    call cursor(59, 22)  " Position on 'add' in "let result = add(2, 2);"
    let initial_line = line('.')
    let initial_col = col('.')
    let initial_file = expand('%:t')

    " Trigger goto definition
    call yac#goto_definition()

    " Wait for response
    sleep 3000m

    " Check if we jumped to a different position
    let current_line = line('.')
    let current_col = col('.')
    let current_file = expand('%:t')

    " Success check - should jump to line 3 where 'add' function is defined
    if current_line == 3 && current_file == 'lib.rs'
      call writefile(['SUCCESS:Jumped to add function definition at line ' . current_line], 'goto_definition_result.tmp')
    elseif current_line != initial_line || current_col != initial_col
      call writefile(['PARTIAL:Position changed to ' . current_file . ':' . current_line . ':' . current_col . ' but not expected definition'], 'goto_definition_result.tmp')
    else
      call writefile(['FAILED:No position change after goto definition request'], 'goto_definition_result.tmp')
    endif

  catch
    call writefile(['ERROR:' . v:exception], 'goto_definition_result.tmp')
  finally
    call yac#stop()
  endtry
endfunction

" Auto-run test on startup
autocmd VimEnter * call RunGotoDefinitionTest()
