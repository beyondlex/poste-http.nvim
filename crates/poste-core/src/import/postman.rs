use crate::import::{ImportResult, SpecImporter};
use anyhow::Result;

/// Import from Postman Collection v2.1 export.
pub struct PostmanImporter;

impl SpecImporter for PostmanImporter {
    fn import(&self, _spec_content: &str) -> Result<ImportResult> {
        // Placeholder — will be implemented in Step 10–12
        Ok(ImportResult {
            files: vec![],
            env_vars: std::collections::HashMap::new(),
            warnings: vec![],
        })
    }
}