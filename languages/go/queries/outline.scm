(function_declaration name: (identifier) @name) @function
(method_declaration name: (field_identifier) @name) @method
(type_declaration (type_spec name: (type_identifier) @name type: (struct_type))) @struct
(type_declaration (type_spec name: (type_identifier) @name type: (interface_type))) @interface
(var_declaration (var_spec name: (identifier) @name)) @variable
(const_declaration (const_spec name: (identifier) @name)) @constant
