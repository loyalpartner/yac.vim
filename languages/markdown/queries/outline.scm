; Markdown headings as document symbols (all → Module)
(atx_heading
  (atx_h1_marker)
  (inline) @name) @module

(atx_heading
  (atx_h2_marker)
  (inline) @name) @module

(atx_heading
  (atx_h3_marker)
  (inline) @name) @module

(atx_heading
  (atx_h4_marker)
  (inline) @name) @module

(atx_heading
  (atx_h5_marker)
  (inline) @name) @module

(atx_heading
  (atx_h6_marker)
  (inline) @name) @module

; Setext-style headings
(setext_heading
  (paragraph) @name
  (setext_h1_underline)) @module

(setext_heading
  (paragraph) @name
  (setext_h2_underline)) @module
