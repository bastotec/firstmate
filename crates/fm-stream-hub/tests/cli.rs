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
        Self::start_with_ack("0")
    }

    fn start_with_ack(ack: &str) -> Self {
        let mut child = hub()
            .args(["serve", "--port", "0", "--command-ack-secs", ack])
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
        let (status, body) = self.api_raw(method, path, body, cap);
        (status, serde_json::from_str(&body).unwrap())
    }

    fn api_raw(&self, method: &str, path: &str, body: &str, cap: &str) -> (u16, String) {
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
        (status, body.to_owned())
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

#[test]
fn deeply_nested_requests_are_refused_without_losing_hub_state() {
    let server = Server::start();
    let eid = "c".repeat(32);
    assert_eq!(
        server
            .api(
                "POST",
                "/v1/agent/endpoints",
                &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker"})
                    .to_string(),
                ""
            )
            .0,
        201
    );
    let raw = format!(
        "{{\"text\":\"echo ok\",\"unused\":{}0{}}}",
        "[".repeat(200_000),
        "]".repeat(200_000)
    );
    let (status, response) = server.api("POST", &format!("/v1/tasks/{eid}/input"), &raw, "");
    assert_eq!(status, 400);
    assert_eq!(response["error"], "bad_json");
    let (status, health) = server.api("GET", "/v1/health", "", "");
    assert_eq!(status, 200);
    assert_eq!(health["endpoints"], 1);
    let (status, tasks) = server.api("GET", "/v1/tasks", "", "");
    assert_eq!(status, 200);
    assert_eq!(tasks["tasks"][0]["endpoint_id"], eid);
}

#[test]
fn compatibility_input_preserves_literal_text_and_nonfinite_boolean_fields() {
    let server = Server::start_with_ack("5");
    let eid = "d".repeat(32);
    let (status, registered) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker"}).to_string(),
        "",
    );
    assert_eq!(status, 201);
    let cap = registered["command_capability"].as_str().unwrap();
    for literal in ["NaN", "Infinity", "-Infinity", "1e999", "-1e999"] {
        let raw = format!(r#"{{"text":"\\ud800","keys":["\ud800"],"submit":{literal}}}"#);
        std::thread::scope(|scope| {
            let input =
                scope.spawn(|| server.api("POST", &format!("/v1/tasks/{eid}/input"), &raw, ""));
            let (status, taken_raw) = server.api_raw(
                "GET",
                &format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=3"),
                "",
                cap,
            );
            assert_eq!(status, 200);
            let taken = fm_stream_wire::python_json::python_reparse(&taken_raw).unwrap();
            let command = &taken["commands"][0];
            let cid = command["command_id"].as_str().unwrap();
            assert_eq!(
                taken_raw,
                format!(
                    r#"{{"commands": [{{"command_id": "{cid}", "endpoint_id": "{eid}", "kind": "input", "payload": {{"keys": ["\ud800"], "submit": true, "text": "\\ud800"}}}}], "ok": true}}"#
                )
            );
            let result = format!(
                r#"{{"machine":"box","command_id":"{cid}","ok":{literal},"unused":"\ud800"}}"#
            );
            assert_eq!(server.api("POST", "/v1/agent/results", &result, cap).0, 200);
            assert_eq!(input.join().unwrap().0, 200);
            let conflicting = json!({"machine":"box","command_id":cid,"ok":false}).to_string();
            assert_eq!(
                server.api("POST", "/v1/agent/results", &conflicting, cap).0,
                409
            );
        });
        let frame = format!(
            r#"{{"machine":"box","frames":[{{"endpoint_id":"{eid}","state":{{"alive":{literal}}}}}],"unused":"\ud800"}}"#
        );
        assert_eq!(server.api("POST", "/v1/agent/frames", &frame, "").0, 200);
        let (status, processes) = server.api("GET", &format!("/v1/tasks/{eid}/processes"), "", "");
        assert_eq!(status, 200);
        assert_eq!(processes["alive"], true);
    }
    let (_, health) = server.api("GET", "/v1/health", "", "");
    let order = format!(
        r#"{{"leaf_worker_id":"box/worker","execution_id":"{eid}","order_id":"strict","text":"echo ok","submit":NaN,"hub_generation":{}}}"#,
        health["generation"]
    );
    let (status, refused) = server.api("POST", "/v1/orders", &order, "");
    assert_eq!(status, 400);
    assert_eq!(refused["error"], "bad_submit");
    let frame = format!(
        r#"{{"machine":"box","frames":[{{"endpoint_id":"{eid}","closed":NaN,"exit_code":0}}]}}"#
    );
    assert_eq!(server.api("POST", "/v1/agent/frames", &frame, "").0, 200);
    let (status, endpoint) = server.api("GET", &format!("/v1/tasks/{eid}"), "", "");
    assert_eq!(status, 200);
    assert_eq!(endpoint["task"]["closed_by"], "agent");
}

#[test]
fn unallocatable_screens_leave_registry_and_command_routes_healthy() {
    let server = Server::start();
    let eid = "f".repeat(32);
    for (rows, cols) in [(1, i64::MAX), (i64::MAX, 1), (i64::MAX, i64::MAX)] {
        let (status, failed) = server.api("POST", "/v1/agent/endpoints", &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","rows":rows,"cols":cols}).to_string(), "");
        assert_eq!(status, 500, "{failed}");
        let (status, health) = server.api("GET", "/v1/health", "", "");
        assert_eq!(status, 200);
        assert_eq!(health["endpoints"], 0);
        let (status, machines) = server.api("GET", "/v1/machines", "", "");
        assert_eq!(status, 200);
        assert_eq!(machines["machines"], json!([]));
    }
    let (status, registered) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","rows":2,"cols":8})
            .to_string(),
        "",
    );
    assert_eq!(status, 201);
    let cap = registered["command_capability"].as_str().unwrap();
    assert_eq!(server.api("POST", "/v1/agent/frames", &json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"ok")}]}).to_string(), "").0, 200);
    assert_eq!(
        server
            .api(
                "GET",
                &format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=0"),
                "",
                cap
            )
            .0,
        200
    );
    let (status, screen) = server.api("GET", &format!("/v1/tasks/{eid}/screen"), "", "");
    assert_eq!(status, 200);
    assert_eq!(screen["screen"], "ok\n");
}

