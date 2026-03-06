; Function definitions (with body)
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

; Struct/enum/union specifiers
(struct_specifier name: (type_identifier) @name) @struct
(enum_specifier name: (type_identifier) @name) @enum
(union_specifier name: (type_identifier) @name) @union

; Typedef
(type_definition
  declarator: (type_identifier) @name) @typedef


; Preprocessor macros
(preproc_function_def name: (identifier) @name) @macro
(preproc_def name: (identifier) @name) @macro
