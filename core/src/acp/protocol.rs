use serde::{Deserialize, Serialize};
use serde_json::Value;

// --- JSON-RPC envelope types ---

#[derive(Serialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: &'static str,
    pub id: u64,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

impl JsonRpcRequest {
    pub fn new(id: u64, method: &str, params: Option<Value>) -> Self {
        Self {
            jsonrpc: "2.0",
            id,
            method: method.to_string(),
            params,
        }
    }
}

#[derive(Deserialize)]
pub struct JsonRpcResponse {
    #[allow(dead_code)]
    pub jsonrpc: String,
    pub id: Option<u64>,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
}

#[derive(Deserialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[allow(dead_code)]
    pub data: Option<Value>,
}

#[derive(Deserialize)]
pub struct JsonRpcNotification {
    #[allow(dead_code)]
    pub jsonrpc: String,
    pub method: String,
    pub params: Option<Value>,
}

// --- ACP-specific types ---

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeParams {
    pub protocol_version: String,
    pub client_capabilities: ClientCapabilities,
    pub client_info: ClientInfo,
}

#[derive(Serialize)]
pub struct ClientCapabilities {}

#[derive(Serialize)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InitializeResult {
    #[allow(dead_code)]
    pub protocol_version: Option<String>,
    #[allow(dead_code)]
    pub agent_capabilities: Option<Value>,
    #[allow(dead_code)]
    pub agent_info: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionNewParams {
    pub cwd: String,
    pub mcp_servers: Vec<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionNewResult {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionCancelParams {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRewindParams {
    pub session_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionResumeParams {
    pub session_id: String,
    pub cwd: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPromptParams {
    pub session_id: String,
    pub prompt: Vec<ContentBlock>,
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct ContentBlock {
    #[serde(rename = "type")]
    pub content_type: String,
    pub text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPromptResult {
    pub stop_reason: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUpdateParams {
    #[allow(dead_code)]
    pub session_id: String,
    #[serde(flatten)]
    pub update: SessionUpdate,
}

#[derive(Deserialize)]
#[serde(tag = "sessionUpdate", rename_all = "snake_case")]
pub enum SessionUpdate {
    AgentMessageChunk {
        content: ContentBlock,
    },
    ToolCall {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        title: String,
        kind: Option<String>,
        status: String,
    },
    ToolCallUpdate {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        status: String,
        content: Option<ContentBlock>,
    },
    TurnEnd,
}

// --- Permission request (server-to-client) ---

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestPermissionParams {
    pub session_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub description: String,
    pub kind: Option<String>,
}

// --- JSON-RPC response (outgoing) ---

#[derive(Serialize)]
pub struct JsonRpcResponseOut {
    pub jsonrpc: &'static str,
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcErrorOut>,
}

#[derive(Serialize)]
pub struct JsonRpcErrorOut {
    pub code: i64,
    pub message: String,
}

// --- Incoming message parsing ---

/// A raw line from stdout can be either a response (has `id`) or a notification (has `method`, no `id`).
#[derive(Deserialize)]
pub struct RawMessage {
    pub id: Option<u64>,
    pub method: Option<String>,
    pub result: Option<Value>,
    pub error: Option<JsonRpcError>,
    pub params: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_initialize_request() {
        let req = JsonRpcRequest::new(
            1,
            "initialize",
            Some(
                serde_json::to_value(InitializeParams {
                    protocol_version: "2025-01-01".to_string(),
                    client_capabilities: ClientCapabilities {},
                    client_info: ClientInfo {
                        name: "AwalTerminal".to_string(),
                        version: "0.17.0".to_string(),
                    },
                })
                .unwrap(),
            ),
        );
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"method\":\"initialize\""));
        assert!(json.contains("\"protocolVersion\":\"2025-01-01\""));
    }

    #[test]
    fn deserialize_session_update_text_chunk() {
        let json = r#"{"sessionId":"abc","sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello"}}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        match params.update {
            SessionUpdate::AgentMessageChunk { content } => {
                assert_eq!(content.text, "hello");
            }
            _ => panic!("expected AgentMessageChunk"),
        }
    }

    #[test]
    fn deserialize_session_update_turn_end() {
        let json = r#"{"sessionId":"abc","sessionUpdate":"turn_end"}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        assert!(matches!(params.update, SessionUpdate::TurnEnd));
    }

    #[test]
    fn deserialize_session_update_tool_call() {
        let json = r#"{"sessionId":"abc","sessionUpdate":"tool_call","toolCallId":"t1","title":"Read file","kind":"read","status":"running"}"#;
        let params: SessionUpdateParams = serde_json::from_str(json).unwrap();
        match params.update {
            SessionUpdate::ToolCall {
                tool_call_id,
                title,
                status,
                ..
            } => {
                assert_eq!(tool_call_id, "t1");
                assert_eq!(title, "Read file");
                assert_eq!(status, "running");
            }
            _ => panic!("expected ToolCall"),
        }
    }

    #[test]
    fn deserialize_response_with_error() {
        let json =
            r#"{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid request"}}"#;
        let resp: JsonRpcResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.id, Some(1));
        let err = resp.error.unwrap();
        assert_eq!(err.code, -32600);
        assert_eq!(err.message, "Invalid request");
    }
}
