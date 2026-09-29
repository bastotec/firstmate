use base64::{engine::general_purpose::STANDARD, Engine};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

fn hub() -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_fm-stream-hub"));
    command
        .env("FM_STREAM_TOKEN", "test")
        .env_remove("FM_STREAM_TOKEN_FILE");
    command
}

struct Server {
    child: Child,
    address: String,
}

impl Server {
    fn start() -> Self {
        let mut child = hub()
            .args(["serve", "--port", "0", "--command-ack-secs", "0"])
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stderr.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        let server = Self {
            child,
            address: line.split_whitespace().last().unwrap_or("").to_owned(),
        };
        assert!(line.contains("listening on"), "{line}");
        server
    }

    fn api(&self, method: &str, path: &str, body: &str, cap: &str) -> (u16, Value) {
        let mut socket = TcpStream::connect(&self.address).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write!(
            socket,
            "{method} {path} HTTP/1.1\r\nHost: {}\r\nAuthorization: Bearer test\r\nX-Endpoint-Capability: {cap}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            self.address,
            body.len()
        )
        .unwrap();
        let mut response = String::new();
        socket.read_to_string(&mut response).unwrap();
        let (headers, body) = response.split_once("\r\n\r\n").unwrap();
        let status = headers.split_whitespace().nth(1).unwrap().parse().unwrap();
        (status, serde_json::from_str(body).unwrap())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn malformed_input_is_rejected_and_python_valid_extensions_still_reparse() {
    let server = Server::start();
    let eid = "a".repeat(32);
    let (status, registered) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker"}).to_string(),
        "",
    );
    assert_eq!(status, 201);
    let cap = registered["command_capability"].as_str().unwrap();
    let path = format!("/v1/tasks/{eid}/input");
    for invalid in ["Invalid", "NaNonsense", "-Invalid", "1e+"] {
        let raw = format!("{{\"text\":\"echo ok\",\"submit\":true,\"unused\":{invalid}}}");
        let (status, response) = server.api("POST", &path, &raw, "");
        assert_eq!(status, 400, "{response}");
        assert_eq!(response["error"], "bad_json");
    }
    let (status, response) = server.api(
        "GET",
        &format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=0"),
        "",
        cap,
    );
    assert_eq!(status, 200);
    assert_eq!(response["commands"], json!([]));
    let (status, response) = server.api(
        "POST",
        &path,
        r#"{"text":"echo ok","unused":NaN,"surrogate":"\ud800"}"#,
        "",
    );
    assert_eq!(status, 504);
    assert_eq!(response["error"], "no_agent_ack");
    assert_eq!(response["taken"], false);
}

#[tokio::test]
async fn live_stream_keeps_output_published_after_response_headers() {
    let server = Server::start();
    let eid = "b".repeat(32);
    let (status, _) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker"}).to_string(),
        "",
    );
    assert_eq!(status, 201);
    let (status, _) = server.api(
        "POST",
        "/v1/agent/frames",
        &json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"before")}]})
            .to_string(),
        "",
    );
    assert_eq!(status, 200);
    let socket = tokio::net::TcpStream::connect(&server.address)
        .await
        .unwrap();
    let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
        .await
        .unwrap();
    let connection = tokio::spawn(async move { connection.await.unwrap() });
    let response = tokio::time::timeout(
        Duration::from_secs(5),
        sender.send_request(
            hyper::Request::builder()
                .uri(format!("/v1/tasks/{eid}/stream"))
                .header("Host", &server.address)
                .header("Authorization", "Bearer test")
                .body(Full::new(Bytes::new()))
                .unwrap(),
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["Content-Type"], "text/event-stream");
    let final_output = b"final output\r\n";
    let (status, _) = server.api(
        "POST",
        "/v1/agent/frames",
        &json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(final_output),"closed":true,"exit_code":0}]}).to_string(),
        "",
    );
    assert_eq!(status, 200);
    let bytes = tokio::time::timeout(Duration::from_secs(5), response.into_body().collect())
        .await
        .unwrap()
        .unwrap()
        .to_bytes();
    let events: Vec<Value> = std::str::from_utf8(&bytes)
        .unwrap()
        .lines()
        .filter_map(|line| line.strip_prefix("data: "))
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(events.len(), 2, "{events:?}");
    assert_eq!(
        STANDARD.decode(events[0]["b64"].as_str().unwrap()).unwrap(),
        final_output
    );
    assert_eq!(events[0]["offset"], 6 + final_output.len());
    assert_eq!(events[1]["offset"], events[0]["offset"]);
    assert_eq!(events[1]["closed"], true);
    assert_eq!(events[1]["exit_code"], 0);
    drop(sender);
    tokio::time::timeout(Duration::from_secs(5), connection)
        .await
        .unwrap()
        .unwrap();
}

#[test]
fn protocol_and_version_are_top_level_only() {
    for (option, expected) in [("--protocol", "3"), ("--version", "2.0.0")] {
        let output = hub().arg(option).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), expected);
        let output = hub().args(["serve", option]).output().unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8(output.stderr)
            .unwrap()
            .contains(&format!("unrecognized or incomplete argument {option}")));
        let output = hub()
            .args(["serve", "--state-max-age-secs", option])
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert_eq!(
            String::from_utf8(output.stderr).unwrap().trim(),
            "fm-stream-hub: invalid state-max-age-secs"
        );
    }
}

#[test]
fn option_aliases_are_rejected() {
    for name in [
        "bind",
        "port",
        "token-file",
        "state-max-age-secs",
        "command-ack-secs",
        "ready-file",
        "pid-file",
    ] {
        for prefix in ["", "----", "------"] {
            let option = format!("{prefix}{name}");
            let output = hub().args(["serve", &option, "0"]).output().unwrap();
            assert!(!output.status.success(), "{option}");
            assert!(
                String::from_utf8(output.stderr)
                    .unwrap()
                    .contains(&format!("unrecognized or incomplete argument {option}")),
                "{option}"
            );
        }
    }
}

#[test]
fn documented_options_reach_value_validation() {
    let output = hub()
        .args([
            "serve",
            "--bind",
            "127.0.0.1",
            "--port",
            "0",
            "--ready-file",
            "unused-ready",
            "--pid-file",
            "unused-pid",
            "--command-ack-secs",
            "1",
            "--state-max-age-secs",
            "invalid",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        String::from_utf8(output.stderr).unwrap().trim(),
        "fm-stream-hub: invalid state-max-age-secs"
    );
}
