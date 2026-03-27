" yac_picker_mru.vim — MRU (Most Recently Used) file persistence

let s:picker_mru = []

function! s:mru_file() abort
  return expand('~/.local/share/yac/history')
endfunction

function! yac_picker_mru#load() abort
  let f = s:mru_file()
  if filereadable(f)
    let s:picker_mru = readfile(f)
    let s:filtered = filter(copy(s:picker_mru), 'filereadable(v:val)')
    if len(s:filtered) < len(s:picker_mru)
      let s:picker_mru = s:filtered
      call yac_picker_mru#save()
    endif
  endif
endfunction

function! yac_picker_mru#save() abort
  let f = s:mru_file()
  let dir = fnamemodify(f, ':h')
  if !isdirectory(dir)
    call mkdir(dir, 'p')
  endif
  call writefile(s:picker_mru[:99], f)
endfunction

function! yac_picker_mru#get() abort
  return s:picker_mru
endfunction

function! yac_picker_mru#set(files) abort
  let s:picker_mru = a:files
endfunction

function! yac_picker_mru#update(target_file) abort
  if empty(a:target_file) | return | endif
  call filter(s:picker_mru, 'v:val !=# a:target_file')
  call insert(s:picker_mru, a:target_file, 0)
  if len(s:picker_mru) > 100
    call remove(s:picker_mru, 100, -1)
  endif
  call yac_picker_mru#save()
endfunction

function! yac_picker_mru#query(query) abort
  let items = []
  for f in s:picker_mru
    if !filereadable(f) | continue | endif
    let rel = fnamemodify(f, ':.')
    if empty(a:query) || stridx(tolower(rel), tolower(a:query)) >= 0
      call add(items, {'label': rel, 'file': f})
    endif
    if len(items) >= 50 | break | endif
  endfor
  return items
endfunction
