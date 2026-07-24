; Inject Lua into pre/post script blocks (strip {% and %} markers)
((script_block) @injection.content
 (#offset! @injection.content 0 2 0 -2)
 (#set! injection.language "lua"))

; Inject JSON into request body
((request_body) @injection.content
 (#set! injection.language "json"))

