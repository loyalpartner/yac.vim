; Function declarations
(function_declaration
  name: (identifier) @name) @function

; Named function expressions assigned to variables
(variable_declarator
  name: (identifier) @name
  value: [
    (function_expression)
    (arrow_function)
  ]) @function

; Class declarations
(class_declaration
  name: (type_identifier) @name) @class

; Method definitions inside class body
(method_definition
  name: [
    (property_identifier)
    (private_property_identifier)
  ] @name) @method

; Abstract method signatures
(abstract_method_signature
  name: (property_identifier) @name) @method

; Object methods (key: function)
(pair
  key: [
    (property_identifier)
    (string)
  ] @name
  value: [
    (function_expression)
    (arrow_function)
  ]) @method

; Assignment to member expression
(assignment_expression
  left: (member_expression
    property: (property_identifier) @name)
  right: [
    (function_expression)
    (arrow_function)
  ]) @method

; Interface declarations
(interface_declaration
  name: (type_identifier) @name) @interface

; Type alias declarations
(type_alias_declaration
  name: (type_identifier) @name) @type_alias

; Enum declarations
(enum_declaration
  name: (type_identifier) @name) @enum

; Namespace declarations
(module_declaration
  name: [
    (identifier)
    (string)
  ] @name) @namespace

; Exported function declarations
(export_statement
  declaration: (function_declaration
    name: (identifier) @name)) @function

; Exported class declarations
(export_statement
  declaration: (class_declaration
    name: (type_identifier) @name)) @class

; Exported interface declarations
(export_statement
  declaration: (interface_declaration
    name: (type_identifier) @name)) @interface

; Exported type alias declarations
(export_statement
  declaration: (type_alias_declaration
    name: (type_identifier) @name)) @type_alias

; Exported enum declarations
(export_statement
  declaration: (enum_declaration
    name: (identifier) @name)) @enum

; Exported variable (function/arrow)
(export_statement
  declaration: (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [
        (function_expression)
        (arrow_function)
      ]))) @function

