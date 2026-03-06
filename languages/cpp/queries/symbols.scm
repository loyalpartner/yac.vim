(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (identifier) @name))) @method

(class_specifier name: (type_identifier) @name) @class
(struct_specifier name: (type_identifier) @name) @struct
(enum_specifier name: (type_identifier) @name) @enum
(union_specifier name: (type_identifier) @name) @union

(namespace_definition name: (namespace_identifier) @name) @namespace

(type_definition
  declarator: (type_identifier) @name) @typedef

(template_declaration
  (function_definition
    declarator: (function_declarator
      declarator: (identifier) @name))) @function

(template_declaration
  (class_specifier name: (type_identifier) @name)) @class

(declaration
  declarator: (init_declarator
    declarator: (identifier) @name)) @variable

(preproc_function_def name: (identifier) @name) @macro
(preproc_def name: (identifier) @name) @macro
