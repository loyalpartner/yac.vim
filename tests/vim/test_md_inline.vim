call yac_test#begin('md_inline')
call yac_test#setup()

" Open Markdown file and enable tree-sitter highlights
call yac_test#open_test_file('test_data/src/test_md.md', 3000)

" Manually ensure both markdown and markdown_inline are loaded
if has_key(g:yac_lang_plugins, 'markdown')
  call yac#ensure_language(g:yac_lang_plugins.markdown)
endif
call yac#ts_highlights_enable()

" Wait for inline highlights on L16: **bold** and *italic*
" If injection works, bold/italic should have highlight props
let s:has_inline = yac_test#wait_for(
  \ {-> len(filter(prop_list(16), {_, p -> get(p, 'type', '') =~# '^yac_ts_'})) >= 1}, 10000)

" Collect all props for diagnostics
let s:total = 0
let s:diag = []
for lnum in range(1, line('$'))
  let props = filter(prop_list(lnum), {_, p -> get(p, 'type', '') =~# '^yac_ts_'})
  let s:total += len(props)
  if !empty(props)
    for p in props
      let hl = get(prop_type_get(p.type), 'highlight', '?')
      call add(s:diag, printf('L%d C%d len=%d: %s', lnum, p.col, p.length, hl))
    endfor
  endif
endfor

call yac_test#log('INFO', printf('inline_available=%d total_props=%d', s:has_inline, s:total))
for d in s:diag
  call yac_test#log('INFO', d)
endfor

" Block-level props should exist (headings, lists, quotes)
call yac_test#assert_true(s:total >= 5, 'Block-level highlights missing (got ' . s:total . ')')

" Inline injection should produce >10 highlights (bold, italic, code, links)
call yac_test#assert_true(s:has_inline, 'Inline highlights not detected on L16 (total=' . s:total . ')')
call yac_test#assert_true(s:total > 10, 'Inline highlights insufficient (got ' . s:total . ', expected >10)')

call yac#ts_highlights_disable()
call yac_test#teardown()
call yac_test#end()
