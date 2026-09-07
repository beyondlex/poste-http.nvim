; GraphQL query text injected into GRAPHQL request bodies.
; Standard capture groups only — the injected parser is optional at runtime,
; so colors must work through the default treesitter highlight links.

(operation_type) @keyword
"fragment" @keyword
"on" @keyword

(operation_definition name: (name) @function)
(fragment_definition (fragment_name (name) @function))

(variable) @variable
(template_variable) @variable

(field name: (name) @property)
(alias name: (name) @property)
(argument name: (name) @property)
(object_field name: (name) @property)

(named_type) @type
(enum_value) @constant
(null_value) @constant.builtin
(boolean_value) @boolean
(number_value) @number
(string_value) @string

(directive (name) @attribute)

(comment) @comment

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
[":" "=" "!" "$" "..." "@"] @punctuation.delimiter
