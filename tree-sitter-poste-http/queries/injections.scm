; Inject Lua into pre/post script blocks
(pre_script) @lua
(post_script) @lua

; Inject JSON into json_body
((json_body) @injection.content
 (#set! injection.language "json"))