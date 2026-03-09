" yac_folding.vim — Folding module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_folding_request(method, params, callback)  — send daemon request
"   yac#_folding_debug_log(msg)                      — debug logging
"   yac#toast(msg, ...)                              — toast notification

" === State ===

let s:fold_signs_defined = 0

" === Public API ===

function! yac_folding#range() abort
  let l:params = {'file': expand('%:p')}
  " Include text so daemon can auto-parse if buffer wasn't parsed yet
  " (e.g. load_language raced with file_open on different threads).
  if !exists('b:yac_fold_levels')
    let l:params.text = join(getline(1, '$'), "\n")
  endif
  call yac#_folding_request('ts_folding', l:params, 'yac_folding#_handle_response')
endfunction

function! yac_folding#foldexpr(lnum) abort
  if !exists('b:yac_fold_levels')
    return 0
  endif
  let level = get(b:yac_fold_levels, a:lnum, 0)
  if level > 0 && has_key(b:yac_fold_start_set, a:lnum)
    return '>' . level
  endif
  return level
endfunction

function! yac_folding#foldtext() abort
  let line = getline(v:foldstart)
  let hidden = max([v:foldend - v:foldstart, 1])
  return line . '  ' . hidden . ' lines'
endfunction

function! yac_folding#update_signs() abort
  if !exists('b:yac_fold_start_lines')
    return
  endif
  let l:state = {}
  for lnum in b:yac_fold_start_lines
    let l:state[lnum] = foldclosed(lnum) != -1 ? 'yac_fold_closed' : 'yac_fold_open'
  endfor
  if l:state ==# get(b:, 'yac_fold_sign_cache', {})
    return
  endif
  if !s:fold_signs_defined
    call sign_define('yac_fold_open',   {'text': '▾', 'texthl': 'FoldColumn'})
    call sign_define('yac_fold_closed', {'text': '▸', 'texthl': 'FoldColumn'})
    let s:fold_signs_defined = 1
  endif
  let bufnr = bufnr('%')
  call sign_unplace('yac_folds', {'buffer': bufnr})
  for [lnum, name] in items(l:state)
    call sign_place(0, 'yac_folds', name, bufnr, {'lnum': lnum})
  endfor
  let b:yac_fold_sign_cache = l:state
endfunction

" Test helper: inject mock ranges directly
function! yac_folding#apply_ranges_test(ranges) abort
  call s:apply_folding_ranges(a:ranges)
endfunction

" === Response Handler (callback) ===

function! yac_folding#_handle_response(channel, response) abort
  call yac#_folding_debug_log(printf('[RECV]: ts_folding response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" === Internal ===

function! s:apply_folding_ranges(ranges) abort
  if empty(a:ranges)
    call yac#toast('No folding ranges available')
    return
  endif

  let nlines = line('$')

  " Filter valid ranges
  let valid = filter(copy(a:ranges), {_, r ->
    \ r.start_line + 1 >= 1 && r.end_line + 1 <= nlines && r.start_line < r.end_line})

  " Sort by start_line ascending, end_line descending (same start: larger range first)
  call sort(valid, {a, b ->
    \ a.start_line != b.start_line
    \ ? a.start_line - b.start_line
    \ : b.end_line - a.end_line})

  " Remove redundant ranges: if a range's start/end differ from stack top by <=1,
  " treat as same fold level (e.g. function vs function body), skip it.
  let filtered = []
  let stack = []
  for r in valid
    while !empty(stack) && stack[-1].end_line < r.start_line
      call remove(stack, -1)
    endwhile
    if !empty(stack)
      let top = stack[-1]
      if abs(r.start_line - top.start_line) <= 1 && abs(r.end_line - top.end_line) <= 1
        continue
      endif
    endif
    call add(filtered, r)
    call add(stack, r)
  endfor

  " Difference array + prefix sum for per-line fold levels
  let levels = repeat([0], nlines + 2)
  for r in filtered
    let levels[r.start_line + 1] += 1
    let levels[r.end_line + 2] -= 1
  endfor
  let cur = 0
  for lnum in range(1, nlines)
    let cur += levels[lnum]
    let levels[lnum] = cur
  endfor

  let b:yac_fold_levels = levels
  let b:yac_fold_start_lines = map(copy(filtered), {_, r -> r.start_line + 1})
  let b:yac_fold_start_set = {}
  for lnum in b:yac_fold_start_lines
    let b:yac_fold_start_set[lnum] = 1
  endfor
  setlocal foldmethod=expr
  setlocal foldexpr=yac_folding#foldexpr(v:lnum)
  setlocal foldtext=yac_folding#foldtext()
  setlocal foldlevel=99
  if has('patch-8.2.1516') && &l:fillchars !~# 'fold: '
    let l:fc = substitute(&l:fillchars, ',\?fold:[^,]*', '', 'g')
    let l:fc = substitute(l:fc, '^,\+', '', '')
    let &l:fillchars = (empty(l:fc) ? '' : l:fc . ',') . 'fold: '
  endif
  setlocal foldcolumn=0

  call yac_folding#update_signs()
endfunction