#[test]
fn extreme_negative_csi_parameters_preserve_screen_and_fleet_state() {
    let server = Server::start();
    let eid = "e".repeat(32);
    let (status, registered) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","rows":4,"cols":8})
            .to_string(),
        "",
    );
    assert_eq!(status, 201);
    let cap = registered["command_capability"].as_str().unwrap();
    let min = i64::MIN;
    let large = "9223372036854775808";
    for (csi, row, col) in [
        (format!("{large}G"), 2, 7),
        (format!("+{large}`"), 2, 7),
        (format!("-{large}G"), 2, 0),
        (format!(" {large} G"), 2, 7),
        (format!("{large}d"), 3, 3),
        (format!("{large};{large}H"), 3, 7),
        (format!("3;{large}f"), 2, 7),
        (format!("{large};4r"), 2, 3),
        (format!("2;{large}r"), 1, 0),
        (format!("{large}C"), 2, 7),
        (format!("{large}B"), 3, 3),
        ("1.5G".into(), 2, 0),
        ("--1G".into(), 2, 0),
        ("1-2G".into(), 2, 0),
        (format!("{min}G"), 2, 0),
        (format!("{min}`"), 2, 0),
        (format!("{min}d"), 0, 3),
        (format!("{min};4H"), 0, 3),
        (format!("3;{min}H"), 2, 0),
        (format!("{min};{min}H"), 0, 0),
        (format!("{min};4f"), 0, 3),
        (format!("3;{min}f"), 2, 0),
        (format!("{min};{min}f"), 0, 0),
        (format!("{min};4r"), 0, 0),
        (format!("2;{min}r"), 2, 3),
        (format!("{min};{min}r"), 2, 3),
    ] {
        let terminal = format!("\x1bc\x1b[3;4H\x1b[{csi}x");
        let (status, published) = server.api(
            "POST",
            "/v1/agent/frames",
            &json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(terminal)}]}).to_string(),
            "",
        );
        assert_eq!(status, 200, "{csi}: {published}");
        let (status, screen) = server.api("GET", &format!("/v1/tasks/{eid}/screen"), "", "");
        assert_eq!(status, 200, "{csi}: {screen}");
        let mut expected = vec![String::new(); 4];
        expected[row] = " ".repeat(col) + "x";
        assert_eq!(screen["screen"], expected.join("\n"), "{csi}");
        assert_eq!(screen["cursor_row"], row, "{csi}");
        let (status, health) = server.api("GET", "/v1/health", "", "");
        assert_eq!(status, 200);
        assert_eq!(health["endpoints"], 1);
        let (status, commands) = server.api(
            "GET",
            &format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=0"),
            "",
            cap,
        );
        assert_eq!(status, 200);
        assert_eq!(commands["commands"], json!([]));
    }
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

