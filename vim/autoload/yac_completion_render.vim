" yac_completion_render.vim — Completion popup rendering, highlights, doc popup
"
" Dependencies:
"   yac_completion#_get_state()        — reference to s:completion dict
"   yac_completion#_normalize_kind()   — kind normalization
"   yac_completion#_filter()           — popup key filter (for popup_create)
"   yac_lsp#apply_ts_highlights_to_buffer()

" === Constants (render-only) ===

let s:completion_icons = {
  \ 'Function': '󰊕 ',
  \ 'Method': '󰊕 ',
  \ 'Variable': '󰀫 ',
  \ 'Field': '󰆧 ',
  \ 'TypeParameter': '󰅲 ',
  \ 'Constant': '󰏿 ',
  \ 'Class': '󰠱 ',
  \ 'Interface': '󰜰 ',
  \ 'Struct': '󰌗 ',
  \ 'Enum': ' ',
  \ 'EnumMember': ' ',
  \ 'Module': '󰆧 ',
  \ 'Property': '󰜢 ',
  \ 'Unit': '󰑭 ',
  \ 'Value': '󰎠 ',
  \ 'Keyword': '󰌋 ',
  \ 'Snippet': '󰅴 ',
  \ 'Text': '󰉿 ',
  \ 'File': '󰈙 ',
  \ 'Reference': '󰈇 ',
  \ 'Folder': '󰉋 ',
  \ 'Color': '󰏘 ',
  \ 'Constructor': '󰆧 ',
  \ 'Operator': '󰆕 ',
  \ 'Event': '󱐋 ',
  \ }

let s:completion_kind_highlights = {
  \ 'Function': 'YacCompletionFunction',
  \ 'Method': 'YacCompletionFunction',
  \ 'Constructor': 'YacCompletionFunction',
  \ 'Variable': 'YacCompletionVariable',
  \ 'Field': 'YacCompletionVariable',
  \ 'Property': 'YacCompletionVariable',
  \ 'Constant': 'YacCompletionVariable',
  \ 'Struct': 'YacCompletionStruct',
  \ 'Class': 'YacCompletionStruct',
  \ 'Interface': 'YacCompletionStruct',
  \ 'Enum': 'YacCompletionStruct',
  \ 'EnumMember': 'YacCompletionStruct',
  \ 'TypeParameter': 'YacCompletionStruct',
  \ 'Keyword': 'YacCompletionKeyword',
  \ 'Module': 'YacCompletionModule',
  \ 'Snippet': 'YacCompletionKeyword',
  \ }

" === Public API ===

" Render completion popup: format lines, create/update popup, apply highlights
function! yac_completion_render#render(state) abort
  let lines = map(copy(a:state.items), {_, item -> s:format_item(item)})
  call s:create_or_update_popup(a:state, lines)
  call s:apply_highlights(a:state)
  call yac_completion_render#highlight_selected(a:state)
  call s:show_doc(a:state)
endfunction

" Move cursorline to the selected item
function! yac_completion_render#highlight_selected(state) abort
  if a:state.popup_id == -1 | return | endif
  let lnum = a:state.selected + 1
  call win_execute(a:state.popup_id, 'noautocmd call cursor(' . lnum . ', 1)')
endfunction

" Show documentation popup for currently selected item
function! yac_completion_render#show_doc(state) abort
  call s:show_doc(a:state)
endfunction

" Close documentation popup
function! yac_completion_render#close_doc(state) abort
  if a:state.doc_popup_id != -1 && exists('*popup_close')
    call popup_close(a:state.doc_popup_id)
    let a:state.doc_popup_id = -1
  endif
endfunction

" === Internal: Item Formatting ===

function! s:format_item(item) abort
  let kind_str = yac_completion#_normalize_kind(get(a:item, 'kind', ''))
  let icon = get(s:completion_icons, kind_str, '󰉿 ')
  let label = a:item.label
  let display = icon . label

  if has_key(a:item, 'detail') && !empty(a:item.detail)
    let detail = substitute(a:item.detail, '[\n\r].*', '', '')
    let label_width = strdisplaywidth(display)
    let detail_col = max([label_width + 2, 30])
    let pad = detail_col - label_width
    let max_detail_width = 70 - detail_col
    if max_detail_width > 3 && strdisplaywidth(detail) > max_detail_width
      let detail = s:truncate_display(detail, max_detail_width - 3) . '...'
    endif
    if max_detail_width > 3
      let display .= repeat(' ', pad) . detail
    endif
  endif

  return display
