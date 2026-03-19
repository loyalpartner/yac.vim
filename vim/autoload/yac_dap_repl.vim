" yac_dap_repl.vim — REPL buffer (create, append output, handle input)
"
" Public API:
"   yac_dap_repl#create()
"   yac_dap_repl#append(text, category)

" Create and open the DAP REPL scratch buffer in a bottom split.
function! yac_dap_repl#create() abort
  execute 'botright 10new'
  let g:_yac_dap.repl_bufnr = bufnr('%')
  setlocal buftype=nofile bufhidden=hide noswapfile nomodeline
  setlocal filetype=yac_dap_repl
  setlocal statusline=%#YacDapTitle#\ DAP\ REPL\ %#StatusLine#
  setlocal winfixheight
  setlocal modifiable

  file [DAP REPL]

  " REPL prop types for colored output
  for [name, hl] in [
        \ ['YacDapReplPrompt', 'YacDapReplPrompt'],
        \ ['YacDapReplOutput', 'YacDapReplOutput'],
        \ ['YacDapReplError',  'YacDapReplError'],
        \ ]
    if empty(prop_type_get(name, {'bufnr': g:_yac_dap.repl_bufnr}))
      call prop_type_add(name, {'highlight': hl, 'combine': 1, 'bufnr': g:_yac_dap.repl_bufnr})
    endif
  endfor

  " Add prompt line
  call setbufline(g:_yac_dap.repl_bufnr, '$', '> ')

  " REPL input mappings — <SID> resolves to this script's s:submit
  nnoremap <buffer> <CR> :call <SID>submit()<CR>
  inoremap <buffer> <CR> <Esc>:call <SID>submit()<CR>

  " Return to previous window
  wincmd p
endfunction

" Append a line of output to the REPL buffer with category-based highlighting.
function! yac_dap_repl#append(text, category) abort
  if g:_yac_dap.repl_bufnr <= 0 || !bufexists(g:_yac_dap.repl_bufnr)
    return
  endif

  let lines = split(a:text, "\n", 1)
  for line in lines
    if empty(line) | continue | endif
    call appendbufline(g:_yac_dap.repl_bufnr, '$', line)
    let lnum = getbufinfo(g:_yac_dap.repl_bufnr)[0].linecount

    let hl_type = 'YacDapReplOutput'
    if a:category ==# 'stderr' || a:category ==# 'error'
      let hl_type = 'YacDapReplError'
    elseif a:category ==# 'result'
      let hl_type = 'YacDapReplPrompt'
    endif
    call prop_add(lnum, 1, {
          \ 'length': len(line), 'type': hl_type, 'bufnr': g:_yac_dap.repl_bufnr})
  endfor

  " Auto-scroll all REPL windows
  for winid in win_findbuf(g:_yac_dap.repl_bufnr)
    call win_execute(winid, 'normal! G')
  endfor
endfunction

" Handle <CR> in the REPL buffer: submit the current line as an expression.
function! s:submit() abort
  if g:_yac_dap.repl_bufnr <= 0 || !bufexists(g:_yac_dap.repl_bufnr)
    return
  endif
  let last_line = getbufline(g:_yac_dap.repl_bufnr, '$')[0]
  let expr = substitute(last_line, '^>\s*', '', '')
  if empty(expr)
    return
  endif

  " Highlight the submitted line with prompt style
  let lnum = getbufinfo(g:_yac_dap.repl_bufnr)[0].linecount
  call prop_add(lnum, 1, {
        \ 'length': len(last_line), 'type': 'YacDapReplPrompt', 'bufnr': g:_yac_dap.repl_bufnr})

  " Add new prompt line
  call appendbufline(g:_yac_dap.repl_bufnr, '$', '> ')

  " Auto-scroll
  for winid in win_findbuf(g:_yac_dap.repl_bufnr)
    call win_execute(winid, 'normal! G')
  endfor

  " Send to daemon for evaluation
  if g:_yac_dap.dap_active
    call yac_dap#evaluate(expr)
  else
    call yac_dap_repl#append('Error: No active debug session', 'error')
  endif
endfunction
