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
      $.graphql_body,
      $.multipart_boundary,
      $.multipart_form_data,
      $.form_body,
      $.header,
      $.request_line,
      $.comment,
      $.file_upload,
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
    request_line: $ => choice(
      seq(
        $.method,
        WS,
        $.url,
        optional(seq(WS, $.http_version)),
        NL,
      ),
      // Bare SCRIPT method (script-only block, no URL)
      seq(
        $.method_script,
        NL,
      ),
    ),

    method: $ => choice(
      $.method_get, $.method_post, $.method_put, $.method_delete,
      $.method_patch, $.method_head, $.method_options,
      $.method_trace, $.method_connect, $.method_script,
      $.method_graphql, $.method_grpc, $.method_websocket,
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
    method_graphql: $ => 'GRAPHQL',
    method_grpc: $ => 'GRPC',
    method_websocket: $ => 'WEBSOCKET',

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

    identifier: $ => /[^}]+(?:}[^}]+)*/,

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

    header_value: $ => repeat1(choice(
      /[^\n{}]+/,
      $.variable,
    )),

    // ─── Variable Definition ────────────────────────
    variable_definition: $ => seq(
      '@',
      field('name', $.var_name),
      optional(seq(
        optional(WS),
        optional($.var_assign),
        optional(WS),
        field('value', choice($.variable, $.import_var_ref, $.var_value)),
      )),
      NL,
    ),

    var_name: $ => /\w+/,

    var_assign: $ => '=',

    var_value: $ => seq(
      /[^\{]/,
      /[^\n]*/,
    ),

    // Import variable reference: @var = alias.keypath
    // Single token to avoid lexer conflict with var_value's opening regex.
    // Sub-highlighting applied via Lua extmarks (treesitter.lua).
    import_var_ref: $ => token(seq(
      /[a-zA-Z_][a-zA-Z0-9_]*/,
      repeat1(seq(
        '.',
        /[a-zA-Z_][a-zA-Z0-9_]*/,
        optional(seq('[', /\d+/, ']')),
      )),
    )),

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
        $.variable,
        /[^\[\]{}]+/,
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
      /\n/,
    ),

    external_assertion: $ => seq(
      '>',
      /[ \t]+/,
      /\.\/\S*/,
      /\n/,
    ),

    // ─── File Operations ────────────────────────────
    file_upload: $ => seq(
      '<',
      /[ \t]+/,
      /[^\.\n][^\n]*/,
      /\n/,
    ),

    file_upload_token: $ => token(seq(
      '<',
      /[ \t]+/,
      /[^\n]+/,
      /\n/,
    )),

    file_ref: $ => seq(
      '>',
      /[ \t]+/,
      /[^\n]+/,
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
      token(prec(1, /[Rr][Uu][Nn]/)),
      /\s+/,
      field('target', $.run_target),
      optional($.run_vars_clause),
      NL,
    ),

    run_target: $ => seq(
      optional($.run_target_prefix),
      $.run_target_name,
    ),

    run_target_prefix: $ => token(prec(1, /[^ \t\n.]+\./)),

    run_target_name: $ => token(/[^ \t\n]+/),

    run_vars_clause: $ => token(seq(
      /[ \t]*/,
      '(',
      /[^)]*/,
      ')',
    )),

    // ─── JSON Body ──────────────────────────────────
    // A continuation line is any line whose first non-blank character does
    // not start a `###`-shaped separator: `###` is ALWAYS the next block's
    // separator, even when the user omitted the blank line after the body.
    // The old blanket `\n[^\n]+` continuation swallowed the entire next
    // request block into one json_body (highlight/fold bleed across the
    // boundary, two adjacent POSTs parsed as one body). `#`-comment lines
    // inside the body stay body text (JSON has no #-lexeme, nothing legal
    // is lost); `##`+ lines are ambiguous and end the body.
    json_body: $ => token(seq(
      /[\[{][^\n]*/,
      repeat(seq('\n', choice(
        /[ \t]*[^ \t#\n][^\n]*/,
        /[ \t]*#[^#\n][^\n]*/,
      ))),
    )),

    // ─── GraphQL Query Body ─────────────────────────
    // Query/mutation/subscription/fragment text for GRAPHQL request
    // blocks. Anchored to those keywords followed by whitespace so it
    // never competes with headers (`query: x`) or form bodies
    // (`query=x`); '{'-starting segments (anonymous queries, variables)
    // stay with json_body.
    graphql_body: $ => token(seq(
      choice(/query[ \t]/, /mutation[ \t]/, /subscription[ \t]/, /fragment[ \t]/),
      /[^\n]*/,
      // Continuation lines stop at blank lines (so the variables JSON
      // after the query parses as json_body) and at ### separator lines
      // (same no-blank-line rule as json_body above). Single-# lines stay
      // body: they are legal GraphQL comments.
      repeat(seq('\n', choice(
        /[ \t]*[^ \t#\n][^\n]*/,
        /[ \t]*#[^#\n][^\n]*/,
      ))),
    )),

    // ─── Multipart Boundary ─────────────────────────
    multipart_boundary: $ => /---[^\n]*/,

    // ─── Multipart Form Data ─────────────────────────
    multipart_form_data: $ => seq(
      $.multipart_disposition,
      optional($.multipart_content_type),
      /[ \t]*\n/,
      choice(
        $.file_upload_token,
        $.multipart_value,
      ),
    ),

    multipart_body: $ => choice(
      seq('<', /[ \t]+/, /[^\n]+/, /\n/),
      /[^\n]+/,
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
        optional(/[ \t]*\n[ \t]*/),
        '&',
        /[a-zA-Z_][a-zA-Z0-9_]*/,
        '=',
        /[^&\n]*/,
      )),
      optional(NL),
    )),
  },
});
