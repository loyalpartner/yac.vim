; TOML tables as module-level symbols
(table (bare_key) @name) @module
(table (dotted_key) @name) @module

; TOML array of tables as module-level symbols
(table_array_element (bare_key) @name) @module
(table_array_element (dotted_key) @name) @module

; Key-value pairs as variable symbols
(pair (bare_key) @name) @variable
(pair (dotted_key) @name) @variable
