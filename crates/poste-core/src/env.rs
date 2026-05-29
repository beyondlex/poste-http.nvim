use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use anyhow::Result;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Environment {
    #[serde(flatten)]
    pub envs: HashMap<String, HashMap<String, String>>,
}

impl Environment {
    pub fn load(path: &str) -> Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let envs: HashMap<String, HashMap<String, String>> = serde_json::from_str(&content)?;
        Ok(Self { envs })
    }

    pub fn get(&self, env_name: &str, var_name: &str) -> Option<&String> {
        self.envs.get(env_name)?.get(var_name)
    }
}
