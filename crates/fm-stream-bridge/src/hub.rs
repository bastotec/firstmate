//! Transport to the hub: one HTTP/HTTPS GET client whose outcomes are exactly
//! the reference bridge's `BridgeError` (refusal, fatal) and `HubUnreachable`
//! (transport problem, retryable in serve, exit-1 in snapshot).

use std::time::Duration;

use http_body_util::{BodyExt, Empty};
use hyper::body::Bytes;
use hyper::Request;
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder};
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
    client: Client<HttpsConnector<HttpConnector>, Empty<Bytes>>,
}

impl HubClient {
    pub fn new(url: &str, token: &str) -> Self {
        let builder = HttpsConnectorBuilder::new()
            .with_native_roots()
            .unwrap_or_else(|_| HttpsConnectorBuilder::new().with_webpki_roots());
        let connector = builder.https_or_http().enable_http1().build();
        HubClient {
            url: url.trim_end_matches('/').to_string(),
            token: token.to_string(),
            client: Client::builder(TokioExecutor::new()).build(connector),
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
        let mut uri = match format!("{}{}", self.url, path).parse::<hyper::Uri>() {
            Ok(uri) => uri,
            Err(error) => return self.unreachable(error),
        };
        for redirects in 0..=10 {
            let request = match Request::builder()
                .uri(uri.clone())
                .header("authorization", format!("Bearer {}", self.token))
                .body(Empty::<Bytes>::new())
            {
                Ok(request) => request,
                Err(error) => return self.unreachable(error),
            };
            let sent =
                tokio::time::timeout(Duration::from_secs(5), self.client.request(request)).await;
            let response = match sent {
                Ok(Ok(response)) => response,
                Ok(Err(error)) => return self.unreachable(error),
                Err(_) => return self.unreachable("timed out after 5s"),
            };
            let status = response.status();
            if is_redirect(status) {
                let Some(location) = response.headers().get(hyper::header::LOCATION) else {
                    return self.http_failure(path, status);
                };
                if redirects == 10 {
                    return self.unreachable("redirect limit exceeded");
                }
                let location = match location.to_str() {
                    Ok(location) => location,
                    Err(error) => return self.unreachable(error),
                };
                uri = match redirect_uri(&uri, location) {
                    Ok(uri) => uri,
                    Err(error) => return self.unreachable(error),
                };
                continue;
            }
            if status == hyper::StatusCode::UNAUTHORIZED || status == hyper::StatusCode::FORBIDDEN {
                return GetOutcome::Refused(BridgeError(format!(
                    "the hub at {} refused the credential for {} (HTTP {}): the bridge needs a token holding the subscribe class",
                    self.url, path, status.as_u16()
                )));
            }
            if !status.is_success() {
                return self.http_failure(path, status);
            }
            let body =
                match tokio::time::timeout(Duration::from_secs(5), response.into_body().collect())
                    .await
                {
                    Ok(Ok(collected)) => collected.to_bytes(),
                    Ok(Err(error)) => return self.unreachable(error),
                    Err(_) => return self.unreachable("timed out after 5s"),
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
            return GetOutcome::Answer(answer);
        }
        unreachable!("the redirect loop always returns at its limit")
    }

    fn unreachable(&self, error: impl std::fmt::Display) -> GetOutcome {
        GetOutcome::Unreachable(HubUnreachable(format!(
            "cannot reach the hub at {}: {}",
            self.url, error
        )))
    }

    fn http_failure(&self, path: &str, status: hyper::StatusCode) -> GetOutcome {
        GetOutcome::Unreachable(HubUnreachable(format!(
            "the hub at {} answered {} with HTTP {}",
            self.url,
            path,
            status.as_u16()
        )))
    }
}

fn is_redirect(status: hyper::StatusCode) -> bool {
    matches!(
        status,
        hyper::StatusCode::MOVED_PERMANENTLY
            | hyper::StatusCode::FOUND
            | hyper::StatusCode::SEE_OTHER
            | hyper::StatusCode::TEMPORARY_REDIRECT
            | hyper::StatusCode::PERMANENT_REDIRECT
    )
}

fn redirect_uri(current: &hyper::Uri, location: &str) -> Result<hyper::Uri, String> {
    let location = location.split('#').next().unwrap_or("");
    if location.starts_with("http://") || location.starts_with("https://") {
        return location.parse().map_err(|error| format!("{error}"));
    }
    let scheme = current
        .scheme_str()
        .ok_or_else(|| "redirect source has no scheme".to_string())?;
    if location.starts_with("//") {
        return format!("{scheme}:{location}")
            .parse()
            .map_err(|error| format!("{error}"));
    }
    let authority = current
        .authority()
        .ok_or_else(|| "redirect source has no authority".to_string())?;
    let target = if location.starts_with('/') {
        location.to_string()
    } else if location.starts_with('?') {
        format!("{}{}", current.path(), location)
    } else {
        let base = current
            .path()
            .rsplit_once('/')
            .map_or("/", |(base, _)| base);
        normalize_path(&format!("{base}/{location}"))
    };
    format!("{scheme}://{authority}{target}")
        .parse()
        .map_err(|error| format!("{error}"))
}

fn normalize_path(path_and_query: &str) -> String {
    let (path, query) = path_and_query
        .split_once('?')
        .map_or((path_and_query, None), |(path, query)| (path, Some(query)));
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(part),
        }
    }
    let mut normalized = format!("/{}", parts.join("/"));
    if path.ends_with('/') && !normalized.ends_with('/') {
        normalized.push('/');
    }
    if let Some(query) = query {
        normalized.push('?');
        normalized.push_str(query);
    }
    normalized
}
