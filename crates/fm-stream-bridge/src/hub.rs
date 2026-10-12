//! Transport to the hub: one GET client whose outcomes are exactly the
//! reference bridge's `BridgeError` (refusal, fatal) and `HubUnreachable`
//! (transport problem, retryable in serve, exit-1 in snapshot).
//!
//! Known divergence: the reference's stdlib client follows 3xx redirects; the
//! hub never emits one, so this client treats a 3xx like any other unexpected
//! status.  Everything a healthy or broken hub can actually answer is
//! reproduced.

use std::time::Duration;

use http_body_util::{BodyExt, Empty};
use hyper::body::Bytes;
use hyper::Request;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;

/// A refusal: this hub's answer (or the input, or the invocation) makes
/// driving the wire protocol impossible.  Always fatal in the reference.
#[derive(Debug)]
pub struct BridgeError(pub String);

impl std::fmt::Display for BridgeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A transport problem: the hub could not be asked.  Retryable in serve
/// (which reports it once and emits nothing until it clears), exit-1 in
/// snapshot, and wrapped into a refusal in compare.
#[derive(Debug)]
pub struct HubUnreachable(pub String);

impl std::fmt::Display for HubUnreachable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// One GET's outcome.
pub enum GetOutcome {
    Answer(serde_json::Value),
    Unreachable(HubUnreachable),
    Refused(BridgeError),
}

pub struct HubClient {
    url: String,
    token: String,
    client: Client<HttpConnector, Empty<Bytes>>,
}

impl HubClient {
    pub fn new(url: &str, token: &str) -> Self {
        HubClient {
            url: url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client: Client::builder(TokioExecutor::new()).build_http(),
        }
    }

    /// The hub's base URL as normalized at construction, for messages.
    pub fn url(&self) -> &str {
        &self.url
    }

    /// GET `path` with the subscribe-class bearer token and read one JSON
    /// object back, 5-second budget end to end, mirroring the reference's
    /// urlopen-with-timeout behaviour including its refusal wording.
    pub async fn get(&self, path: &str) -> GetOutcome {
        let uri = match format!("{}{}", self.url, path).parse::<hyper::Uri>() {
            Ok(uri) => uri,
            Err(error) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: {}",
                    self.url, error
                )))
            }
        };
        let request = match Request::builder()
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token))
            .body(Empty::<Bytes>::new())
        {
            Ok(request) => request,
            Err(error) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: {}",
                    self.url, error
                )))
            }
        };
        let sent = tokio::time::timeout(Duration::from_secs(5), self.client.request(request)).await;
        let response = match sent {
            Ok(Ok(response)) => response,
            Ok(Err(error)) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: {}",
                    self.url, error
                )))
            }
            Err(_) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: timed out after 5s",
                    self.url
                )))
            }
        };
        let status = response.status();
        if status == hyper::StatusCode::UNAUTHORIZED || status == hyper::StatusCode::FORBIDDEN {
            return GetOutcome::Refused(BridgeError(format!(
                "the hub at {} refused the credential for {} (HTTP {}): the bridge needs a token holding the subscribe class",
                self.url, path, status.as_u16()
            )));
        }
        if !status.is_success() {
            return GetOutcome::Unreachable(HubUnreachable(format!(
                "the hub at {} answered {} with HTTP {}",
                self.url,
                path,
                status.as_u16()
            )));
        }
        let body = match tokio::time::timeout(
            Duration::from_secs(5),
            response.into_body().collect(),
        )
        .await
        {
            Ok(Ok(collected)) => collected.to_bytes(),
            Ok(Err(error)) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: {}",
                    self.url, error
                )))
            }
            Err(_) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "cannot reach the hub at {}: timed out after 5s",
                    self.url
                )))
            }
        };
        let answer: serde_json::Value = match serde_json::from_slice(&body) {
            Ok(answer) => answer,
            Err(_) => {
                return GetOutcome::Unreachable(HubUnreachable(format!(
                    "the hub at {} answered {} with malformed JSON",
                    self.url, path
                )))
            }
        };
        if !answer.is_object() {
            return GetOutcome::Unreachable(HubUnreachable(format!(
                "the hub at {} answered {} with a non-object",
                self.url, path
            )));
        }
        GetOutcome::Answer(answer)
    }
}
