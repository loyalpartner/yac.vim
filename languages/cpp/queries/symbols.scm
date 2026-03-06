; Function definitions (with body)
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

; Method definitions outside class (ClassName::method)
(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (identifier) @name))) @method

; Class/struct/enum/union specifiers
(class_specifier name: (type_identifier) @name) @class
(struct_specifier name: (type_identifier) @name) @struct
(enum_specifier name: (type_identifier) @name) @enum
(union_specifier name: (type_identifier) @name) @union

; Namespace
(namespace_definition name: (namespace_identifier) @name) @namespace

; Typedef
(type_definition
  declarator: (type_identifier) @name) @typedef

; Template function/class
(template_declaration
  (function_definition
    declarator: (function_declarator
      declarator: (identifier) @name))) @function

(template_declaration
  (class_specifier name: (type_identifier) @name)) @class

; Method declarations inside class body (no body, field_declaration with function_declarator)
(field_declaration
  declarator: (function_declarator
    declarator: (field_identifier) @name)) @method

; Top-level variable declarations
(declaration
  declarator: (init_declarator
    declarator: (identifier) @name)) @variable

; Function declarations (forward declarations, no body)
(declaration
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

; Preprocessor macros
(preproc_function_def name: (identifier) @name) @macro
(preproc_def name: (identifier) @name) @macro
