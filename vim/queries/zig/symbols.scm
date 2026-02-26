(function_declaration name: (identifier) @name) @function
(variable_declaration (identifier) @name (struct_declaration)) @struct
(variable_declaration (identifier) @name (enum_declaration)) @enum
(variable_declaration (identifier) @name (union_declaration)) @union
(test_declaration (string) @name) @test
