/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

const WS = /[ \t]+/;
const NL = token(choice('\n', '\r', '\r\n'));

module.exports = grammar({
  name: 'poste_http',

  extras: $ => [],

  rules: {
    document: $ => repeat(choice(
      $._blank_line,
      $._statement,
    )),

    _blank_line: $ => seq(optional(WS), token(prec(-1, NL))),

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
      $.json_body,
      $.multipart_boundary,
      $.multipart_form_data,
      $.form_body,
      $.header,
      $.request_line,
      $.comment,
      $.file_upload,
      $.file_ref,
    ),

    // ─── Request Block Separator ────────────────────
    request_block: $ => seq(
      $.separator,
      optional($.request_name),
      NL,
    ),

    separator: $ => token('###'),

    request_name: $ => /[^\n]*/,

    // ─── Request Line ───────────────────────────────
    request_line: $ => seq(
      $.method,
      WS,
      $.url,
      optional(seq(WS, $.http_version)),
      NL,
    ),

    method: $ => choice(
      $.method_get, $.method_post, $.method_put, $.method_delete,
      $.method_patch, $.method_head, $.method_options,
      $.method_trace, $.method_connect, $.method_script,
    ),

    method_get: $ => 'GET',
    method_post: $ => 'POST',
    method_put: $ => 'PUT',
    method_delete: $ => 'DELETE',
    method_patch: $ => 'PATCH',
    method_head: $ => 'HEAD',
    method_options: $ => 'OPTIONS',
    method_trace: $ => 'TRACE',
    method_connect: $ => 'CONNECT',
    method_script: $ => 'SCRIPT',

    url: $ => seq(
      $.url_path,
      optional($.query_string),
    ),

    url_path: $ => repeat1(choice(
      /[^ \t\n{}?]+/,
      $.variable,
    )),

    query_string: $ => seq(
      '?',
      $.query_params,
    ),

    query_params: $ => seq(
      $.query_param,
      repeat(seq('&', $.query_param)),
    ),

    query_param: $ => seq(
      $.query_key,
      optional(seq('=', optional($.query_value))),
    ),

    query_key: $ => /[a-zA-Z_][a-zA-Z0-9_.-]*/,

    query_value: $ => repeat1(choice(
      /[^ \t\n{}&]+/,
      $.variable,
    )),

    variable: $ => seq(
      '{{',
      optional(WS),
      field('name', $.identifier),
      optional(WS),
      '}}',
    ),

    identifier: $ => /[A-Za-z_.$\d\u00A1-\uFFFF-]+/,

    http_version: $ => /HTTP\/\d+(?:\.\d+)?/i,

    // ─── Header ─────────────────────────────────────
    header: $ => seq(
      $.header_key,
      optional(WS),
      ':',
      optional($.header_value),
      NL,
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
      NL,
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

    // ─── Prompt Variable ────────────────────────────
    prompt_variable: $ => seq(
      '<<',
      $.prompt_name,
      optional(seq(WS, $.prompt_options)),
      NL,
    ),

    prompt_name: $ => /\w+/,

    prompt_options: $ => seq(
      '[',
      repeat(choice(
        /[^\[\]]+/,
        $.prompt_options,
      )),
      ']',
    ),

    // ─── Comments ───────────────────────────────────
    comment: $ => token(seq('#', optional(/[^#\n][^\n]*/), NL)),

    // ─── Scripts ────────────────────────────────────
    pre_script: $ => seq(
      '<',
      optional(WS),
      $.script_block,
      optional(NL),
    ),

    post_script: $ => seq(
      '>',
      optional(WS),
      $.script_block,
      optional(NL),
    ),

    script_block: $ => token(seq(
      '{%',
      repeat(choice(
        /[^%]+/,
        /%[^}]/,
      )),
      '%}',
    )),

    external_script: $ => seq(
      '<',
      /[ \t]+/,
      /\.\/\S*/,
      optional(NL),
    ),

    external_assertion: $ => seq(
      '>',
      /[ \t]+/,
      /\.\/\S*/,
      optional(NL),
    ),

    // ─── File Operations ────────────────────────────
    file_upload: $ => seq(
      '<',
      /[ \t]+/,
      /[^\{][^\n]*/,
      optional(NL),
    ),

    file_ref: $ => seq(
      '>',
      /[ \t]+/,
      /[^\{][^\n]*/,
      optional(NL),
    ),

    // ─── Import / Run ───────────────────────────────
    import_directive: $ => seq(
      'import',
      /\s+/,
      field('path', $.import_path),
      optional($.import_alias_clause),
      NL,
    ),

    import_path: $ => /\S+/,

    import_alias_clause: $ => token(seq(
      /[ \t]+/,
      'as',
      /[ \t]+/,
      /\w+/,
    )),

    run_directive: $ => seq(
      'run',
      /\s+/,
      field('target', $.run_target),
      optional($.run_vars_clause),
      NL,
    ),

    run_target: $ => /\S+/,

    run_vars_clause: $ => token(seq(
      /[ \t]*/,
      '(',
      /[^)]*/,
      ')',
    )),

    // ─── JSON Body ──────────────────────────────────
    json_body: $ => token(seq(
      /[\[{][^\n]*/,
      /(?:\n[^#\n][^\n]*)*/,
    )),

    // ─── Multipart Boundary ─────────────────────────
    multipart_boundary: $ => /---[^\n]*/,

    // ─── Multipart Form Data ─────────────────────────
    multipart_form_data: $ => seq(
      $.multipart_disposition,
      optional($.multipart_content_type),
      /[ \t]*\n/,
      choice(
        $.file_upload,
        $.multipart_value,
      ),
    ),

    multipart_disposition: $ => seq(
      $.multipart_disposition_key,
      optional(WS),
      ':',
      optional($.multipart_disposition_value),
      NL,
    ),

    multipart_disposition_key: $ => token(prec(1, /Content-Disposition/)),

    multipart_disposition_value: $ => /[^\n]*/,

    multipart_content_type: $ => seq(
      $.multipart_content_type_key,
      optional(WS),
      ':',
      optional($.multipart_content_type_value),
      NL,
    ),

    multipart_content_type_key: $ => /Content-Type/,

    multipart_content_type_value: $ => /[^\n]*/,

    multipart_value: $ => /[^\n]+/,

    // ─── URL-Encoded Form Body ───────────────────────
    form_body: $ => token(seq(
      /[a-zA-Z_][a-zA-Z0-9_]*/,
      '=',
      /[^&\n]*/,
      repeat(seq(
        '&',
        /[a-zA-Z_][a-zA-Z0-9_]*/,
        '=',
        /[^&\n]*/,
      )),
      optional(NL),
    )),
  },
});