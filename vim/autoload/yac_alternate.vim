" yac_alternate.vim — C/C++ header/implementation file switching

" Extension → candidate alternates (in priority order)
let s:alternates = {
  \ 'c':   ['h'],
  \ 'cpp': ['hpp', 'h', 'hxx', 'hh'],
  \ 'cc':  ['hh', 'h', 'hpp', 'hxx'],
  \ 'cxx': ['hxx', 'h', 'hpp', 'hh'],
  \ 'h':   ['c', 'cpp', 'cc', 'cxx'],
  \ 'hpp': ['cpp', 'cc', 'cxx'],
  \ 'hh':  ['cc', 'cpp', 'cxx'],
  \ 'hxx': ['cxx', 'cpp', 'cc'],
  \ }

function! yac_alternate#switch() abort
  let ext = expand('%:e')
  if !has_key(s:alternates, ext)
    echohl WarningMsg | echo 'yac: not a C/C++ file' | echohl None
    return
  endif

  let base = expand('%:p:r')
  for candidate_ext in s:alternates[ext]
    let candidate = base . '.' . candidate_ext
    if filereadable(candidate)
      execute 'edit ' . fnameescape(candidate)
      return
    endif
  endfor

  echohl WarningMsg | echo 'yac: no alternate file found' | echohl None
endfunction
