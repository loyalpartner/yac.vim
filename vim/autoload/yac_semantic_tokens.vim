" yac_semantic_tokens.vim — LSP Semantic Tokens highlighting
"
" Adds semantic-level highlighting that overlays tree-sitter syntax highlights.
" LSP servers provide richer info (e.g., distinguishing local vars from
" parameters, readonly from mutable) that tree-sitter alone cannot.
"
" Dependencies on yac.vim:
"   yac#_semantic_tokens_request(method, params, callback)
"   yac#_semantic_tokens_debug_log(msg)

" === State ===

" Per-buffer prop types for cleanup
" {bufnr: [prop_type_name, ...]}
let s:st_prop_types_created = {}

" Debounce timer
let s:st_debounce_timer = -1

" === Public API ===

" Request semantic tokens for the current buffer (full document).
function! yac_semantic_tokens#request() abort
  if !get(b:, 'yac_lsp_supported', 0) | return | endif
  if !get(g:, 'yac_semantic_tokens', 1) && !get(b:, 'yac_semantic_tokens', -1) | return | endif
  if get(b:, 'yac_semantic_tokens', -1) == 0 | return | endif

  let l:bufnr = bufnr('%')
  let l:seq = get(b:, 'yac_st_seq', 0) + 1
  let b:yac_st_seq = l:seq

  call yac#_semantic_tokens_request('semantic_tokens', {
    \   'file': expand('%:p'),
    \ }, {ch, resp -> yac_semantic_tokens#_handle_response(
    \     ch, resp, l:seq, l:bufnr)})
endfunction

" Debounced request (called from autocmd after text changes).
function! yac_semantic_tokens#request_debounce() abort
  if !get(b:, 'yac_lsp_supported', 0) | return | endif
  if !get(g:, 'yac_semantic_tokens', 1) && !get(b:, 'yac_semantic_tokens', -1) | return | endif
  if get(b:, 'yac_semantic_tokens', -1) == 0 | return | endif

  if s:st_debounce_timer >= 0
    call timer_stop(s:st_debounce_timer)
  endif
  let s:st_debounce_timer = timer_start(500, {-> yac_semantic_tokens#request()})
endfunction

" Toggle semantic tokens for the current buffer.
function! yac_semantic_tokens#toggle() abort
  let b:yac_semantic_tokens = !get(b:, 'yac_semantic_tokens',
        \ get(g:, 'yac_semantic_tokens', 1))
  if b:yac_semantic_tokens
    call yac_semantic_tokens#request()
    echo '[yac] Semantic tokens enabled'
  else
    call yac_semantic_tokens#clear()
    echo '[yac] Semantic tokens disabled'
  endif
endfunction

" Clear all semantic token highlights from the current buffer.
function! yac_semantic_tokens#clear() abort
  let l:bufnr = bufnr('%')
  let l:types = getbufvar(l:bufnr, 'yac_st_prop_types', [])
  for l:t in l:types
    silent! call prop_remove({'type': l:t, 'bufnr': l:bufnr, 'all': 1})
  endfor
  call setbufvar(l:bufnr, 'yac_st_prop_types', [])
endfunction

" === Response Handler (callback) ===

function! yac_semantic_tokens#_handle_response(channel, response, seq, bufnr) abort
  call yac#_semantic_tokens_debug_log(printf(
        \ '[RECV]: semantic_tokens response (seq=%d, bufnr=%d)', a:seq, a:bufnr))

  " Discard stale responses
  if a:seq != getbufvar(a:bufnr, 'yac_st_seq', 0)
    return
  endif

  if !bufexists(a:bufnr)
    return
  endif

  if yac_picker#is_open()
    return
  endif

  if type(a:response) != v:t_dict || !has_key(a:response, 'highlights')
    return
  endif

  " Double-buffered generation swap (same pattern as tree-sitter highlights)
  let l:old_gen = getbufvar(a:bufnr, 'yac_st_gen', 0)
  let l:new_gen = 1 - l:old_gen
  let l:old_types = getbufvar(a:bufnr, 'yac_st_prop_types', [])

  let l:new_types = s:apply_semantic_highlights(l:new_gen, a:response.highlights, a:bufnr)

  " Remove old generation's properties
  for l:t in l:old_types
    silent! call prop_remove({'type': l:t, 'bufnr': a:bufnr, 'all': 1})
  endfor

  call setbufvar(a:bufnr, 'yac_st_gen', l:new_gen)
  call setbufvar(a:bufnr, 'yac_st_prop_types', l:new_types)
endfunction

" === Internal ===

" Apply highlights for a generation. Returns list of prop type names used.
function! s:apply_semantic_highlights(gen, highlights, bufnr) abort
  let l:types = []
  for [l:group, l:positions] in items(a:highlights)
    let l:prop_type = 'yac_st_' . a:gen . '_' . l:group
    call s:ensure_prop_type(l:prop_type, l:group)
    call add(l:types, l:prop_type)
    if !empty(l:positions)
      try
        call prop_add_list({'type': l:prop_type, 'bufnr': a:bufnr}, l:positions)
      catch
      endtry
    endif
  endfor
  return l:types
endfunction

" Ensure a prop type exists for a given highlight group.
function! s:ensure_prop_type(prop_type, highlight_group) abort
  if !has_key(s:st_prop_types_created, a:prop_type)
    try
      " Higher priority than tree-sitter (default priority=0, semantic=10)
      call prop_type_add(a:prop_type, {
            \ 'highlight': a:highlight_group,
            \ 'priority': 10,
            \ 'start_incl': 1,
            \ 'end_incl': 1
            \ })
    catch /E969/
      " Already exists
    endtry
    let s:st_prop_types_created[a:prop_type] = 1
  endif
endfunction