#[tokio::test]
async fn idle_agent_polls_leave_the_executable_healthy_and_commands_acknowledgeable() {
    let server = std::sync::Arc::new(Server::start_with_ack("5"));
    let eid = "9".repeat(32);
    let (status, registered) = server.api(
        "POST",
        "/v1/agent/endpoints",
        &json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker"}).to_string(),
        "",
    );
    assert_eq!(status, 201);
    let cap = registered["command_capability"]
        .as_str()
        .unwrap()
        .to_owned();
    // Exceed the default blocking executor's 512 slots through the workspace
    // binary, not a server configured with an artificially smaller pool.
    let (started_tx, mut started_rx) = tokio::sync::mpsc::channel(513);
    let (result_tx, mut result_rx) = tokio::sync::mpsc::channel(513);
    let mut polls = Vec::new();
    let closing = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    for _ in 0..513 {
        let address = server.address.clone();
        let eid = eid.clone();
        let cap = cap.clone();
        let started_tx = started_tx.clone();
        let result_tx = result_tx.clone();
        let closing = closing.clone();
        // Establish connections serially so this checks executor saturation,
        // not the operating system's small incoming TCP backlog.
        let socket = tokio::net::TcpStream::connect(&address).await.unwrap();
        let (mut sender, connection) = hyper::client::conn::http1::handshake(TokioIo::new(socket))
            .await
            .unwrap();
        let connection = tokio::spawn(connection);
        polls.push(tokio::spawn(async move {
            let request = hyper::Request::builder()
                .uri(format!(
                    "/v1/agent/commands?machine=box&endpoint={eid}&wait=25"
                ))
                .header("Host", &address)
                .header("Authorization", "Bearer test")
                .header("X-Endpoint-Capability", cap)
                .header("Connection", "close")
                .body(Full::new(Bytes::new()))
                .unwrap();
            let response = sender.send_request(request);
            started_tx.send(()).await.unwrap();
            let response = response.await.unwrap();
            let status = response.status();
            let value: Value =
                serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes())
                    .unwrap();
            if status == 403 {
                // A request still entering the handler after close sees the
                // endpoint capability revoked rather than an empty poll.
                assert!(closing.load(std::sync::atomic::Ordering::SeqCst));
                assert_eq!(value["error"], "endpoint_unauthorized");
            } else {
                assert_eq!(status, 200, "{value}");
                result_tx.send(value).await.unwrap();
            }
            drop(sender);
            connection.await.unwrap().unwrap();
        }));
    }
    for _ in 0..513 {
        started_rx.recv().await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let health = server.api("GET", "/v1/health", "", "");
    assert_eq!(health.0, 200);
    let published = server.api(
        "POST",
        "/v1/agent/frames",
        &json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"still responsive")}]}).to_string(),
        "",
    );
    assert_eq!(published.0, 200);
    let control_server = server.clone();
    let control_eid = eid.clone();
    let input = tokio::task::spawn_blocking(move || {
        control_server.api(
            "POST",
            &format!("/v1/tasks/{control_eid}/input"),
            &json!({"text":"hello","submit":true}).to_string(),
            "",
        )
    });
    let taken = tokio::time::timeout(Duration::from_secs(5), result_rx.recv())
        .await
        .unwrap()
        .unwrap();
    let cid = taken["commands"][0]["command_id"].as_str().unwrap();
    let result = server.api(
        "POST",
        "/v1/agent/results",
        &json!({"machine":"box","command_id":cid,"ok":true}).to_string(),
        &cap,
    );
    assert_eq!(result.0, 200);
    let delivered = input.await.unwrap();
    assert_eq!(delivered.0, 200);
    println!(
        "513 idle polls: health={:?}; frame={:?}; acknowledgement={:?}; input={:?}",
        health, published, result, delivered
    );
    closing.store(true, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(server.api("POST", "/v1/agent/frames", &json!({"machine":"box","frames":[{"endpoint_id":eid,"closed":true,"exit_code":0}]}).to_string(), "").0, 200);
    for poll in polls {
        tokio::time::timeout(Duration::from_secs(5), poll)
            .await
            .unwrap()
            .unwrap();
    }
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
