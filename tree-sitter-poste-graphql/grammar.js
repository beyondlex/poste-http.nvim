/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// GraphQL query language with Poste {{var}} template support — the injected
// language for GRAPHQL request bodies (mirrors tree-sitter-poste-json for
// JSON bodies). Based on the standard tree-sitter-graphql grammar, restricted
// to executable definitions (operations + fragments): .http bodies never
// carry type-system SDL, and unknown syntax degrades to ERROR nodes, which
// is acceptable for highlighting.

module.exports = grammar({
  name: 'poste_graphql',

  extras: $ => [
    /\s/,
    /,/,
    $.comment,
  ],

  word: $ => $.name,

  supertypes: $ => [
    $._value,
    $._type,
  ],

  rules: {
    document: $ => repeat(choice(
      $.operation_definition,
      $.fragment_definition,
    )),

    operation_definition: $ => choice(
      // Anonymous query: `{ user { name } }`
      $.selection_set,
      seq(
        $.operation_type,
        optional(field('name', $.name)),
        optional($.variable_definitions),
        optional($.directives),
        $.selection_set,
      ),
    ),

    operation_type: $ => choice(
      'query',
      'mutation',
      'subscription',
    ),

    name: $ => /[_A-Za-z][_0-9A-Za-z]*/,

    variable_definitions: $ => seq(
      '(',
      repeat1($.variable_definition),
      ')',
    ),

    variable_definition: $ => seq(
      $.variable,
      ':',
      $._type,
      optional($.default_value),
      optional($.directives),
    ),

    variable: $ => seq('$', $.name),

    default_value: $ => seq('=', $._value),

    _type: $ => choice(
      $.named_type,
      $.list_type,
      $.non_null_type,
    ),

    named_type: $ => field('name', $.name),

    list_type: $ => seq('[', $._type, ']'),

    non_null_type: $ => seq($._type, '!'),

    selection_set: $ => seq(
      '{',
      repeat1($.selection),
      '}',
    ),

    selection: $ => choice(
      $.field,
      $.fragment_spread,
      $.inline_fragment,
    ),

    field: $ => seq(
      optional($.alias),
      field('name', $.name),
      optional($.arguments),
      optional($.directives),
      optional($.selection_set),
    ),

    alias: $ => seq(field('name', $.name), ':'),

    arguments: $ => seq(
      '(',
      repeat1($.argument),
      ')',
    ),

    argument: $ => seq(
      field('name', $.name),
      ':',
      $._value,
    ),

    fragment_spread: $ => seq(
      '...',
      $.fragment_name,
      optional($.directives),
    ),

    fragment_name: $ => field('name', $.name),

    inline_fragment: $ => seq(
      '...',
      optional($.type_condition),
      optional($.directives),
      $.selection_set,
    ),

    fragment_definition: $ => seq(
      'fragment',
      $.fragment_name,
      $.type_condition,
      optional($.directives),
      $.selection_set,
    ),

    type_condition: $ => seq(
      'on',
      $.named_type,
    ),

    directives: $ => repeat1($.directive),

    directive: $ => seq(
      '@',
      $.name,
      optional($.arguments),
    ),

    _value: $ => choice(
      $.variable,
      $.template_variable,
      $.string_value,
      $.number_value,
      $.boolean_value,
      $.null_value,
      $.enum_value,
      $.list_value,
      $.object_value,
    ),

    string_value: $ => choice(
      seq('"', repeat(choice(
        /[^"\\\n]/,
        /\\./,
      )), '"'),
      // Block strings: each alternative consumes 1-3 chars without forming """
      seq('"""', repeat(choice(
        /[^"]/,
        /"[^"]/,
        /""[^"]/,
      )), '"""'),
    ),

    number_value: $ => token(seq(
      optional('-'),
      choice(
        '0',
        seq(/[1-9]/, /[0-9]*/),
      ),
      optional(seq('.', /[0-9]+/)),
      optional(seq(/[eE]/, optional(/[+-]/), /[0-9]+/)),
    )),

    boolean_value: $ => choice('true', 'false'),

    null_value: $ => 'null',

    enum_value: $ => field('name', $.name),

    list_value: $ => seq(
      '[',
      repeat($._value),
      ']',
    ),

    object_value: $ => seq(
      '{',
      repeat($.object_field),
      '}',
    ),

    object_field: $ => seq(
      field('name', $.name),
      ':',
      $._value,
    ),

    // Poste template variable: {{var_name}} anywhere a value is expected
    template_variable: $ => seq(
      '{{',
      optional(/\s+/),
      /[^}]+(?:}[^}]+)*/,
      optional(/\s+/),
      '}}',
    ),

    comment: $ => token(seq('#', /[^\n]*/)),
  },
});
