use crate::import::{ImportResult, SpecImporter};
use anyhow::Result;
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
}

impl Default for OpenApiImporter {
    fn default() -> Self {
        Self::new()
    }
}

impl SpecImporter for OpenApiImporter {
    fn import(&self, _spec_content: &str) -> Result<ImportResult> {
        // Placeholder — will be implemented in Step 3+
        Ok(ImportResult {
            files: vec![],
            env_vars: HashMap::new(),
            warnings: vec![],
        })
    }
}