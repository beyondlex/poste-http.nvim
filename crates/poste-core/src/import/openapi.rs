use crate::import::{HttpFile, ImportResult, SpecImporter};
use anyhow::{Context, Result};
use openapiv3::{OpenAPI, PathItem, Operation, ReferenceOr, Parameter, ParameterSchemaOrContent, Schema};
use std::collections::HashMap;

/// Import from OpenAPI 3.x spec.
pub struct OpenApiImporter {
    /// Default base URL override (overrides spec's servers[0])
    pub base_url: Option<String>,
}

impl OpenApiImporter {
    pub fn new() -> Self {
        Self { base_url: None }
    }

    pub fn with_base_url(url: &str) -> Self {
        Self { base_url: Some(url.to_string()) }
    }

    /// Extract the base URL from the spec or use override.
    fn resolve_base_url(&self, api: &OpenAPI) -> String {
        if let Some(ref url) = self.base_url {
            return url.clone();
        }
        if let Some(server) = api.servers.first() {
            let url = server.url.trim_end_matches('/').to_string();
            if !url.is_empty() {
                return url;
            }
        }
        "http://localhost".to_string()
    }

    /// Collect all operations grouped by tag.
    /// Operations without tags go into a "_default" group.
    fn collect_operations(&self, api: &OpenAPI) -> HashMap<String, Vec<OperationInfo>> {
        let mut by_tag: HashMap<String, Vec<OperationInfo>> = HashMap::new();

        for (path_str, item) in &api.paths.paths {
            let item = match item {
                ReferenceOr::Item(item) => item,
                ReferenceOr::Reference { reference } => {
                    eprintln!("[poste import] warning: skipping $ref '{}' at path '{}'", reference, path_str);
                    continue;
                }
            };

            let operations = collect_methods(item);
            for (method, op) in operations {
                let tags = if op.tags.is_empty() {
                    vec!["_default".to_string()]
                } else {
                    op.tags.clone()
                };

                // Replace {param} with {{param}} for Poste variable syntax
                let http_path = path_str.replace('{', "{{").replace('}', "}}");

                for tag in &tags {
                    by_tag.entry(tag.clone())
                        .or_default()
                        .push(OperationInfo {
                            method: method.to_uppercase(),
                            http_path: http_path.clone(),
                            operation_id: op.operation_id.clone().unwrap_or_else(|| {
                                format!("{}{}", method.to_lowercase(), sanitize_path_segment(path_str))
                            }),
                            summary: op.summary.clone().unwrap_or_default(),
                            description: op.description.clone().unwrap_or_default(),
                            parameters: op.parameters.clone(),
                            request_body: op.request_body.clone(),
                            security: op.security.clone(),
                        });
                }
            }
        }

        by_tag
    }

    /// Generate safe filename from tag name.
    fn tag_to_filename(tag: &str) -> String {
        let sanitized: String = tag.chars()
            .map(|c| if c.is_alphanumeric() || c == '_' || c == '-' { c } else { '_' })
            .collect();
        if sanitized.is_empty() {
            "default".to_string()
        } else {
            sanitized.to_lowercase()
        }
    }
}

impl Default for OpenApiImporter {
    fn default() -> Self {
        Self::new()
    }
}

