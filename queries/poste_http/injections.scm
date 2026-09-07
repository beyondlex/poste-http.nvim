; Inject Lua into pre/post script blocks (strip {% and %} markers)
((script_block) @injection.content
 (#offset! @injection.content 0 2 0 -2)
 (#set! injection.language "lua"))

; Inject custom JSON (with {{var}} support) into json_body
((json_body) @injection.content
 (#set! injection.language "poste_json"))

; Inject custom GraphQL (with {{var}} support) into graphql_body
((graphql_body) @injection.content
 (#set! injection.language "poste_graphql"))