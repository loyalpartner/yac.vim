; Top-level functions only
(source_file (function_declaration name: (identifier) @name) @function)

; Named containers
(source_file (variable_declaration (identifier) @name (struct_declaration)) @struct)
(source_file (variable_declaration (identifier) @name (enum_declaration)) @enum)
(source_file (variable_declaration (identifier) @name (union_declaration)) @union)

; Methods inside containers
(source_file (variable_declaration (identifier) @impl_type (struct_declaration (function_declaration name: (identifier) @name) @method)))
(source_file (variable_declaration (identifier) @impl_type (enum_declaration (function_declaration name: (identifier) @name) @method)))
(source_file (variable_declaration (identifier) @impl_type (union_declaration (function_declaration name: (identifier) @name) @method)))

(test_declaration (string) @name) @test

; Variable declarations with extractable detail (import, type alias, variable).
; Restricted to source_file direct children to exclude local variables inside function bodies.
(source_file (variable_declaration (identifier) @name (builtin_function) @detail) @module)
(source_file (variable_declaration (identifier) @name (field_expression) @detail) @type_alias)
(source_file (variable_declaration (identifier) @name (identifier) @detail) @variable)