impl SpecImporter for OpenApiImporter {
    fn import(&self, spec_content: &str) -> Result<ImportResult> {
        // Try JSON first, then YAML
        let api: OpenAPI = serde_json::from_str(spec_content)
            .or_else(|_| serde_yaml::from_str(spec_content))
            .context("Failed to parse OpenAPI spec (tried JSON and YAML)")?;

        let base_url = self.resolve_base_url(&api);
        let by_tag = self.collect_operations(&api);
        let mut files = Vec::new();
        let mut env_vars = HashMap::new();
        let mut warnings = Vec::new();

        env_vars.insert("base_url".to_string(), base_url.clone());

        // Process tags in sorted order for deterministic output
        let mut tag_names: Vec<&String> = by_tag.keys().collect();
        tag_names.sort();

        for tag in tag_names {
            let ops = &by_tag[tag];
            let filename = format!("{}.http", Self::tag_to_filename(tag));
            let mut content = String::new();

            // File-level base_url variable
            content.push_str(&format!("@base_url = {{{{base_url}}}}\n"));
            content.push('\n');

            for op in ops {
                // Separator + name
                let display_name = if !op.operation_id.is_empty() {
                    op.operation_id.clone()
                } else {
                    format!("{} {}", op.method, &op.http_path)
                };
                content.push_str(&format!("### {}\n", display_name));
                if !op.summary.is_empty() {
                    content.push_str(&format!("# {}\n", op.summary));
                }

                // Collect query params for the request line
                let mut query_parts: Vec<String> = Vec::new();
                for param in &op.parameters {
                    if let ReferenceOr::Item(Parameter::Query { parameter_data, .. }) = param {
                        let var_name = sanitize_var_name(&parameter_data.name);
                        query_parts.push(format!("{}={}", &parameter_data.name, format!("{{{{{}}}}}", var_name)));
                        if !env_vars.contains_key(&var_name) {
                            let default = extract_default_from_param(parameter_data);
                            env_vars.insert(var_name, default);
                        }
                    }
                }

                // Request line with query string
                let request_url = if query_parts.is_empty() {
                    format!("{{{{base_url}}}}{}", op.http_path)
                } else {
                    format!("{{{{base_url}}}}{}?{}", op.http_path, query_parts.join("&"))
                };
                content.push_str(&format!("{} {}\n", op.method, request_url));

                // Parameters: header/cookie become header lines
                for param in &op.parameters {
                    match param {
                        ReferenceOr::Item(Parameter::Header { parameter_data, .. }) => {
                            let var_name = sanitize_var_name(&parameter_data.name);
                            content.push_str(&format!("{}: {{{}}}\n", parameter_data.name, var_name));
                            if !env_vars.contains_key(&var_name) {
                                let default = extract_default_from_param(parameter_data);
                                env_vars.insert(var_name, default);
                            }
                        }
                        ReferenceOr::Item(Parameter::Query { .. }) => {
                            // Already handled in request line above
                        }
                        ReferenceOr::Item(Parameter::Path { parameter_data, .. }) => {
                            let var_name = sanitize_var_name(&parameter_data.name);
                            if !env_vars.contains_key(&var_name) {
                                let default = extract_default_from_param(parameter_data);
                                env_vars.insert(var_name, default);
                            }
                        }
                        ReferenceOr::Item(Parameter::Cookie { parameter_data, .. }) => {
                            let var_name = sanitize_var_name(&parameter_data.name);
                            content.push_str(&format!("Cookie: {}={{{}}}\n", parameter_data.name, var_name));
                            if !env_vars.contains_key(&var_name) {
                                let default = extract_default_from_param(parameter_data);
                                env_vars.insert(var_name, default);
                            }
                        }
                        ReferenceOr::Reference { reference } => {
                            warnings.push(format!("Skipping $ref parameter: {}", reference));
                        }
                    }
                }

                // Request body
                if let Some(body) = &op.request_body {
                    let body = match body {
                        ReferenceOr::Item(item) => item,
                        ReferenceOr::Reference { reference } => {
                            warnings.push(format!("Skipping $ref request body: {}", reference));
                            // Use continue but in a loop context
                            let _ = warnings.len();
                            continue;
                        }
                    };

                    if let Some((content_type, media_type)) = body.content.iter().next() {
                        content.push_str(&format!("Content-Type: {}\n", content_type));
                        content.push('\n');

                        if let Some(example) = &media_type.example {
                            if let Ok(json) = serde_json::to_string_pretty(example) {
                                content.push_str(&json);
                                content.push('\n');
                            }
                        } else if let Some(schema) = &media_type.schema {
                            if let Some(s) = schema_as_schema(schema) {
                                if let Some(ex) = &s.schema_data.example {
                                    if let Ok(json) = serde_json::to_string_pretty(ex) {
                                        content.push_str(&json);
                                        content.push('\n');
                                    }
                                }
                            }
                        }
                    }
                }

                content.push('\n');
            }

            files.push(HttpFile {
                path: filename,
                content,
            });
        }

        Ok(ImportResult {
            files,
            env_vars,
            warnings,
        })
    }
}

// ---------------------------------------------------------------------------
// Internal types and helpers
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct OperationInfo {
    method: String,
    http_path: String,
    operation_id: String,
    summary: String,
    description: String,
    parameters: Vec<openapiv3::ReferenceOr<openapiv3::Parameter>>,
    request_body: Option<openapiv3::ReferenceOr<openapiv3::RequestBody>>,
    security: Option<Vec<openapiv3::SecurityRequirement>>,
}