endfunction

function! s:truncate_display(str, max_width) abort
  let result = ''
  let width = 0
  for char in split(a:str, '\zs')
    let cw = strdisplaywidth(char)
    if width + cw > a:max_width
      break
    endif
    let result .= char
    let width += cw
  endfor
  return result
endfunction

" === Internal: Highlights ===

function! s:ensure_prop_types(bufnr) abort
  for [kind, hl] in items(s:completion_kind_highlights)
    let type_name = 'yac_ck_' . kind
    try
      call prop_type_add(type_name, {'highlight': hl, 'bufnr': a:bufnr, 'priority': 10})
    catch /E969/
    endtry
  endfor
  try
    call prop_type_add('yac_match', {'highlight': 'YacBridgeMatchChar', 'bufnr': a:bufnr, 'priority': 20, 'combine': 0})
  catch /E969/
  endtry
  try
    call prop_type_add('yac_detail', {'highlight': 'YacCompletionDetail', 'bufnr': a:bufnr, 'priority': 5})
  catch /E969/
  endtry
endfunction

function! s:apply_highlights(state) abort
  if a:state.popup_id == -1 | return | endif
  let bufnr = winbufnr(a:state.popup_id)
  if bufnr == -1 | return | endif

  call prop_clear(1, len(a:state.items), {'bufnr': bufnr})
  call s:ensure_prop_types(bufnr)

  let lnum = 1
  for item in a:state.items
    let kind_str = yac_completion#_normalize_kind(get(item, 'kind', ''))
    let hl_type = get(s:completion_kind_highlights, kind_str, '')

    let icon = get(s:completion_icons, kind_str, '󰉿 ')
    let icon_bytes = strlen(icon)
    let label_bytes = strlen(item.label)

    " 1. icon + label colored by kind
    if !empty(hl_type)
      call prop_add(lnum, 1, {
        \ 'type': 'yac_ck_' . kind_str,
        \ 'length': icon_bytes + label_bytes,
        \ 'bufnr': bufnr
        \ })
    endif

    " 2. fuzzy match character highlights (merge consecutive runs)
    if has_key(item, '_match_positions') && !empty(item._match_positions)
      let l:label = item.label
      let l:positions = item._match_positions
      let l:i = 0
      while l:i < len(l:positions)
        let l:char_start = l:positions[l:i]
        let l:run = 1
        while l:i + l:run < len(l:positions) && l:positions[l:i + l:run] == l:char_start + l:run
          let l:run += 1
        endwhile
        let l:byte_start = byteidx(l:label, l:char_start)
        let l:byte_end = byteidx(l:label, l:char_start + l:run)
        if l:byte_start >= 0 && l:byte_end >= 0
          call prop_add(lnum, icon_bytes + l:byte_start + 1, {
            \ 'type': 'yac_match',
            \ 'length': l:byte_end - l:byte_start,
            \ 'bufnr': bufnr
            \ })
        endif
        let l:i += l:run
      endwhile
    endif

    " 3. detail gray highlight
    let display = s:format_item(item)
    if has_key(item, 'detail') && !empty(item.detail)
      let detail_text = item.detail
      if strdisplaywidth(detail_text) > 25
        let detail_text = s:truncate_display(detail_text, 22) . '...'
      endif
      let detail_start = stridx(display, detail_text, icon_bytes + label_bytes)
      if detail_start >= 0
        call prop_add(lnum, detail_start + 1, {
          \ 'type': 'yac_detail',
          \ 'length': strlen(detail_text),
          \ 'bufnr': bufnr
          \ })
      endif
    endif

    let lnum += 1
  endfor
endfunction

" === Internal: Popup Creation ===

function! s:popup_position(state) abort
  let screen_cursor_row = screenrow()
  let popup_height = min([len(a:state.items), 10])
  let space_below = &lines - screen_cursor_row - 1
  if space_below >= popup_height
    return {'line': screen_cursor_row + 1, 'pos': 'topleft'}
  else
    return {'line': screen_cursor_row - 1, 'pos': 'botleft'}
  endif
endfunction

