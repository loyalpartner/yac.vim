(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

(struct_specifier name: (type_identifier) @name) @struct
(enum_specifier name: (type_identifier) @name) @enum
(union_specifier name: (type_identifier) @name) @union

(type_definition
  declarator: (type_identifier) @name) @typedef

(declaration
  declarator: (init_declarator
    declarator: (identifier) @name)) @variable

(preproc_function_def name: (identifier) @name) @macro
(preproc_def name: (identifier) @name) @macro