/// Collect (method_name, Operation) pairs from a PathItem.
fn collect_methods(item: &PathItem) -> Vec<(&str, &Operation)> {
    let mut ops = Vec::new();
    if let Some(ref op) = item.get { ops.push(("GET", op)); }
    if let Some(ref op) = item.post { ops.push(("POST", op)); }
    if let Some(ref op) = item.put { ops.push(("PUT", op)); }
    if let Some(ref op) = item.delete { ops.push(("DELETE", op)); }
    if let Some(ref op) = item.patch { ops.push(("PATCH", op)); }
    if let Some(ref op) = item.options { ops.push(("OPTIONS", op)); }
    if let Some(ref op) = item.head { ops.push(("HEAD", op)); }
    if let Some(ref op) = item.trace { ops.push(("TRACE", op)); }
    ops
}

/// Create a safe variable name from a parameter name.
fn sanitize_var_name(name: &str) -> String {
    let s: String = name.chars()
        .map(|c| if c == '-' || c == '.' || c == ' ' { '_' } else { c })
        .collect();
    if s.is_empty() { "param".to_string() } else { s }
}

/// Create a safe path segment for fallback operationId generation.
fn sanitize_path_segment(path: &str) -> String {
    path.trim_start_matches('/')
        .replace('/', "_")
        .replace('{', "")
        .replace('}', "")
        .replace('-', "_")
}

/// Extract a default value string from a parameter's schema.
fn extract_default_from_param(data: &openapiv3::ParameterData) -> String {
    match &data.format {
        ParameterSchemaOrContent::Schema(schema_ref) => {
            match schema_ref {
                ReferenceOr::Item(schema) => {
                    if let Some(default) = &schema.schema_data.default {
                        if let Ok(s) = serde_json::to_string(default) {
                            return s.trim_matches('"').to_string();
                        }
                    }
                    String::new()
                }
                ReferenceOr::Reference { .. } => String::new(),
            }
        }
        ParameterSchemaOrContent::Content(_) => String::new(),
    }
}

