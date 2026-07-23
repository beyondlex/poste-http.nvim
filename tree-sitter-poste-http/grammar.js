module.exports = grammar({
  name: 'poste_http',

  extras: $ => [/\s/],

  rules: {
    document: $ => repeat($._statement),

    _statement: $ => choice(
      $.request_block,
      $.variable_definition,
      $.multiline_variable,
      $.import_directive,
      $.run_directive,
      $.prompt_variable,
      $.pre_script,
      $.post_script,
      $.external_script,
      $.external_assertion,
      $.request_line,
      $.header,
      $.comment,
      $.file_upload,
      $.file_ref,
    ),

    // ─── Request Block Separator ────────────────────
    request_block: $ => seq(
      $.separator,
      optional($.request_name),
    ),

    separator: $ => '###',

    request_name: $ => /.*/,

    // ─── Request Line ───────────────────────────────
    request_line: $ => seq(
      $.method,
      $.url,
      optional($.http_version),
    ),

    method: $ => /GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|TRACE|CONNECT|SCRIPT/i,

    url: $ => /[^ \t\n]+/,

    http_version: $ => /HTTP\/\d+(?:\.\d+)?/i,

    // ─── Header ─────────────────────────────────────
    header: $ => seq(
      $.header_key,
      ':',
      optional($.header_value),
    ),

    header_key: $ => /[A-Za-z][A-Za-z0-9-]*/,

    header_value: $ => /[^\n]*/,

    // ─── Variable Definition ────────────────────────
    variable_definition: $ => seq(
      '@',
      field('name', $.var_name),
      optional(seq(
        optional($.var_assign),
        field('value', $.var_value),
      )),
    ),

    var_name: $ => /\w+/,

    var_assign: $ => '=',

    var_value: $ => /[^\n]+/,

    // ─── Multi-line Variable ────────────────────────
    multiline_variable: $ => token(seq(
      '@', /\w+/, /[ \t]*=>>>[ \t]*\n/,
      /[\s\S]*?/,
      /\n[ \t]*<<<[ \t]*/
    )),

    // ─── Variable Reference ─────────────────────────
    // (reserved for future use — inline interpolation inside URLs/values)

    // ─── Prompt Variable ────────────────────────────
    prompt_variable: $ => seq(
      '<<',
      field('name', $.var_name),
      optional(seq(
        '[',
        field('options', $.prompt_options),
        ']',
      )),
    ),

    prompt_options: $ => /[^\]]+/,

    // ─── Comments ───────────────────────────────────
    comment: $ => token(seq('#', /[^#\n]*/)),

    // ─── Scripts ────────────────────────────────────
    pre_script: $ => seq(
      '<',
      choice(
        $.inline_script,
        $.multi_line_script,
      ),
    ),

    post_script: $ => seq(
      '>',
      choice(
        $.inline_script,
        $.multi_line_script,
      ),
    ),

    inline_script: $ => /\s*\{%.*%\}/,

    multi_line_script: $ => seq(
      /\s*\{%/,
      repeat(choice(
        /[^%]+/,
        /%[^}]/,
      )),
      /%\}/,
    ),

    external_script: $ => seq(
      '<',
      /\s+\.\/\S*/,
    ),

    external_assertion: $ => seq(
      '>',
      /\s+\.\/\S*/,
    ),

    // ─── File Operations ────────────────────────────
    file_upload: $ => seq(
      '<',
      /\s+\S+/,
    ),

    file_ref: $ => seq(
      '>',
      /\s+\S+/,
    ),

    // ─── Import / Run ───────────────────────────────
    import_directive: $ => seq(
      'import',
      /\s+/,
      field('path', $.import_path),
      optional(seq(
        /\s+/,
        'as',
        /\s+/,
        field('alias', $.import_alias),
      )),
    ),

    import_path: $ => /\S+/,

    import_alias: $ => /\w+/,

    run_directive: $ => seq(
      'run',
      /\s+/,
      field('target', $.run_target),
      optional(seq(
        /\s*/,
        '(',
        field('vars', $.run_vars),
        ')',
      )),
    ),

    run_target: $ => /\S+/,

    run_vars: $ => /[^)]+/,
  },
})