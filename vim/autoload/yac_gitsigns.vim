" yac_gitsigns.vim — Git diff signs in the sign column

let s:sign_group = 'yac_git'
let s:debounce_timer = -1

" Parse a unified diff hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
function! yac_gitsigns#parse_hunk_header(line) abort
  let l:m = matchlist(a:line, '@@ -\(\d\+\)\%(,\(\d\+\)\)\? +\(\d\+\)\%(,\(\d\+\)\)\? @@')
  if empty(l:m)
    return {}
  endif
  return {
    \ 'old_start': str2nr(l:m[1]),
    \ 'old_count': empty(l:m[2]) ? 1 : str2nr(l:m[2]),
    \ 'new_start': str2nr(l:m[3]),
    \ 'new_count': empty(l:m[4]) ? 1 : str2nr(l:m[4]),
    \ }
endfunction

" Convert unified diff output lines to a list of sign entries.
" Each entry: {'lnum': N, 'type': 'add'|'delete'|'change'}
function! yac_gitsigns#diff_to_signs(diff_lines) abort
  let l:signs = []
  let l:new_line = 0
  let l:adds = []
  let l:dels = []

  for l:line in a:diff_lines
    if l:line =~# '^@@'
      " Flush previous hunk
      call s:flush_hunk(l:signs, l:adds, l:dels)
      let l:adds = []
      let l:dels = []
      let l:hdr = yac_gitsigns#parse_hunk_header(l:line)
      if empty(l:hdr) | continue | endif
      let l:new_line = l:hdr.new_start
    elseif l:line[0] ==# '+'
      call add(l:adds, l:new_line)
      let l:new_line += 1
    elseif l:line[0] ==# '-'
      call add(l:dels, l:new_line)
    else
      " Context line — flush and advance
      call s:flush_hunk(l:signs, l:adds, l:dels)
      let l:adds = []
      let l:dels = []
      let l:new_line += 1
    endif
  endfor

  call s:flush_hunk(l:signs, l:adds, l:dels)
  return l:signs
endfunction

function! s:flush_hunk(signs, adds, dels) abort
  if empty(a:adds) && empty(a:dels)
    return
  endif

  " If both adds and dels in same region → change
  let l:n_change = min([len(a:adds), len(a:dels)])
  for l:i in range(l:n_change)
    call add(a:signs, {'lnum': a:adds[l:i], 'type': 'change'})
  endfor

  " Remaining adds
  for l:i in range(l:n_change, len(a:adds) - 1)
    call add(a:signs, {'lnum': a:adds[l:i], 'type': 'add'})
  endfor

  " Remaining dels (mark at the line where deletion happened)
  if len(a:dels) > l:n_change
    let l:del_lnum = empty(a:adds) ? a:dels[0] : a:adds[-1]
    call add(a:signs, {'lnum': l:del_lnum, 'type': 'delete'})
  endif
endfunction

" Define sign types
function! yac_gitsigns#define_signs() abort
  sign define YacGitAdd    text=│ texthl=DiffAdd
  sign define YacGitDelete text=_ texthl=DiffDelete
  sign define YacGitChange text=│ texthl=DiffChange
endfunction

" Place signs in the current buffer from sign data
function! yac_gitsigns#place_signs(bufnr, signs) abort
  " Clear old signs
  call sign_unplace(s:sign_group, {'buffer': a:bufnr})

  let l:sign_map = {'add': 'YacGitAdd', 'delete': 'YacGitDelete', 'change': 'YacGitChange'}
  let l:id = 1
  for l:s in a:signs
    let l:name = get(l:sign_map, l:s.type, '')
    if !empty(l:name)
      call sign_place(l:id, s:sign_group, l:name, a:bufnr, {'lnum': l:s.lnum})
      let l:id += 1
    endif
  endfor
endfunction

" Get diff for a file and update signs
function! yac_gitsigns#update() abort
  let l:file = expand('%:p')
  if empty(l:file) || !filereadable(l:file)
    return
  endif

  " Check if file is in a git repo
  let l:git_dir = finddir('.git', fnamemodify(l:file, ':h') . ';')
  if empty(l:git_dir)
    return
  endif

  let l:dir = fnamemodify(l:file, ':h')
  let l:diff = systemlist('cd ' . shellescape(l:dir) . ' && git diff --no-color -U0 -- ' . shellescape(l:file))
  if v:shell_error != 0
    return
  endif

  let l:signs = yac_gitsigns#diff_to_signs(l:diff)
  call yac_gitsigns#place_signs(bufnr('%'), l:signs)
endfunction

" Debounced update
function! yac_gitsigns#update_debounce() abort
  if !get(g:, 'yac_git_signs', 1)
    return
  endif
  if s:debounce_timer != -1
    call timer_stop(s:debounce_timer)
  endif
  let s:debounce_timer = timer_start(200, {-> yac_gitsigns#update()})
endfunction
