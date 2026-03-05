; Emphasis
(emphasis) @markup.italic
(strong_emphasis) @markup.bold
(strikethrough) @markup.strikethrough

; Code spans
(code_span) @markup.raw.inline

; Links
[
  (inline_link)
  (shortcut_link)
  (collapsed_reference_link)
  (full_reference_link)
  (image)
] @markup.link

(link_text) @markup.link.label
(link_label) @markup.link.label
(image_description) @markup.link.label

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @markup.link.url

; Delimiters
[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation.delimiter

; Escape
[
  (backslash_escape)
  (hard_line_break)
] @string.escape
