" yac_autopairs.vim — Auto bracket/quote pairing

let s:pairs = {'(': ')', '[': ']', '{': '}'}
let s:quotes = {'"': '"', "'": "'"}
let s:closers = {')': '(', ']': '[', '}': '{'}

function! yac_autopairs#open(open) abort
  if !get(g:, 'yac_auto_pairs', 1)
    return a:open
  endif
  let l:close = s:pairs[a:open]
  return a:open . l:close . "\<Left>"
endfunction

function! yac_autopairs#close(close) abort
  if !get(g:, 'yac_auto_pairs', 1)
    return a:close
  endif
  " If next char is the same closer, skip over it
  let l:next = getline('.')[col('.') - 1]
  if l:next ==# a:close
    return "\<Right>"
  endif
  return a:close
endfunction

function! yac_autopairs#quote(q) abort
  if !get(g:, 'yac_auto_pairs', 1)
    return a:q
  endif
  let l:next = getline('.')[col('.') - 1]
  " Skip over if next char is the same quote
  if l:next ==# a:q
    return "\<Right>"
  endif
  " Don't pair inside a word (e.g. it's)
  let l:prev = col('.') >= 2 ? getline('.')[col('.') - 2] : ''
  if l:prev =~# '\w'
    return a:q
  endif
  return a:q . a:q . "\<Left>"
endfunction

function! yac_autopairs#bs() abort
  if !get(g:, 'yac_auto_pairs', 1)
    return "\<BS>"
  endif
  let l:col = col('.')
  if l:col < 2
    return "\<BS>"
  endif
  let l:line = getline('.')
  let l:prev = l:line[l:col - 2]
  let l:next = l:col <= len(l:line) ? l:line[l:col - 1] : ''
  " If cursor is between a matched pair, delete both
  if (has_key(s:pairs, l:prev) && s:pairs[l:prev] ==# l:next)
        \ || (has_key(s:quotes, l:prev) && l:prev ==# l:next)
    return "\<BS>\<Del>"
  endif
  return "\<BS>"
endfunction

function! yac_autopairs#setup() abort
  if !get(g:, 'yac_auto_pairs', 1)
    return
  endif
  " Brackets
  for [open, close] in items(s:pairs)
    execute printf('inoremap <expr><buffer> %s yac_autopairs#open(%s)',
          \ open, string(open))
    execute printf('inoremap <expr><buffer> %s yac_autopairs#close(%s)',
          \ close, string(close))
  endfor
  " Quotes
  for q in keys(s:quotes)
    execute printf('inoremap <expr><buffer> %s yac_autopairs#quote(%s)',
          \ q, string(q))
  endfor
  " Backspace
  inoremap <expr><buffer> <BS> yac_autopairs#bs()
endfunction