function! s:create_or_update_popup(state, lines) abort
  if !exists('*popup_create')
    echo "Completions: " . join(a:lines, " | ")
    return
  endif

  if a:state.popup_id != -1
    call popup_settext(a:state.popup_id, a:lines)
    call popup_move(a:state.popup_id, {
      \ 'col': a:state.trigger_col,
      \ })
    return
  endif

  let l:pos = s:popup_position(a:state)

  let opts = {
    \ 'line': l:pos.line,
    \ 'col': a:state.trigger_col,
    \ 'pos': l:pos.pos,
    \ 'fixed': 1,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'padding': [0,0,0,0],
    \ 'cursorline': 1,
    \ 'highlight': 'YacCompletionNormal',
    \ 'maxheight': 10,
    \ 'minwidth': 25,
    \ 'maxwidth': 70,
    \ 'zindex': 1000,
    \ 'filter': function('yac_completion#_filter'),
    \ }
  if has('patch-9.0.0')
    let opts['cursorlinehighlight'] = 'YacCompletionSelect'
  endif

  let a:state.popup_id = popup_create(a:lines, opts)
  call yac_completion_render#highlight_selected(a:state)
endfunction

" === Internal: Documentation Popup ===

function! s:show_doc(state) abort
  call yac_completion_render#close_doc(a:state)

  if !exists('*popup_create') || empty(a:state.items) || a:state.selected >= len(a:state.items)
    return
  endif

  let item = a:state.items[a:state.selected]

  let plain_lines = []
  if has_key(item, 'detail') && !empty(item.detail)
    call extend(plain_lines, split(item.detail, '\n'))
  endif
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(plain_lines)
      call add(plain_lines, '')
    endif
    let doc_raw = item.documentation
    if type(doc_raw) == v:t_dict && has_key(doc_raw, 'value')
      let doc_raw = doc_raw.value
    endif
    if type(doc_raw) == v:t_string
      call extend(plain_lines, split(doc_raw, '\n'))
    endif
  endif

  if empty(plain_lines)
    return
  endif

  call s:create_doc_popup(a:state, plain_lines)

  let md_parts = []
  if has_key(item, 'detail') && !empty(item.detail)
    call add(md_parts, '```' . &filetype)
    call add(md_parts, item.detail)
    call add(md_parts, '```')
  endif
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(md_parts) | call add(md_parts, '') | endif
    let doc_raw = item.documentation
    if type(doc_raw) == v:t_dict && has_key(doc_raw, 'value')
      let doc_raw = doc_raw.value
    endif
    if type(doc_raw) == v:t_string
      call extend(md_parts, split(doc_raw, '\n'))
    endif
  endif
  call yac#_request('ts_hover_highlight', {
    \ 'markdown': join(md_parts, "\n"),
    \ 'filetype': &filetype
    \ }, function('s:handle_doc_hl_response'))
endfunction

function! s:create_doc_popup(state, lines) abort
  let pos = popup_getpos(a:state.popup_id)
  if empty(pos) | return | endif

  let doc_min_width = 30
  let right_space = &columns - (pos.col + pos.width)
  let left_space = pos.col - 1

  if right_space >= doc_min_width + 2
    let doc_col = pos.col + pos.width + 1
    let doc_maxwidth = min([60, right_space - 2])
  elseif left_space >= doc_min_width + 2
    let doc_maxwidth = min([60, left_space - 2])
    let doc_col = max([1, pos.col - doc_maxwidth - 2])
  else
    return
  endif

  if a:state.doc_popup_id != -1
    call popup_settext(a:state.doc_popup_id, a:lines)
    call popup_move(a:state.doc_popup_id, {'col': doc_col})
    return
  endif

  let a:state.doc_popup_id = popup_create(a:lines, {
    \ 'line': pos.line,
    \ 'col': doc_col,
    \ 'pos': 'topleft',
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'padding': [0,1,0,1],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'minwidth': doc_min_width,
    \ 'maxwidth': doc_maxwidth,
    \ 'maxheight': 15,
    \ 'wrap': 1,
    \ 'zindex': 1001,
    \ })
endfunction

function! s:handle_doc_hl_response(channel, response) abort
  let l:state = yac_completion#_get_state()
  if l:state.popup_id == -1 || l:state.doc_popup_id == -1
    return
  endif
  if type(a:response) != v:t_dict || !has_key(a:response, 'lines') || empty(a:response.lines)
    return
  endif

  call popup_settext(l:state.doc_popup_id, a:response.lines)

  let l:highlights = get(a:response, 'highlights', {})
  if !empty(l:highlights)
    call yac_lsp#apply_ts_highlights_to_buffer(winbufnr(l:state.doc_popup_id), l:highlights)
  endif
endfunction
