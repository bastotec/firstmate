//! Isolated Rust hub pilot. No deployed entry point selects this binary.
mod model;
mod screen;
use base64::{engine::general_purpose::STANDARD, Engine};
use fm_stream_wire::{is_endpoint_id, is_label, is_machine_name, HUB_PROTOCOL};
use http_body_util::{combinators::BoxBody, BodyExt, Full, StreamBody};
use hyper::{
    body::{Bytes, Frame, Incoming},
    Response,
};
use model::*;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::convert::Infallible;
use std::sync::Arc;
use std::time::Duration;

struct Request {
    method: hyper::Method,
    headers: hyper::HeaderMap,
    raw: Vec<u8>,
    body_error: Option<Error>,
}
impl Request {
    fn method(&self) -> &hyper::Method {
        &self.method
    }
}

type Query = BTreeMap<String, String>;
fn header(r: &Request, name: &'static str) -> String {
    r.headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_owned()
}
fn require(h: &Hub, r: &Request, q: &Query, class: &str, allow_query: bool) -> Result<()> {
    let auth = header(r, "Authorization");
    let token = auth
        .strip_prefix("Bearer ")
        .map(str::trim)
        .unwrap_or_else(|| {
            if allow_query {
                q.get("access_token").map(String::as_str).unwrap_or("")
            } else {
                ""
            }
        });
    let granted = h.classes(token);
    if granted.is_empty() {
        return Err(Error::new(
            401,
            "unauthenticated",
            "a bearer token is required",
        ));
    }
    if !class.is_empty() && !granted.iter().any(|c| c == class) {
        return Err(Error::new(
            403,
            "wrong_token_class",
            format!("this token does not hold the '{class}' class"),
        ));
    }
    Ok(())
}
fn query_int(q: &Query, name: &str, default: i64) -> Result<i64> {
    q.get(name)
        .map(|s| {
            s.trim().parse().map_err(|_| {
                Error::new(
                    400,
                    &format!("bad_{name}"),
                    format!("{name} must be an integer"),
                )
            })
        })
        .unwrap_or(Ok(default))
}
fn body(r: &mut Request) -> Result<Value> {
    if let Some(error) = &r.body_error {
        return Err(error.clone());
    }
    let raw = &r.raw;
    if raw.is_empty() {
        return Ok(json!({}));
    }
    let text = std::str::from_utf8(raw)
        .map_err(|e| Error::new(400, "bad_json", format!("malformed JSON body: {e}")))?;
    let p = serde_json::from_str::<Value>(text).or_else(|_| {
        if let Some(error) = fm_stream_wire::python_json::python_json_error(text) {
            return Err(Error::new(
                400,
                "bad_json",
                format!("malformed JSON body: {error}"),
            ));
        }
        let mut parsed = fm_stream_wire::python_json::python_reparse(text)
            .map_err(|_| Error::new(400, "bad_json", "malformed JSON body: invalid JSON"))?;
        let truthy = fm_stream_wire::python_json::python_reparse_truthy(text)
            .map_err(|_| Error::new(400, "bad_json", "malformed JSON body: invalid JSON"))?;
        for field in ["submit", "ok"] {
            if let Some(value) = truthy.get(field) {
                parsed[field] = value.clone();
            }
        }
        if let (Some(frames), Some(truthy_frames)) = (
            parsed.get_mut("frames").and_then(Value::as_array_mut),
            truthy.get("frames").and_then(Value::as_array),
        ) {
            for (frame, truthy_frame) in frames.iter_mut().zip(truthy_frames) {
                if let Some(value) = truthy_frame.get("closed") {
                    frame["closed"] = value.clone();
                }
                if let Some(value) = truthy_frame
                    .get("state")
                    .and_then(|state| state.get("alive"))
                {
                    frame["state"]["alive"] = value.clone();
                }
            }
        }
        Ok(parsed)
    })?;
    if !p.is_object() {
        return Err(Error::new(
            400,
            "bad_json",
            "the body must be a JSON object",
        ));
    }
    Ok(p)
}
// Python JSON uses ASCII escapes and spaces in both separators.
fn encode(value: &Value) -> String {
    match value {
        Value::String(s) => {
            let mut out = String::new();
            fm_stream_wire::append_json_string(s, &mut out);
            out
        }
        Value::Array(a) => format!("[{}]", a.iter().map(encode).collect::<Vec<_>>().join(", ")),
        Value::Object(o) => format!(
            "{{{}}}",
            o.iter()
                .map(|(k, v)| format!("{}: {}", encode(&json!(k)), encode(v)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        _ => value.to_string(),
    }
}
enum Answer {
    Json(u16, Value),
    Text(String, &'static str),
    Stream(String, bool),
}
fn route(h: &Hub, r: &mut Request, path: &str, q: &Query) -> Result<Answer> {
    let method = r.method().as_str().to_owned();
    let method = method.as_str();
    let answer = |v| Ok(Answer::Json(200, v));
    if path == "/ui" && method == "GET" {
        return Ok(Answer::Text(
            include_str!("ui.html").into(),
            "text/html; charset=utf-8",
        ));
    }
    if path == "/v1/health" && method == "GET" {
        require(h, r, q, "", false)?;
        let mut s = h.state.lock().unwrap();
        Hub::reap(&mut s);
        return answer(
            json!({"ok":true,"protocol":HUB_PROTOCOL,"version":VERSION,"capabilities":CAPS,"generation":h.generation,"started_at":h.started,"endpoints":s.endpoints.len(),"state_max_age_secs":h.max_age,"command_ack_secs":h.ack}),
        );
    }
    if let Some(tail) = path.strip_prefix("/v1/agent/") {
        require(h, r, q, "publish", false)?;
        let cap = header(r, "X-Endpoint-Capability");
        if tail == "endpoints" && method == "POST" {
            return Ok(Answer::Json(201, h.register(&body(r)?, &cap)?));
        }
        if tail == "frames" && method == "POST" {
            let p = body(r)?;
            let machine = string(&p["machine"]);
            if !is_machine_name(&machine) {
                return Err(Error::new(400, "bad_machine", "malformed machine name"));
            }
            let mut s = h.state.lock().unwrap();
            Hub::touch(&mut s, &machine);
            let mut accepted = 0;
            for frame in p["frames"].as_array().into_iter().flatten() {
                if !frame.is_object() {
                    continue;
                }
                let eid = string(&frame["endpoint_id"]);
                let e = Hub::get(&s, &eid)?;
                if e.machine != machine {
                    return Err(Error::new(
                        403,
                        "endpoint_owned_elsewhere",
                        format!("endpoint {eid} belongs to machine {}", e.machine),
                    ));
                }
                let closing = truth(&frame["closed"]);
                if !closing {
                    Hub::spoke(&mut s, &eid)?;
                }
                let e = s.endpoints.get_mut(&eid).unwrap();
                if truth(&frame["b64"]) {
                    let raw=frame["b64"].as_str().ok_or_else(||Error::new(400,"bad_frame","frame payload is not valid base64: argument should be a bytes-like object or ASCII string"))?;
                    let data = STANDARD.decode(raw).map_err(|_| {
                        Error::new(
                            400,
                            "bad_frame",
                            "frame payload is not valid base64: Only base64 data is allowed",
                        )
                    })?;
                    e.feed(&data);
                }
                if frame["state"].is_object() {
                    e.state = frame["state"].clone();
                    e.received = now();
                    e.seen = e.received;
                }
                if closing {
                    e.close(frame["exit_code"].clone(), "agent");
                }
                accepted += 1;
            }
            h.wake.notify_all();
            return answer(json!({"ok":true,"accepted":accepted}));
        }
        if tail == "commands" && method == "GET" {
            let machine = q.get("machine").map(String::as_str).unwrap_or("");
            let eid = q.get("endpoint").map(String::as_str).unwrap_or("");
            if !is_machine_name(machine) {
                return Err(Error::new(400, "bad_machine", "malformed machine name"));
            }
            if !is_endpoint_id(eid) {
                return Err(Error::new(400, "bad_endpoint_id", "malformed endpoint id"));
            }
            let wait = query_int(q, "wait", 25)?.clamp(0, 120) as f64;
            return answer(json!({"ok":true,"commands":h.take(machine,eid,wait,&cap)?}));
        }
        if tail == "results" && method == "POST" {
            let p = body(r)?;
            let machine = string(&p["machine"]);
            let cid = string(&p["command_id"]);
            if !is_endpoint_id(&cid) {
                return Err(Error::new(400, "bad_command_id", "malformed command id"));
            }
            h.complete(&machine, &cid, truth(&p["ok"]), &string(&p["error"]), &cap)?;
            return answer(json!({"ok":true}));
        }
        return Err(Error::new(
            404,
            "no_such_route",
            format!("no such agent route: {path}"),
        ));
    }
    if (path == "/v1/machines" || path == "/v1/tasks") && method == "GET" {
        require(h, r, q, "subscribe", false)?;
        let mut s = h.state.lock().unwrap();
        if path == "/v1/tasks" {
            Hub::reap(&mut s);
        }
        let machines: Vec<_> = s
            .machines
            .iter()
            .map(|(name, m)| m.describe(name, h.max_age))
            .collect();
        return answer(if path == "/v1/tasks" {
            json!({"ok":true,"machines":machines,"tasks":Hub::listing(&s)})
        } else {
            json!({"ok":true,"machines":machines})
        });
    }
    if path == "/v1/orders" && method == "POST" {
        require(h, r, q, "control", false)?;
        let p = body(r)?;
        if p["hub_generation"] != h.generation {
            return Err(Error::new(
                409,
                "hub_generation_changed",
                "the order was negotiated for another hub generation",
            ));
        }
        let leaf = p["leaf_worker_id"]
            .as_str()
            .ok_or_else(|| Error::new(400, "bad_leaf", "an order needs a 'leaf_worker_id'"))?;
        if !leaf
            .split_once('/')
            .is_some_and(|(m, l)| is_machine_name(m) && is_label(l))
        {
            return Err(Error::new(
                400,
                "bad_leaf",
                "leaf_worker_id must be '<machine>/<label>'",
            ));
        }
        let execution = p["execution_id"]
            .as_str()
            .filter(|s| is_endpoint_id(s))
            .ok_or_else(|| {
                Error::new(
                    400,
                    "bad_execution",
                    "an execution_id must be 32 lowercase hex characters",
                )
            })?;
        let text = p["text"]
            .as_str()
            .ok_or_else(|| Error::new(400, "bad_input", "an order needs 'text' as a string"))?;
        if p["submit"] != true {
            return Err(Error::new(
                400,
                "bad_submit",
                "an order must set 'submit' to true",
            ));
        }
        let unexpected: Vec<_> = p
            .as_object()
            .unwrap()
            .keys()
            .filter(|k| {
                ![
                    "leaf_worker_id",
                    "execution_id",
                    "order_id",
                    "text",
                    "submit",
                    "hub_generation",
                ]
                .contains(&k.as_str())
            })
            .cloned()
            .collect();
        if !unexpected.is_empty() {
            return Err(Error::new(
                400,
                "bad_order_fields",
                format!("unsupported order fields: {}", unexpected.join(", ")),
            ));
        }
        let oid = p["order_id"]
            .as_str()
            .filter(|s| is_machine_name(s))
            .ok_or_else(|| {
                Error::new(
                    400,
                    "bad_order_id",
                    "an order_id must be 1-128 characters of [A-Za-z0-9._-]",
                )
            })?;
        return answer(h.place(leaf, execution, text, oid)?);
    }
    if let Some(rest) = path.strip_prefix("/v1/tasks/") {
        let (eid, tail) = rest.split_once('/').unwrap_or((rest, ""));
        if !is_endpoint_id(eid) {
            return Err(Error::new(
                404,
                "no_such_endpoint",
                format!("no endpoint {eid}"),
            ));
        }
        if tail.is_empty() && method == "DELETE" {
            require(h, r, q, "control", false)?;
            let result = h.submit(eid, "kill", json!({"signal":"TERM"}), None);
            let mut delivered = true;
            if let Err(e) = result {
                if e.code != "no_agent_ack" {
                    return Err(e);
                }
                let mut s = h.state.lock().unwrap();
                s.endpoints.get_mut(eid).unwrap().close(Value::Null, "hub");
                h.wake.notify_all();
                delivered = false;
            }
            let s = h.state.lock().unwrap();
            let e = Hub::get(&s, eid)?;
            return answer(
                json!({"ok":true,"closed":eid,"machine":e.machine,"delivered":delivered}),
            );
        }
        let steering = method == "POST" && (tail == "input" || tail == "status");
        require(
            h,
            r,
            q,
            if steering { "control" } else { "subscribe" },
            method == "GET" && tail == "stream",
        )?;
        {
            let s = h.state.lock().unwrap();
            Hub::get(&s, eid)?;
        }
        if tail == "input" && method == "POST" {
            let p = body(r)?;
            if p["text"].is_null() && p["keys"].is_null() {
                return Err(Error::new(
                    400,
                    "bad_input",
                    "an input needs 'text' or 'keys'",
                ));
            }
            h.submit(
                eid,
                "input",
                json!({"text":p["text"],"keys":p["keys"],"submit":truth(&p["submit"])}),
                None,
            )?;
            return answer(json!({"ok":true,"delivered":eid}));
        }
        if tail == "status" && method == "POST" {
            let p = body(r)?;
            let state = string(&p["state"]);
            let states = [
                "working",
                "needs-decision",
                "blocked",
                "paused",
                "done",
                "failed",
                "resolved",
            ];
            if !states.contains(&state.as_str()) {
                return Err(Error::new(
                    400,
                    "bad_state",
                    format!(
                        "unknown status state {} (known: {})",
                        fm_stream_wire::python_repr_value(&json!(state)),
                        states.join(", ")
                    ),
                ));
            }
            h.submit(eid,"status",json!({"state":state,"note":if truth(&p["note"]) {p["note"].clone()} else {json!("")}}),None)?;
            return answer(json!({"ok":true,"appended":eid}));
        }
        let s = h.state.lock().unwrap();
        let e = Hub::get(&s, eid)?;
        if method == "GET" {
            let ansi = q.get("format").is_some_and(|s| s == "ansi");
            match tail {
                "" => return answer(json!({"ok":true,"task":e.describe()})),
                "capture" => {
                    let n = query_int(q, "lines", 40)?.clamp(1, 2000) as usize;
                    return Ok(Answer::Text(
                        e.screen.tail(n, ansi).join("\n") + "\n",
                        "text/plain; charset=utf-8",
                    ));
                }
                "screen" => {
                    return answer(
                        json!({"ok":true,"cursor_row":e.screen.cy,"screen":e.screen.lines(ansi).join("\n")}),
                    )
                }
                "stream" => {
                    return Ok(Answer::Stream(
                        eid.into(),
                        q.get("replay")
                            .is_some_and(|s| ["1", "true", "yes"].contains(&s.as_str())),
                    ))
                }
                "processes" | "cwd" => {
                    let age = e.age();
                    let silent = e.silent();
                    let machine_silent =
                        s.machines.get(&e.machine).map(|m| (now() - m.seen).max(0.));
                    let stale = age.is_none_or(|age| age > h.max_age) || silent > h.max_age;
                    let mut v = json!({"ok":true,"endpoint_id":eid,"machine":e.machine,"stale":stale,"state_age_secs":age.map(rounded),"agent_silent_for_secs":rounded(silent),"machine_silent_for_secs":machine_silent.map(rounded),"state_max_age_secs":h.max_age,"closed":e.closed>0.,"closed_by":if e.closed_by.is_empty() {Value::Null} else {json!(e.closed_by)},"exit_code":e.exit});
                    if stale {
                        v["reason"] = json!(if age.is_none() {
                            "no state frame yet".into()
                        } else if silent > h.max_age {
                            format!(
                                "the owning agent on machine {} has been silent for {silent:.1}s",
                                e.machine
                            )
                        } else {
                            format!(
                                "the last state frame is {:.1}s old",
                                age.unwrap_or_default()
                            )
                        });
                    } else {
                        v["alive"] = json!(truth(&e.state["alive"]));
                        if tail == "processes" {
                            if e.state.get("tokens").is_some() || e.state.get("messages").is_some()
                            {
                                for key in ["seq", "tokens", "messages"] {
                                    if let Some(value) = e.state.get(key) {
                                        v[key] = value.clone();
                                    }
                                }
                            }
                            v["foreground"] = if truth(&e.state["foreground"]) {
                                e.state["foreground"].clone()
                            } else {
                                json!([])
                            };
                        } else {
                            v["cwd"] = if truth(&e.state["cwd"]) {
                                e.state["cwd"].clone()
                            } else {
                                json!("")
                            };
                        }
                    }
                    return answer(v);
                }
                _ => (),
            }
        }
        return Err(Error::new(
            404,
            "no_such_route",
            format!(
                "no such endpoint route: {}",
                if tail.is_empty() { "/" } else { tail }
            ),
        ));
    }
    Err(Error::new(
        404,
        "no_such_route",
        format!("no such route: {path}"),
    ))
}
type HttpBody = BoxBody<Bytes, Infallible>;
fn stream(h: Arc<Hub>, eid: String, replay: bool) -> HttpBody {
    let mut offset = {
        let s = h.state.lock().unwrap();
        if replay {
            0
        } else {
            s.endpoints.get(&eid).map(|e| e.end).unwrap_or(0)
        }
    };
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    std::thread::spawn(move || loop {
        let mut s = h.state.lock().unwrap();
        let deadline = now() + 15.;
        loop {
            let Some(e) = s.endpoints.get(&eid) else {
                return;
            };
            if e.end > offset || e.closed > 0. || now() >= deadline || tx.is_closed() {
                break;
            }
            s = h
                .wake
                .wait_timeout(s, Duration::from_secs_f64((deadline - now()).clamp(0., 1.)))
                .unwrap()
                .0;
        }
        if tx.is_closed() {
            return;
        }
        let Some(e) = s.endpoints.get(&eid) else {
            return;
        };
        let (start, data) = e.bytes(offset);
        let closed = e.closed > 0.;
        let terminal = closed && data.is_empty();
        let record = if !data.is_empty() {
            offset = start + data.len() as u64;
            format!(
                "data: {{\"offset\": {offset}, \"machine\": {}, \"b64\": {}}}\n\n",
                encode(&json!(e.machine)),
                encode(&json!(STANDARD.encode(data)))
            )
        } else if closed {
            format!(
                "data: {{\"offset\": {offset}, \"closed\": true, \"exit_code\": {}}}\n\n",
                encode(&e.exit)
            )
        } else {
            ": keepalive\n\n".into()
        };
        drop(s);
        if tx
            .blocking_send(Ok(Frame::data(Bytes::from(record))))
            .is_err()
            || terminal
        {
            return;
        }
    });
    StreamBody::new(tokio_stream::wrappers::ReceiverStream::new(rx)).boxed()
}
async fn handle(
    h: Arc<Hub>,
    request: hyper::Request<Incoming>,
) -> std::result::Result<Response<HttpBody>, Infallible> {
    let (parts, mut incoming) = request.into_parts();
    let raw_url = parts.uri.to_string();
    let (path, query) = raw_url.split_once('?').unwrap_or((&raw_url, ""));
    let path = path.trim_end_matches('/');
    let path = if path.is_empty() { "/" } else { path };
    let mut q = Query::new();
    for (k, v) in form_urlencoded::parse(query.as_bytes()) {
        if !v.is_empty() {
            q.entry(k.into_owned()).or_insert(v.into_owned());
        }
    }
    let length = parts
        .headers
        .get("Content-Length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<usize>().ok());
    let oversized = length.is_some_and(|n| n > 4 * 1024 * 1024);
    let mut r = Request {
        method: parts.method,
        headers: parts.headers,
        raw: Vec::new(),
        body_error: None,
    };
    let mut close = oversized;
    if oversized {
        r.body_error = Some(Error::new(
            413,
            "body_too_large",
            "request body exceeds 4194304 bytes",
        ));
    } else {
        while let Some(frame) = incoming.frame().await {
            match frame {
                Ok(frame) => {
                    if let Ok(data) = frame.into_data() {
                        if r.raw.len() + data.len() > 4 * 1024 * 1024 {
                            r.body_error = Some(Error::new(
                                413,
                                "body_too_large",
                                "request body exceeds 4194304 bytes",
                            ));
                            close = true;
                            break;
                        }
                        r.raw.extend_from_slice(&data);
                    }
                }
                Err(_) => {
                    r.body_error = Some(Error::new(400, "bad_length", "malformed Content-Length"));
                    close = true;
                    break;
                }
            }
        }
    }
    let owned_path = path.to_owned();
    let route_h = h.clone();
    let answer = tokio::task::spawn_blocking(move || {
        route(&route_h, &mut r, &owned_path, &q)
            .unwrap_or_else(|e| Answer::Json(e.status, e.body()))
    })
    .await
    .unwrap_or_else(|_| {
        Answer::Json(
            500,
            json!({"ok":false,"error":"internal","message":"request handler failed"}),
        )
    });
    let (status, content, ctype) = match answer {
        Answer::Json(status, v) => (
            status,
            Full::new(Bytes::from(encode(&v))).boxed(),
            "application/json",
        ),
        Answer::Text(text, ctype) => (200, Full::new(Bytes::from(text)).boxed(), ctype),
        Answer::Stream(eid, replay) => {
            close = true;
            (200, stream(h, eid, replay), "text/event-stream")
        }
    };
    let mut response = Response::builder()
        .status(status)
        .header("Content-Type", ctype)
        .header("Cache-Control", "no-store")
        .header("Server", "fm-stream-hub/2.0.0");
    if close {
        response = response.header("Connection", "close");
    }
    Ok(response.body(content).unwrap())
}
fn tokens(path: &str) -> std::result::Result<Vec<(String, Vec<String>)>, String> {
    if path.is_empty() {
        let token = std::env::var("FM_STREAM_TOKEN").unwrap_or_default();
        if token.is_empty() {
            return Err("no credential; pass --token-file or set FM_STREAM_TOKEN. The hub never serves unauthenticated.".into());
        }
        return Ok(vec![(
            token,
            vec!["publish".into(), "subscribe".into(), "control".into()],
        )]);
    }
    let data = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read --token-file {path}: {e}"))?;
    let mut tokens: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (n, line) in data.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (token, classes) = if let Some((classes, token)) = line.split_once(':') {
            let names: Vec<String> = classes
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
            for name in &names {
                if !["publish", "subscribe", "control"].contains(&name.as_str()) {
                    return Err(format!("{path} line {}: unknown token class '{name}' (known: publish,subscribe,control)",n+1));
                }
            }
            if names.is_empty() || token.trim().is_empty() {
                return Err(format!(
                    "{path} line {}: token line {}",
                    n + 1,
                    if names.is_empty() {
                        "names no classes"
                    } else {
                        "has an empty token"
                    }
                ));
            }
            (token.trim(), names)
        } else {
            (line, vec!["subscribe".into()])
        };
        let entry = tokens.entry(token.into()).or_default();
        for class in classes {
            if !entry.contains(&class) {
                entry.push(class);
            }
        }
    }
    if tokens.is_empty() {
        return Err(format!(
            "{path} defines no tokens; the hub refuses to serve unauthenticated"
        ));
    }
    Ok(tokens.into_iter().collect())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("fm-stream-hub: {e}");
        std::process::exit(1);
    }
}
fn run() -> std::result::Result<(), String> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|s| s == "--protocol") {
        println!("{HUB_PROTOCOL}");
        return Ok(());
    }
    if args.first().is_some_and(|s| s == "--version") {
        println!("{VERSION}");
        return Ok(());
    }
    if args.first().is_none_or(|s| s != "serve") || args.iter().any(|s| s == "--help" || s == "-h")
    {
        println!("fm-stream-hub serve [--bind ADDR] [--port N] [--token-file PATH] [--state-max-age-secs N] [--command-ack-secs N] [--ready-file PATH] [--pid-file PATH]\nIsolated Rust pilot; docs/stream-backend.md owns deployment prerequisites.");
        return Ok(());
    }
    let mut opts = BTreeMap::new();
    let mut i = 1;
    while i < args.len() {
        let key = args[i].as_str();
        if ![
            "--bind",
            "--port",
            "--token-file",
            "--state-max-age-secs",
            "--command-ack-secs",
            "--ready-file",
            "--pid-file",
        ]
        .contains(&key)
            || i + 1 >= args.len()
        {
            return Err(format!("unrecognized or incomplete argument {}", args[i]));
        }
        opts.insert(key.to_owned(), args[i + 1].clone());
        i += 2;
    }
    let opt = |name: &str, default: &str| {
        opts.get(&format!("--{name}"))
            .cloned()
            .unwrap_or_else(|| default.into())
    };
    let parse = |name: &str, default: &str| -> std::result::Result<f64, String> {
        let n = opt(name, default)
            .parse::<f64>()
            .map_err(|_| format!("invalid {name}"))?;
        if !n.is_finite() || n < 0. {
            return Err(format!("invalid {name}"));
        }
        Ok(n)
    };
    let hub = Hub::new(
        tokens(&opt(
            "token-file",
            &std::env::var("FM_STREAM_TOKEN_FILE").unwrap_or_default(),
        ))?,
        parse("state-max-age-secs", "30")?,
        parse("command-ack-secs", "20")?,
    );
    let bind = opt("bind", "127.0.0.1");
    let port = opt("port", "7717");
    let socket = std::net::TcpListener::bind(format!("{bind}:{port}"))
        .map_err(|e| format!("cannot listen on {bind}:{port}: {e}"))?;
    socket.set_nonblocking(true).map_err(|e| e.to_string())?;
    let addr = socket.local_addr().map_err(|e| e.to_string())?;
    let ready = opt("ready-file", "");
    let pid = opt("pid-file", "");
    if !pid.is_empty() {
        std::fs::write(&pid, format!("{}\n", std::process::id())).map_err(|e| e.to_string())?;
    }
    if !ready.is_empty() {
        std::fs::write(&ready, format!("{} {}\n", addr.ip(), addr.port()))
            .map_err(|e| e.to_string())?;
    }
    eprintln!("fm-stream-hub {VERSION} protocol {HUB_PROTOCOL} listening on {addr}");
    let stopping = Arc::new(std::sync::atomic::AtomicBool::new(false));
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        signal_hook::flag::register(signal, stopping.clone()).map_err(|e| e.to_string())?;
    }
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let result = runtime.block_on(async {
        let listener = tokio::net::TcpListener::from_std(socket).map_err(|e| e.to_string())?;
        while !stopping.load(std::sync::atomic::Ordering::Relaxed) {
            if let Ok(accepted) =
                tokio::time::timeout(Duration::from_millis(200), listener.accept()).await
            {
                let (socket, _) = accepted.map_err(|e| e.to_string())?;
                let h = hub.clone();
                tokio::spawn(async move {
                    let service =
                        hyper::service::service_fn(move |request| handle(h.clone(), request));
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(hyper_util::rt::TokioIo::new(socket), service)
                        .await;
                });
            }
        }
        Ok::<(), String>(())
    });
    runtime.shutdown_background();
    result?;
    for path in [ready, pid] {
        if !path.is_empty() {
            let _ = std::fs::remove_file(path);
        }
    }
    Ok(())
}
