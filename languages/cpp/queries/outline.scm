; Function definitions (with body)
(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @function

; Method definitions outside class (ClassName::method)
(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (identifier) @name))) @method

; Pointer-returning function definitions: int* foo() {}
(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name))) @function

; Class/struct/enum/union specifiers (only when NOT inside template_declaration)
(class_specifier name: (type_identifier) @name) @class
(struct_specifier name: (type_identifier) @name) @struct
(enum_specifier name: (type_identifier) @name) @enum
(union_specifier name: (type_identifier) @name) @union

; Namespace
(namespace_definition name: (namespace_identifier) @name) @namespace

; Typedef
(type_definition
  declarator: (type_identifier) @name) @typedef

; Template function/class (these also match the inner class/function patterns above,
; but extractSymbols deduplicates by position, so template versions take priority)
(template_declaration
  (function_definition
    declarator: (function_declarator
      declarator: (identifier) @name))) @function

(template_declaration
  (class_specifier name: (type_identifier) @name)) @class

; Method declarations inside class body (field_declaration with function_declarator)
(field_declaration
  declarator: (function_declarator
    declarator: (field_identifier) @name)) @method

; Constructor/destructor declarations inside class body
; These appear as (declaration (function_declarator ...)) inside field_declaration_list
(declaration
  declarator: (function_declarator
    declarator: (identifier) @name)) @method

; Member variables (fields inside class/struct body)
(field_declaration
  declarator: (field_identifier) @name) @field

; Pointer member variables: T* m_data;
(field_declaration
  declarator: (pointer_declarator
    declarator: (field_identifier) @name)) @field

; Preprocessor macros
(preproc_function_def name: (identifier) @name) @macro
(preproc_def name: (identifier) @name) @macro