/// Resolve a ReferenceOr<Schema> to a Schema if possible.
fn schema_as_schema<'a>(s: &'a ReferenceOr<Schema>) -> Option<&'a Schema> {
    match s {
        ReferenceOr::Item(schema) => Some(schema),
        ReferenceOr::Reference { .. } => None,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: parse OpenAPI JSON and run import, return single file content.
    fn import_one(spec: &str, base_url: &str) -> ImportResult {
        let importer = OpenApiImporter::with_base_url(base_url);
        importer.import(spec).unwrap()
    }

    // -----------------------------------------------------------------------
    // Step 3a: Single GET endpoint
    // -----------------------------------------------------------------------

    #[test]
    fn test_single_get_endpoint() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Petstore", "version": "1.0" },
            "paths": {
                "/pets": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "listPets",
                        "summary": "List all pets",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.files[0].path, "pets.http");
        let c = &result.files[0].content;
        assert!(c.contains("### listPets"), "request name: {}", c);
        assert!(c.contains("GET {{base_url}}/pets"), "request line: {}", c);
        assert!(c.contains("List all pets"), "summary: {}", c);
    }

    // -----------------------------------------------------------------------
    // Step 3b: Multiple tags → multiple files
    // -----------------------------------------------------------------------

    #[test]
    fn test_multiple_tags_multiple_files() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Multi", "version": "1.0" },
            "paths": {
                "/pets": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "listPets",
                        "responses": { "200": { "description": "OK" } }
                    }
                },
                "/store/inventory": {
                    "get": {
                        "tags": ["store"],
                        "operationId": "getInventory",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        assert_eq!(result.files.len(), 2);
        let paths: Vec<&str> = result.files.iter().map(|f| f.path.as_str()).collect();
        assert!(paths.contains(&"pets.http"), "should have pets.http: {:?}", paths);
        assert!(paths.contains(&"store.http"), "should have store.http: {:?}", paths);
    }

    // -----------------------------------------------------------------------
    // Step 3c: Path parameters {petId} → {{petId}}
    // -----------------------------------------------------------------------

    #[test]
    fn test_path_parameters() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Petstore", "version": "1.0" },
            "paths": {
                "/pets/{petId}": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "getPetById",
                        "parameters": [
                            { "name": "petId", "in": "path", "required": true, "schema": { "type": "integer" } }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        let c = &result.files[0].content;
        assert!(c.contains("{{petId}}"), "path param should be {{var}}: {}", c);
        // Also check that the raw path template doesn't leak through
        assert!(!c.contains("/pets/{petId}"), "raw path should be replaced: {}", c);
        // Should also have the path param in env_vars (with the path param name)
        assert!(result.env_vars.contains_key("petId"), "env_vars should contain petId");
        assert_eq!(result.env_vars.get("petId").unwrap(), &String::new(), "default should be empty");
    }

    // -----------------------------------------------------------------------
    // Step 3d: Empty spec returns empty result
    // -----------------------------------------------------------------------

    #[test]
    fn test_empty_openapi_creates_no_files() {
        let spec = r#"{"openapi":"3.0.0","info":{"title":"Empty","version":"1.0"},"paths":{}}"#;
        let result = import_one(spec, "http://localhost");
        assert!(result.files.is_empty());
    }

    // -----------------------------------------------------------------------
    // Step 3e: Variables in env_vars
    // -----------------------------------------------------------------------

    #[test]
    fn test_base_url_in_env_vars() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {}
        }"#;
        let importer = OpenApiImporter::with_base_url("https://my.api.com/v2");
        let result = importer.import(spec).unwrap();
        assert_eq!(result.env_vars.get("base_url").unwrap(), "https://my.api.com/v2");
    }

    // -----------------------------------------------------------------------
    // Step 3f: No tag → "_default" file
    // -----------------------------------------------------------------------

    #[test]
    fn test_no_tag_uses_default_file() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/health": {
                    "get": {
                        "operationId": "healthCheck",
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "http://localhost");
        assert_eq!(result.files.len(), 1);
        assert_eq!(result.files[0].path, "_default.http");
    }

    // -----------------------------------------------------------------------
    // Step 3g: Tag name sanitization
    // -----------------------------------------------------------------------

    #[test]
    fn test_tag_to_filename_sanitization() {
        assert_eq!(OpenApiImporter::tag_to_filename("User Management"), "user_management");
        assert_eq!(OpenApiImporter::tag_to_filename("Pets"), "pets");
        assert_eq!(OpenApiImporter::tag_to_filename(""), "default");
    }

    // -----------------------------------------------------------------------
    // Step 4a: Query parameters appear on request line
    // -----------------------------------------------------------------------

    #[test]
    fn test_query_params_on_request_line() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/pets": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "listPets",
                        "parameters": [
                            { "name": "limit", "in": "query", "schema": { "type": "integer" } },
                            { "name": "status", "in": "query", "schema": { "type": "string" } }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        let c = &result.files[0].content;
        assert!(c.contains("?limit={{limit}}"), "query on URL: {}", c);
        assert!(c.contains("status={{status}}"), "second query on URL: {}", c);
        assert!(result.env_vars.contains_key("limit"), "limit in env_vars");
        assert!(result.env_vars.contains_key("status"), "status in env_vars");
    }

    // -----------------------------------------------------------------------
    // Step 4b: Header parameters
    // -----------------------------------------------------------------------

    #[test]
    fn test_header_params_as_headers() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/pets": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "listPets",
                        "parameters": [
                            { "name": "X-Request-Id", "in": "header", "schema": { "type": "string" } }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        let c = &result.files[0].content;
        assert!(c.contains("X-Request-Id"), "header name: {}", c);
        assert!(result.env_vars.contains_key("X_Request_Id"), "header var should be X_Request_Id");
    }

    // -----------------------------------------------------------------------
    // Step 4c: Cookie parameters
    // -----------------------------------------------------------------------

    #[test]
    fn test_cookie_params_as_cookie_header() {
        let spec = r#"{
            "openapi": "3.0.0",
            "info": { "title": "Test", "version": "1.0" },
            "paths": {
                "/pets": {
                    "get": {
                        "tags": ["pets"],
                        "operationId": "listPets",
                        "parameters": [
                            { "name": "session_id", "in": "cookie", "schema": { "type": "string" } }
                        ],
                        "responses": { "200": { "description": "OK" } }
                    }
                }
            }
        }"#;
        let result = import_one(spec, "https://api.example.com");
        let c = &result.files[0].content;
        assert!(c.contains("Cookie:"), "Cookie header: {}", c);
        assert!(result.env_vars.contains_key("session_id"), "cookie var in env");
    }
}
