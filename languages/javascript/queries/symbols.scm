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
  name: (identifier) @name) @class

; Method definitions inside class body
(method_definition
  name: [
    (property_identifier)
    (private_property_identifier)
  ] @name) @method

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

; Assignment to member expression (ClassName.prototype.method = function)
(assignment_expression
  left: (member_expression
    property: (property_identifier) @name)
  right: [
    (function_expression)
    (arrow_function)
  ]) @method

; Exported function declarations
(export_statement
  declaration: (function_declaration
    name: (identifier) @name)) @function

; Exported class declarations
(export_statement
  declaration: (class_declaration
    name: (identifier) @name)) @class

; Exported variable (function/arrow)
(export_statement
  declaration: (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [
        (function_expression)
        (arrow_function)
      ]))) @function

