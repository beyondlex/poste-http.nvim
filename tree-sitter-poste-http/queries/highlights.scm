; Request block separator
(separator) @PosteSeparator
(request_name) @PosteRequestName

; Variable definition
(variable_definition
  "@" @PosteVarDef
  (var_name) @PosteVarDef)
(var_assign) @PosteVarAssign
(var_value) @PosteVarValue

; Multi-line variable body
(multiline_variable) @PosteVarValue

; Request line - per-method colors (grammar-level named nodes)
(method_get) @PosteMethodGET
(method_post) @PosteMethodPOST
(method_put) @PosteMethodPUT
(method_delete) @PosteMethodDELETE
(method_patch) @PosteMethodPATCH
(method_head) @PosteMethodHEAD
(method_options) @PosteMethodOPTIONS
(method_script) @PosteMethodScript
; TRACE, CONNECT -> gray
(method_trace) @PosteMethodOther
(method_connect) @PosteMethodOther
(url) @PosteUrl
(http_version) @PosteHttpVersion

; Variable reference ({{var}} / {{$var}})
(variable) @PosteVarRef

; Header
(header_key) @PosteHeaderKey
":" @PosteHeaderSep
(header_value) @PosteVarValue

; Prompt variable
(prompt_variable) @PostePromptVar
(prompt_name) @PostePromptVar
(prompt_options) @PostePromptOpts

; Comment
(comment) @PosteComment

; Pre/Post scripts
(pre_script) @PostePreScript
(post_script) @PosteAssertion

; External scripts
(external_script) @PosteExternalScript
(external_assertion) @PosteFileRef

; Import / Run
(import_directive
  "import" @PosteImport
  (import_path) @PosteImportPath)
(import_alias_clause) @PosteImportAlias

(run_directive
  "run" @PosteRun
  (run_target) @PosteRunTarget)
(run_vars_clause) @PosteRunVars

; JSON body
(json_body) @PosteRequestBody

; Multipart boundary
(multipart_boundary) @PosteMultipartBoundary

; Multipart form data
(multipart_disposition_key) @PosteHeaderKey
(multipart_disposition_value) @PosteVarValue
(multipart_content_type_key) @PosteHeaderKey
(multipart_content_type_value) @PosteVarValue
(multipart_value) @PosteMultipartBody

; File operations
(file_upload) @PosteFileUpload
(file_ref) @PosteFileRef