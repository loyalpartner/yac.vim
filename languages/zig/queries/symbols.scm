(function_declaration name: (identifier) @name) @function
(variable_declaration (identifier) @name (struct_declaration)) @struct
(variable_declaration (identifier) @name (enum_declaration)) @enum
(variable_declaration (identifier) @name (union_declaration)) @union
(test_declaration (string) @name) @test

; Variable declarations with extractable detail (import, type alias, variable).
; Using distinct capture names so Vim can apply the right highlight group.
; These do NOT overlap with @struct/@enum/@union above (different value node types).
(variable_declaration (identifier) @name (builtin_function) @detail) @module
(variable_declaration (identifier) @name (field_expression) @detail) @type_alias
(variable_declaration (identifier) @name (identifier) @detail) @variable
