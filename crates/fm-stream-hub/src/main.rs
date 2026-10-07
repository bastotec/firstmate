//! Native fleet hub. Deployment selection and limits: docs/stream-backend.md.
mod model;
mod payload;
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
use std::time::{Duration, Instant};

struct Request {
    method: hyper::Method,
    headers: hyper::HeaderMap,
    raw: Vec<u8>,
    body_error: Option<Error>,
}
impl Request {
    fn forwarded(&self) -> Result<payload::Json> {
        if let Some(error) = &self.body_error {
            return Err(error.clone());
        }
        let text = if self.raw.is_empty() {
            "{}"
        } else {
            std::str::from_utf8(&self.raw)
                .map_err(|e| Error::new(400, "bad_json", format!("malformed JSON body: {e}")))?
        };
        let parsed = payload::Json::parse(text)?;
        if !matches!(parsed, payload::Json::Object(_)) {
            return Err(Error::new(
                400,
                "bad_json",
                "the body must be a JSON object",
            ));
        }
        Ok(parsed)
    }
    fn command_body(&self, fields: &[&str]) -> Result<(Value, payload::Json)> {
        let forwarded = self.forwarded()?;
        // Only consumed controls need serde values. Opaque worker input must not
        // inherit serde's recursive parsing limit or lossy compatibility rewrite.
        let controls = fields
            .iter()
            .map(|field| (*field, forwarded.get(field).encode()))
            .collect::<Vec<_>>();
        let parsed = parse_body(&payload::object(&controls))?;
        Ok((parsed, forwarded))
    }
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
    parse_body(text)
}
fn parse_body(text: &str) -> Result<Value> {
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
    Stream(String, bool, Option<u64>),
    TaskEvents,
}
/// The largest PTY geometry a resize accepts, per side.
const MAX_GEOMETRY: u16 = 1000;
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
                if !frame["geometry"].is_null() {
                    let side = |name: &str| -> Result<usize> {
                        frame["geometry"][name]
                            .as_u64()
                            .filter(|v| *v > 0 && *v <= u64::from(MAX_GEOMETRY))
                            .map(|v| v as usize)
                            .ok_or_else(|| {
                                Error::new(
                                    400,
                                    "bad_geometry",
                                    "geometry must have rows and cols in 1-1000",
                                )
                            })
                    };
                    let (rows, cols) = (side("rows")?, side("cols")?);
                    e.screen.resize(rows, cols);
                    e.rows = rows;
                    e.cols = cols;
                }
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
            let commands = h.take(machine, eid, wait, &cap)?;
            return Ok(Answer::Text(
                format!("{{\"commands\": [{}], \"ok\": true}}", commands.join(", ")),
                "application/json",
            ));
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
    if let Some(encoded_id) = path.strip_prefix("/v1/orders/").filter(|_| method == "GET") {
        require(h, r, q, "subscribe", false)?;
        // Use the existing URL decoder with path (not form) '+' semantics.
        let query = format!("id={}", encoded_id.replace('+', "%2B").replace('&', "%26"));
        let order_id = form_urlencoded::parse(query.as_bytes())
            .next()
            .map(|(_, value)| value.into_owned())
            .unwrap_or_default();
        let s = h.state.lock().unwrap();
        let mut record = None;
        for order in &s.orders {
            let order = order.lock().unwrap();
            if order.id == order_id {
                record = Some(Hub::order_record(&s, &order));
                break;
            }
        }
        let mut record = record.ok_or_else(|| {
            Error::new(
                404,
                "no_such_order",
                "this order id is not in the bounded journal",
            )
        })?;
        record["ok"] = json!(true);
        return answer(record);
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
        p["text"]
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
        return answer(h.place_encoded(
            leaf,
            execution,
            &r.forwarded()?.get("text").encode(),
            oid,
        )?);
    }
    if path == "/v1/tasks/events" && method == "GET" {
        require(h, r, q, "subscribe", false)?;
        return Ok(Answer::TaskEvents);
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
            return answer(h.delete(eid)?);
        }
        let steering =
            method == "POST" && (tail == "input" || tail == "status" || tail == "resize");
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
            let (p, forwarded) = r.command_body(&["submit", "b64"])?;
            // Raw bytes for interactive attach: keystrokes that are not UTF-8
            // text. Validated here so the agent only ever sees real base64.
            let raw = match &p["b64"] {
                Value::Null => None,
                Value::String(b64) if STANDARD.decode(b64).is_ok_and(|b| !b.is_empty()) => {
                    Some(b64.clone())
                }
                _ => {
                    return Err(Error::new(
                        400,
                        "bad_input",
                        "'b64' must be non-empty base64",
                    ))
                }
            };
            if matches!(forwarded.get("text"), payload::Json::Null)
                && matches!(forwarded.get("keys"), payload::Json::Null)
                && raw.is_none()
            {
                return Err(Error::new(
                    400,
                    "bad_input",
                    "an input needs 'text', 'keys' or 'b64'",
                ));
            }
            let mut fields = vec![
                ("text", forwarded.get("text").encode()),
                ("keys", forwarded.get("keys").encode()),
                ("submit", truth(&p["submit"]).to_string()),
            ];
            // Only present when used, so ordinary inputs forward the same
            // bytes the Python hub forwards.
            if let Some(b64) = raw {
                fields.push(("b64", encode(&json!(b64))));
            }
            h.submit_encoded(eid, "input", payload::object(&fields))?;
            return answer(json!({"ok":true,"delivered":eid}));
        }
        if tail == "resize" && method == "POST" {
            let (p, _) = r.command_body(&["rows", "cols"])?;
            let bound = |name: &str| -> Result<u16> {
                let value = positive(&p[name], 0, name)?;
                u16::try_from(value)
                    .ok()
                    .filter(|v| *v <= MAX_GEOMETRY)
                    .ok_or_else(|| {
                        Error::new(
                            400,
                            &format!("bad_{name}"),
                            format!("{name} must be 1-{MAX_GEOMETRY}"),
                        )
                    })
            };
            if p["rows"].is_null() || p["cols"].is_null() {
                return Err(Error::new(
                    400,
                    "bad_resize",
                    "a resize needs 'rows' and 'cols'",
                ));
            }
            let (rows, cols) = (bound("rows")?, bound("cols")?);
            h.submit_encoded(
                eid,
                "resize",
                payload::object(&[("rows", rows.to_string()), ("cols", cols.to_string())]),
            )?;
            return answer(json!({"ok":true,"resized":eid,"rows":rows,"cols":cols}));
        }
        if tail == "status" && method == "POST" {
            let (p, forwarded) = r.command_body(&["state"])?;
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
            let note = forwarded.get("note");
            h.submit_encoded(
                eid,
                "status",
                payload::object(&[
                    ("state", encode(&json!(state))),
                    (
                        "note",
                        if note.truth() {
                            note.encode()
                        } else {
                            encode(&json!(""))
                        },
                    ),
                ]),
            )?;
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
                // What an interactive attach paints first: the rendered
                // screen, the cursor, the geometry, and the stream offset that
                // screen already includes, all read under one lock so the
                // stream can resume exactly after it.
                "snapshot" => {
                    return answer(json!({
                        "ok":true,
                        "screen":e.screen.lines(true).join("\n"),
                        "cursor_row":e.screen.cy,
                        "cursor_col":e.screen.cursor_col(),
                        "rows":e.rows,
                        "cols":e.cols,
                        "stream_offset":e.end.saturating_sub(e.screen.pending_len() as u64),
                    }))
                }
                "stream" => {
                    let from = match q.get("from") {
                        None => None,
                        Some(raw) => Some(raw.parse::<u64>().map_err(|_| {
                            Error::new(400, "bad_from", "from must be a stream offset")
                        })?),
                    };
                    return Ok(Answer::Stream(
                        eid.into(),
                        q.get("replay")
                            .is_some_and(|s| ["1", "true", "yes"].contains(&s.as_str())),
                        from,
                    ));
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
fn check_stream_offset(e: &Endpoint, offset: u64) -> Result<()> {
    let oldest = e.end - e.ring.len() as u64;
    if offset < oldest || offset > e.end {
        return Err(Error::new(
            409,
            "stream_continuity_error",
            format!(
                "stream continuity lost: offset {offset} is outside retained range {oldest}..={}",
                e.end
            ),
        ));
    }
    Ok(())
}
fn stream(h: Arc<Hub>, eid: String, replay: bool, from: Option<u64>) -> Result<HttpBody> {
    let (incarnation, mut offset) = {
        let s = h.state.lock().unwrap();
        let endpoint = s.endpoints.get(&eid);
        if let Some(from) = from {
            check_stream_offset(Hub::get(&s, &eid)?, from)?;
        }
        (
            endpoint.map(|e| e.created),
            if let Some(from) = from {
                from
            } else if replay {
                0
            } else {
                endpoint.map(|e| e.end).unwrap_or(0)
            },
        )
    };
    let (tx, rx) = tokio::sync::mpsc::channel(1);
    std::thread::spawn(move || loop {
        let mut s = h.state.lock().unwrap();
        let deadline = now() + 15.;
        loop {
            let Some(e) = s
                .endpoints
                .get(&eid)
                .filter(|e| Some(e.created) == incarnation)
            else {
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
        let Some(e) = s
            .endpoints
            .get(&eid)
            .filter(|e| Some(e.created) == incarnation)
        else {
            return;
        };
        if from.is_some() {
            if let Err(error) = check_stream_offset(e, offset) {
                let record = format!("data: {}\n\n", encode(&error.body()));
                drop(s);
                let _ = tx.blocking_send(Ok(Frame::data(Bytes::from(record))));
                return;
            }
        }
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
    Ok(StreamBody::new(tokio_stream::wrappers::ReceiverStream::new(rx)).boxed())
}
/// One event-stream record, `event: <kind>` then the JSON on one `data:` line.
fn event_record(kind: &str, data: &Value) -> Bytes {
    Bytes::from(format!("event: {kind}\ndata: {}\n\n", encode(data)))
}
/// What one subscriber was last told about one endpoint: its projection, and
/// the output offset it saw with when that offset was sent.
struct Told {
    projection: String,
    offset: u64,
    offset_at: f64,
}
/// `GET /v1/tasks/events`: the `/v1/tasks` listing once, then a delta carrying
/// each endpoint record whose projection changed, whose output grew (at most
/// once per EVENT_OUTPUT_SECS per endpoint), or that left the registry.
/// Registry evaluations are spaced at least 25 ms apart to bound wake-driven work.
/// docs/stream-backend.md "Task events" owns the contract.
fn task_events(h: Arc<Hub>) -> HttpBody {
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    std::thread::spawn(move || {
        let mut told: BTreeMap<String, Told> = BTreeMap::new();
        let mut seq = 0u64;
        let mut last_reap = 0f64;
        let mut last_sent = now();
        let mut wait = 0f64;
        let mut last_evaluation = Instant::now();
        loop {
            let mut s = h.state.lock().unwrap();
            if seq > 0 {
                s = h
                    .wake
                    .wait_timeout(s, Duration::from_secs_f64(wait.clamp(0.001, 1.)))
                    .unwrap()
                    .0;
                if let Some(remaining) =
                    Duration::from_millis(25).checked_sub(last_evaluation.elapsed())
                {
                    drop(s);
                    std::thread::sleep(remaining);
                    s = h.state.lock().unwrap();
                }
            }
            if tx.is_closed() {
                return;
            }
            last_evaluation = Instant::now();
            let at = now();
            if at - last_reap >= 1. {
                Hub::reap(&mut s);
                last_reap = at;
            }
            let ordered = Hub::ordered(&s);
            let mut changed = Vec::new();
            let mut next = last_sent + 15.;
            for (e, current) in &ordered {
                let projection = e.projection(*current);
                let fresh = match told.get(&e.id) {
                    None => true,
                    Some(t) if t.projection != projection => true,
                    Some(t) if t.offset != e.end => {
                        let due = t.offset_at + EVENT_OUTPUT_SECS;
                        next = next.min(due);
                        at >= due
                    }
                    Some(_) => false,
                };
                if e.closed == 0. && rounded(e.silent()) <= PRESUMED_SECS {
                    next = next.min(e.seen + PRESUMED_SECS + 0.002);
                }
                if fresh {
                    let offset_at = match told.get(&e.id) {
                        None => 0.,
                        Some(t) if t.offset == e.end => t.offset_at,
                        Some(_) => at,
                    };
                    told.insert(
                        e.id.clone(),
                        Told {
                            projection,
                            offset: e.end,
                            offset_at,
                        },
                    );
                    changed.push(Hub::record(e, *current));
                }
            }
            let removed: Vec<String> = told
                .keys()
                .filter(|id| !s.endpoints.contains_key(*id))
                .cloned()
                .collect();
            for id in &removed {
                told.remove(id);
            }
            let record = if seq == 0 {
                let machines: Vec<_> = s
                    .machines
                    .iter()
                    .map(|(name, m)| m.describe(name, h.max_age))
                    .collect();
                Some(event_record(
                    "snapshot",
                    &json!({"ok":true,"seq":1,"generation":h.generation,"machines":machines,"tasks":changed}),
                ))
            } else if !changed.is_empty() || !removed.is_empty() {
                Some(event_record(
                    "delta",
                    &json!({"seq":seq + 1,"generation":h.generation,"tasks":changed,"removed":removed}),
                ))
            } else if at - last_sent >= 15. {
                Some(Bytes::from_static(b": keepalive\n\n"))
            } else {
                None
            };
            drop(s);
            if let Some(record) = record {
                if !record.starts_with(b":") {
                    seq += 1;
                }
                last_sent = at;
                next = next.min(at + 15.);
                if tx.blocking_send(Ok(Frame::data(record))).is_err() {
                    return;
                }
            }
            wait = next - now();
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
    let (tx, rx) = tokio::sync::oneshot::channel();
    let spawned = std::thread::Builder::new().spawn(move || {
        let answer = route(&route_h, &mut r, &owned_path, &q)
            .unwrap_or_else(|e| Answer::Json(e.status, e.body()));
        let _ = tx.send(answer);
    });
    let answer = if spawned.is_ok() { rx.await.ok() } else { None }.unwrap_or_else(|| {
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
        Answer::TaskEvents => {
            close = true;
            (200, task_events(h), "text/event-stream")
        }
        Answer::Stream(eid, replay, from) => {
            close = true;
            match stream(h, eid, replay, from) {
                Ok(body) => (200, body, "text/event-stream"),
                Err(error) => (
                    error.status,
                    Full::new(Bytes::from(encode(&error.body()))).boxed(),
                    "application/json",
                ),
            }
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
        println!("fm-stream-hub serve [--bind ADDR] [--port N] [--token-file PATH] [--state-max-age-secs N] [--command-ack-secs N] [--ready-file PATH] [--pid-file PATH]\nNative stream hub; docs/stream-backend.md owns deployment and rollback.");
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
                // Output is pushed to subscribers as it arrives, often a few
                // bytes of echo: never let Nagle hold it for an ACK.
                let _ = socket.set_nodelay(true);
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

#[cfg(test)]
mod tests {
    use super::*;

    async fn server(h: Arc<Hub>) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                let h = h.clone();
                tokio::spawn(async move {
                    let service = hyper::service::service_fn(move |r| handle(h.clone(), r));
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(hyper_util::rt::TokioIo::new(socket), service)
                        .await;
                });
            }
        });
        (address, task)
    }

    async fn request(
        address: std::net::SocketAddr,
        method: &str,
        path: &str,
        body: Value,
        cap: &str,
    ) -> Response<Incoming> {
        let socket = tokio::net::TcpStream::connect(address).await.unwrap();
        let (mut sender, connection) =
            hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(socket))
                .await
                .unwrap();
        tokio::spawn(async move {
            let _ = connection.await;
        });
        sender
            .send_request(
                hyper::Request::builder()
                    .method(method)
                    .uri(path)
                    .header("Host", address.to_string())
                    .header("Authorization", "Bearer test")
                    .header("X-Endpoint-Capability", cap)
                    .header("Connection", "close")
                    .body(Full::new(Bytes::from(body.to_string())))
                    .unwrap(),
            )
            .await
            .unwrap()
    }

    async fn json_response(response: Response<Incoming>) -> (u16, Value) {
        let status = response.status().as_u16();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap())
    }

    fn fixture() -> (Arc<Hub>, String, String) {
        let h = Hub::new(
            vec![(
                "test".into(),
                vec!["publish".into(), "subscribe".into(), "control".into()],
            )],
            30.,
            3.,
        );
        let eid = "a".repeat(32);
        let registered = h.register(&json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","rows":2,"cols":8}), "").unwrap();
        let cap = registered["command_capability"]
            .as_str()
            .unwrap()
            .to_owned();
        (h, eid, cap)
    }

    async fn taken_http_order(
        address: std::net::SocketAddr,
        eid: &str,
        cap: &str,
        generation: &str,
        oid: &str,
    ) -> String {
        let payload = json!({"leaf_worker_id":"box/worker","execution_id":eid,
            "hub_generation":generation,"order_id":oid,"text":"hello","submit":true});
        let placement = tokio::spawn(async move {
            json_response(request(address, "POST", "/v1/orders", payload, "").await).await
        });
        let path = format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=1");
        let (status, commands) =
            json_response(request(address, "GET", &path, json!({}), cap).await).await;
        assert_eq!(status, 200);
        assert_eq!(commands["commands"].as_array().unwrap().len(), 1);
        let (status, record) = placement.await.unwrap();
        assert_eq!(status, 504, "{record}");
        assert_eq!(record["outcome"], "unconfirmed");
        commands["commands"][0]["command_id"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    #[tokio::test]
    async fn interactive_resize_and_raw_input_reach_the_agent_over_http() {
        let h = Hub::new(
            vec![(
                "test".into(),
                vec!["publish".into(), "subscribe".into(), "control".into()],
            )],
            30.,
            5.,
        );
        let (address, server) = server(h.clone()).await;
        let eid = "b".repeat(32);
        let (status, registration) = json_response(request(address, "POST", "/v1/agent/endpoints",
            json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"attach","rows":24,"cols":80,
                "capabilities":["idempotent_command_results"]}), "").await).await;
        assert_eq!(status, 201);
        let cap = registration["command_capability"]
            .as_str()
            .unwrap()
            .to_owned();
        let place = |tail: &'static str, body: Value| {
            let path = format!("/v1/tasks/{eid}/{tail}");
            tokio::spawn(async move {
                json_response(request(address, "POST", &path, body, "").await).await
            })
        };
        let take = format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=3");
        for (tail, body, kind, expected) in [
            (
                "resize",
                json!({"rows":30,"cols":100}),
                "resize",
                json!({"rows":30,"cols":100}),
            ),
            (
                "input",
                json!({"b64":"/3g="}),
                "input",
                json!({"text":null,"keys":null,"submit":false,"b64":"/3g="}),
            ),
            (
                "input",
                json!({"text":"x"}),
                "input",
                json!({"text":"x","keys":null,"submit":false}),
            ),
        ] {
            let placed = place(tail, body);
            let (_, taken) =
                json_response(request(address, "GET", &take, json!({}), &cap).await).await;
            let command = &taken["commands"][0];
            assert_eq!(command["kind"], kind, "{taken}");
            assert_eq!(command["payload"], expected, "{taken}");
            if kind == "resize" {
                let frame = json!({"machine":"box","frames":[
                    {"endpoint_id":eid,"geometry":{"rows":30,"cols":100}},
                    {"endpoint_id":eid,"b64":STANDARD.encode(format!("\x1b[H{}", "x".repeat(100)))},
                ]});
                assert_eq!(
                    request(address, "POST", "/v1/agent/frames", frame, &cap)
                        .await
                        .status(),
                    200
                );
                let (_, snapshot) = json_response(
                    request(
                        address,
                        "GET",
                        &format!("/v1/tasks/{eid}/snapshot"),
                        json!({}),
                        "",
                    )
                    .await,
                )
                .await;
                assert_eq!(snapshot["rows"], 30);
                assert_eq!(snapshot["cols"], 100);
                let lines: Vec<_> = snapshot["screen"].as_str().unwrap().split('\n').collect();
                assert_eq!(lines[0], "x".repeat(100));
                assert_eq!(lines[1], "");
            }
            let result =
                json!({"machine":"box","command_id":command["command_id"],"ok":true,"error":""});
            assert_eq!(
                request(address, "POST", "/v1/agent/results", result, &cap)
                    .await
                    .status(),
                200
            );
            assert_eq!(placed.await.unwrap().0, 200);
        }
        let (_, snapshot) = json_response(
            request(
                address,
                "GET",
                &format!("/v1/tasks/{eid}/snapshot"),
                json!({}),
                "",
            )
            .await,
        )
        .await;
        assert_eq!(
            (snapshot["rows"].clone(), snapshot["cols"].clone()),
            (json!(30), json!(100))
        );
        assert_eq!(snapshot["stream_offset"], 103);
        for (tail, body) in [
            ("input", json!({"b64":"not base64!"})),
            ("resize", json!({"rows":0,"cols":80})),
            ("resize", json!({"rows":24,"cols":1001})),
            ("resize", json!({"rows":24})),
        ] {
            assert_eq!(
                place(tail, body.clone()).await.unwrap().0,
                400,
                "{tail} {body}"
            );
        }
        server.abort();
    }

    #[tokio::test]
    async fn exact_stream_offsets_preserve_continuity() {
        let (h, eid, cap) = fixture();
        let (address, server) = server(h.clone()).await;
        let post = |bytes: Vec<u8>| {
            let eid = eid.clone();
            let cap = cap.clone();
            async move {
                let frame = json!({"machine":"box","frames":[
                    {"endpoint_id":eid,"b64":STANDARD.encode(bytes)}
                ]});
                assert_eq!(
                    request(address, "POST", "/v1/agent/frames", frame, &cap)
                        .await
                        .status(),
                    200
                );
            }
        };
        post(vec![b'x'; 262145]).await;
        for offset in [0, 262146] {
            let (status, error) = json_response(
                request(
                    address,
                    "GET",
                    &format!("/v1/tasks/{eid}/stream?from={offset}"),
                    json!({}),
                    "",
                )
                .await,
            )
            .await;
            assert_eq!(status, 409);
            assert_eq!(error["error"], "stream_continuity_error");
            assert!(error["message"]
                .as_str()
                .unwrap()
                .contains("continuity lost"));
        }
        for offset in [1, 262145] {
            let body = stream(h.clone(), eid.clone(), false, Some(offset)).unwrap();
            drop(body);
        }
        let exact = request(
            address,
            "GET",
            &format!("/v1/tasks/{eid}/stream?from=1"),
            json!({}),
            "",
        )
        .await;
        assert_eq!(exact.status(), 200);
        post(vec![b'y'; 262145]).await;
        let bytes = tokio::time::timeout(Duration::from_secs(2), exact.into_body().collect())
            .await
            .unwrap()
            .unwrap()
            .to_bytes();
        let events: Vec<Value> = std::str::from_utf8(&bytes)
            .unwrap()
            .split("\n\n")
            .filter_map(|event| event.strip_prefix("data: "))
            .map(|event| serde_json::from_str(event).unwrap())
            .collect();
        assert_eq!(events.last().unwrap()["error"], "stream_continuity_error");
        for event in &events {
            if let Some(raw) = event["b64"].as_str() {
                assert_eq!(STANDARD.decode(raw).unwrap(), vec![b'x'; 262144]);
            }
        }
        let replay = request(
            address,
            "GET",
            &format!("/v1/tasks/{eid}/stream?replay=1"),
            json!({}),
            "",
        )
        .await;
        assert_eq!(replay.status(), 200);
        {
            let mut s = h.state.lock().unwrap();
            s.endpoints.get_mut(&eid).unwrap().close(json!(0), "agent");
            h.wake.notify_all();
        }
        let bytes = tokio::time::timeout(Duration::from_secs(2), replay.into_body().collect())
            .await
            .unwrap()
            .unwrap()
            .to_bytes();
        let mut output = Vec::new();
        for event in std::str::from_utf8(&bytes).unwrap().split("\n\n") {
            if let Some(data) = event.strip_prefix("data: ") {
                let record: Value = serde_json::from_str(data).unwrap();
                assert!(record["error"].is_null());
                if let Some(raw) = record["b64"].as_str() {
                    output.extend(STANDARD.decode(raw).unwrap());
                }
            }
        }
        assert_eq!(output, vec![b'y'; 262144]);
        server.abort();
    }

    #[tokio::test]
    async fn snapshot_replays_unconsumed_parser_prefixes() {
        let (h, eid, cap) = fixture();
        let (address, server) = server(h).await;
        let snapshot_path = format!("/v1/tasks/{eid}/snapshot");
        let mut end = 0u64;
        for (prefix, suffix) in [
            (&b"ok\x1b[3"[..], &b"1mred\x1b[0m"[..]),
            (&b"\xc3"[..], &b"\xa9"[..]),
        ] {
            let frame = json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(prefix)}]});
            assert_eq!(
                request(address, "POST", "/v1/agent/frames", frame, &cap)
                    .await
                    .status(),
                200
            );
            end += prefix.len() as u64;
            let (_, snapshot) =
                json_response(request(address, "GET", &snapshot_path, json!({}), "").await).await;
            let offset = snapshot["stream_offset"].as_u64().unwrap();
            assert_eq!(offset, end - if prefix.starts_with(b"ok") { 3 } else { 1 });
            let mut local = screen::Screen::new(2, 8);
            local.feed(
                snapshot["screen"]
                    .as_str()
                    .unwrap()
                    .replace('\n', "\r\n")
                    .as_bytes(),
            );
            local.feed(
                format!(
                    "\x1b[{};{}H",
                    snapshot["cursor_row"].as_u64().unwrap() + 1,
                    snapshot["cursor_col"].as_u64().unwrap() + 1
                )
                .as_bytes(),
            );
            let frame = json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(suffix)}]});
            assert_eq!(
                request(address, "POST", "/v1/agent/frames", frame, &cap)
                    .await
                    .status(),
                200
            );
            end += suffix.len() as u64;
            let stream = request(
                address,
                "GET",
                &format!("/v1/tasks/{eid}/stream?from={offset}"),
                json!({}),
                "",
            )
            .await;
            let mut stream = stream.into_body();
            let mut records = String::new();
            let mut replayed = 0;
            while replayed < (end - offset) as usize {
                let frame = tokio::time::timeout(Duration::from_secs(1), stream.frame())
                    .await
                    .unwrap()
                    .unwrap()
                    .unwrap();
                if let Ok(bytes) = frame.into_data() {
                    records.push_str(std::str::from_utf8(&bytes).unwrap());
                    while let Some(at) = records.find("\n\n") {
                        let event: String = records.drain(..at + 2).collect();
                        if let Some(data) = event.trim().strip_prefix("data: ") {
                            let record: Value = serde_json::from_str(data).unwrap();
                            if let Some(raw) = record["b64"].as_str() {
                                let bytes = STANDARD.decode(raw).unwrap();
                                replayed += bytes.len();
                                local.feed(&bytes);
                            }
                        }
                    }
                }
            }
            let (_, after) =
                json_response(request(address, "GET", &snapshot_path, json!({}), "").await).await;
            assert_eq!(after["stream_offset"], end);
            assert_eq!(
                local.lines(true).join("\n"),
                after["screen"].as_str().unwrap()
            );
        }
        server.abort();
    }

    #[tokio::test]
    async fn journal_retained_results_over_real_http() {
        let h = Hub::new(
            vec![(
                "test".into(),
                vec!["publish".into(), "subscribe".into(), "control".into()],
            )],
            30.,
            0.1,
        );
        let (address, server) = server(h.clone()).await;
        let eid = "a".repeat(32);
        let (status, registration) = json_response(request(address, "POST", "/v1/agent/endpoints",
            json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","rows":24,"cols":80,
                "capabilities":["idempotent_command_results","native_steering_receiver"]}), "").await).await;
        assert_eq!(status, 201);
        let cap = registration["command_capability"].as_str().unwrap();
        let (_, health) =
            json_response(request(address, "GET", "/v1/health", json!({}), "").await).await;
        let generation = health["generation"].as_str().unwrap();
        for age in [899., 901., 1060.5663512, 1061.] {
            let oid = format!("boundary-{age}");
            let cid = taken_http_order(address, &eid, cap, generation, &oid).await;
            h.state.lock().unwrap().commands[&cid].lock().unwrap().taken = model::now() - age;
            assert_eq!(
                request(address, "GET", "/v1/tasks", json!({}), "")
                    .await
                    .status(),
                200
            );
            let path = format!("/v1/orders/{oid}");
            let before = json_response(request(address, "GET", &path, json!({}), "").await).await;
            assert_eq!(before.1["outcome"], "unconfirmed");
            assert_eq!(before.1["delivered"], Value::Null);
            let result = json!({"machine":"box","command_id":cid,"ok":true,"error":""});
            let unauthorized = json_response(
                request(
                    address,
                    "POST",
                    "/v1/agent/results",
                    result.clone(),
                    "wrong",
                )
                .await,
            )
            .await;
            assert_eq!(unauthorized.0, 403);
            assert_eq!(unauthorized.1["error"], "endpoint_unauthorized");
            let completed = json_response(
                request(address, "POST", "/v1/agent/results", result.clone(), cap).await,
            )
            .await;
            assert_eq!(completed.0, 200);
            let after = json_response(request(address, "GET", &path, json!({}), "").await).await;
            assert_eq!(after.1["outcome"], "accepted");
            assert_eq!(after.1["delivered"], true);
            assert_eq!(
                request(address, "POST", "/v1/agent/results", result, cap)
                    .await
                    .status(),
                200
            );
            let conflict = json_response(
                request(
                    address,
                    "POST",
                    "/v1/agent/results",
                    json!({"machine":"box","command_id":cid,"ok":false,"error":"different"}),
                    cap,
                )
                .await,
            )
            .await;
            assert_eq!(conflict.0, 409);
            assert_eq!(conflict.1["error"], "result_conflict");
            println!(
                "Rust HTTP boundary {age}: {}",
                json!({"before":before,"unauthorized":unauthorized,"result":completed,"after":after,"conflict":conflict})
            );
        }
        let cid = taken_http_order(address, &eid, cap, generation, "expiry").await;
        h.state.lock().unwrap().commands[&cid].lock().unwrap().taken = model::now() - 901.;
        request(address, "GET", "/v1/tasks", json!({}), "").await;
        let retired_at = {
            let mut s = h.state.lock().unwrap();
            let retired = s
                .machines
                .get_mut("box")
                .unwrap()
                .retired
                .iter_mut()
                .find(|(id, _)| id == &cid)
                .unwrap();
            retired.1 = model::now() - 802.;
            retired.1
        };
        let result = json!({"machine":"box","command_id":cid,"ok":true,"error":""});
        assert_eq!(
            request(
                address,
                "POST",
                "/v1/agent/results",
                result.clone(),
                "wrong"
            )
            .await
            .status(),
            403
        );
        {
            let mut s = h.state.lock().unwrap();
            let retired = s
                .machines
                .get_mut("box")
                .unwrap()
                .retired
                .iter_mut()
                .find(|(id, _)| id == &cid)
                .unwrap();
            assert_eq!(retired.1, retired_at);
            retired.1 = retired_at - 99.;
        }
        request(address, "GET", "/v1/tasks", json!({}), "").await;
        let expired =
            json_response(request(address, "POST", "/v1/agent/results", result, cap).await).await;
        assert_eq!(expired.0, 404);
        assert_eq!(expired.1["error"], "no_such_command");
        let order =
            json_response(request(address, "GET", "/v1/orders/expiry", json!({}), "").await).await;
        assert_eq!(order.1["outcome"], "unconfirmed");
        println!(
            "Rust HTTP nonrenewal and expiry: {}",
            json!({"result":expired,"order":order})
        );

        let mut ids = vec![];
        for number in 0..517 {
            ids.push(
                taken_http_order(address, &eid, cap, generation, &format!("cap-{number}")).await,
            );
        }
        let path = format!("/v1/tasks/{eid}/input");
        let unrelated = tokio::spawn(async move {
            json_response(
                request(
                    address,
                    "POST",
                    &path,
                    json!({"text":"not an order","submit":true}),
                    "",
                )
                .await,
            )
            .await
        });
        let path = format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=1");
        let (_, taken) = json_response(request(address, "GET", &path, json!({}), cap).await).await;
        let unrelated_id = taken["commands"][0]["command_id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(unrelated.await.unwrap().0, 504);
        {
            let s = h.state.lock().unwrap();
            for cid in ids.iter().chain(std::iter::once(&unrelated_id)) {
                s.commands[cid].lock().unwrap().taken = model::now() - 901.;
            }
        }
        request(address, "GET", "/v1/tasks", json!({}), "").await;
        let mut eligible = vec![];
        for (number, cid) in ids.iter().enumerate() {
            let probe = json_response(
                request(
                    address,
                    "POST",
                    "/v1/agent/results",
                    json!({"machine":"box","command_id":cid,"ok":true,"error":""}),
                    "wrong",
                )
                .await,
            )
            .await;
            assert_eq!(
                probe.0,
                if number < 5 { 404 } else { 403 },
                "{cid}: {probe:?}"
            );
            if probe.0 == 403 {
                eligible.push(cid.clone());
            }
        }
        assert_eq!(eligible, ids[5..]);
        assert_eq!(
            request(
                address,
                "POST",
                "/v1/agent/results",
                json!({"machine":"box","command_id":unrelated_id,"ok":true}),
                cap
            )
            .await
            .status(),
            404
        );
        assert_eq!(
            request(
                address,
                "POST",
                "/v1/agent/results",
                json!({"machine":"box","command_id":ids[5],"ok":true}),
                cap
            )
            .await
            .status(),
            200
        );
        let survivor =
            json_response(request(address, "GET", "/v1/orders/cap-5", json!({}), "").await).await;
        assert_eq!(survivor.1["outcome"], "accepted");
        for number in 0..5 {
            taken_http_order(
                address,
                &eid,
                cap,
                generation,
                &format!("replacement-{number}"),
            )
            .await;
        }
        request(address, "GET", "/v1/tasks", json!({}), "").await;
        for cid in &ids[6..10] {
            assert_eq!(
                request(
                    address,
                    "POST",
                    "/v1/agent/results",
                    json!({"machine":"box","command_id":cid,"ok":true}),
                    cap
                )
                .await
                .status(),
                404
            );
        }
        assert_eq!(
            request(
                address,
                "POST",
                "/v1/agent/results",
                json!({"machine":"box","command_id":ids[10],"ok":true}),
                cap
            )
            .await
            .status(),
            200
        );
        println!(
            "Rust HTTP journal-only retirement: {}",
            json!({"eligible_command_ids":eligible,"evicted_command_ids":&ids[..5],"unrelated_command_id":unrelated_id,"survivor":survivor})
        );
        server.abort();
    }

    #[test]
    fn idle_polls_do_not_block_frames_health_or_acknowledgements() {
        tokio::runtime::Builder::new_current_thread().enable_all().max_blocking_threads(1).build().unwrap().block_on(async {
            let (h, eid, cap) = fixture();
            let (address, server) = server(h).await;
            let (tx, mut rx) = tokio::sync::mpsc::channel(16);
            let mut polls = vec![];
            for _ in 0..16 {
                let tx = tx.clone();
                let cap = cap.clone();
                let path = format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=3");
                polls.push(tokio::spawn(async move {
                    let response = json_response(request(address, "GET", &path, json!({}), &cap).await).await;
                    tx.send(response).await.unwrap();
                }));
            }
            drop(tx);
            tokio::time::sleep(Duration::from_millis(100)).await;
            let health = tokio::time::timeout(Duration::from_secs(1), request(address, "GET", "/v1/health", json!({}), "")).await.unwrap();
            assert_eq!(health.status(), 200);
            let frames = json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"live")}]});
            let frame = tokio::time::timeout(Duration::from_secs(1), request(address, "POST", "/v1/agent/frames", frames, "")).await.unwrap();
            assert_eq!(frame.status(), 200);
            let path = format!("/v1/tasks/{eid}/input");
            let input = tokio::spawn(async move { request(address, "POST", &path, json!({"text":"hello","submit":true}), "").await });
            let (status, taken) = tokio::time::timeout(Duration::from_secs(1), rx.recv()).await.unwrap().unwrap();
            assert_eq!(status, 200);
            let cid = taken["commands"][0]["command_id"].as_str().unwrap();
            let result = tokio::time::timeout(Duration::from_secs(1), request(address, "POST", "/v1/agent/results", json!({"machine":"box","command_id":cid,"ok":true}), &cap)).await.unwrap();
            assert_eq!(result.status(), 200);
            assert_eq!(tokio::time::timeout(Duration::from_secs(1), input).await.unwrap().unwrap().status(), 200);
            assert_eq!(request(address, "POST", "/v1/agent/frames", json!({"machine":"box","frames":[{"endpoint_id":eid,"closed":true,"exit_code":0}]}), "").await.status(), 200);
            for poll in polls { tokio::time::timeout(Duration::from_secs(1), poll).await.unwrap().unwrap(); }
            server.abort();
        });
    }

    #[tokio::test]
    async fn deletion_survives_retention_and_never_closes_or_commands_a_replacement() {
        for (replacement_machine, take_original) in [
            (None, false),
            (Some("box"), false),
            (Some("other"), false),
            (Some("box"), true),
        ] {
            let (h, eid, cap) = fixture();
            let (address, server) = server(h.clone()).await;
            let path = format!("/v1/tasks/{eid}");
            let delete_path = path.clone();
            let deletion = tokio::spawn(async move {
                json_response(request(address, "DELETE", &delete_path, json!({}), "").await).await
            });
            tokio::time::timeout(Duration::from_secs(1), async {
                loop {
                    let queued = h
                        .state
                        .lock()
                        .unwrap()
                        .commands
                        .values()
                        .any(|c| c.lock().unwrap().kind == "kill");
                    if queued {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
            })
            .await
            .unwrap();
            let original_command = if take_original {
                let (status, taken) = json_response(
                    request(
                        address,
                        "GET",
                        &format!("/v1/agent/commands?machine=box&endpoint={eid}&wait=0"),
                        json!({}),
                        &cap,
                    )
                    .await,
                )
                .await;
                assert_eq!(status, 200);
                Some(
                    taken["commands"][0]["command_id"]
                        .as_str()
                        .unwrap()
                        .to_owned(),
                )
            } else {
                None
            };
            h.state
                .lock()
                .unwrap()
                .endpoints
                .get_mut(&eid)
                .unwrap()
                .seen = now() - 3601.;
            let (status, tasks) =
                json_response(request(address, "GET", "/v1/tasks", json!({}), "").await).await;
            assert_eq!(status, 200);
            assert_eq!(tasks["tasks"], json!([]));
            if let Some(machine) = replacement_machine {
                let (status, registered) = json_response(request(address, "POST", "/v1/agent/endpoints", json!({"protocol":3,"endpoint_id":eid,"machine":machine,"label":"replacement","rows":2,"cols":8}), "").await).await;
                assert_eq!(status, 201);
                let replacement_cap = registered["command_capability"].as_str().unwrap();
                let (status, commands) = json_response(
                    request(
                        address,
                        "GET",
                        &format!("/v1/agent/commands?machine={machine}&endpoint={eid}&wait=0"),
                        json!({}),
                        replacement_cap,
                    )
                    .await,
                )
                .await;
                assert_eq!(status, 200);
                assert_eq!(commands["commands"], json!([]));
                if let Some(cid) = original_command {
                    let (status, refused) = json_response(
                        request(
                            address,
                            "POST",
                            "/v1/agent/results",
                            json!({"machine":machine,"command_id":cid,"ok":true}),
                            replacement_cap,
                        )
                        .await,
                    )
                    .await;
                    assert_eq!(status, 403);
                    assert_eq!(refused["error"], "endpoint_unauthorized");
                }
            }
            let (status, deleted) = tokio::time::timeout(Duration::from_secs(5), deletion)
                .await
                .unwrap()
                .unwrap();
            assert_eq!(status, 200);
            assert_eq!(
                deleted,
                json!({"ok":true,"closed":eid,"machine":"box","delivered":false})
            );
            let (status, health) =
                json_response(request(address, "GET", "/v1/health", json!({}), "").await).await;
            assert_eq!(status, 200);
            assert_eq!(
                health["endpoints"],
                usize::from(replacement_machine.is_some())
            );
            if let Some(machine) = replacement_machine {
                let (status, task) =
                    json_response(request(address, "GET", &path, json!({}), "").await).await;
                assert_eq!(status, 200);
                assert!(task["task"]["closed_at"].is_null());
                assert!(task["task"]["closed_by"].is_null());
                let frame = request(address, "POST", "/v1/agent/frames", json!({"machine":machine,"frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"still live")}]}), "").await;
                assert_eq!(frame.status(), 200);
            }
            server.abort();
        }
    }

    #[tokio::test]
    async fn stream_never_reads_a_replacement_incarnation() {
        let (h, eid, _) = fixture();
        h.state
            .lock()
            .unwrap()
            .endpoints
            .get_mut(&eid)
            .unwrap()
            .feed(&[b'x'; 1024]);
        let (address, server) = server(h.clone()).await;
        let response = request(
            address,
            "GET",
            &format!("/v1/tasks/{eid}/stream"),
            json!({}),
            "",
        )
        .await;
        assert_eq!(response.status(), 200);
        let (replacement_hub, _, _) = fixture();
        let mut replacement = replacement_hub
            .state
            .lock()
            .unwrap()
            .endpoints
            .remove(&eid)
            .unwrap();
        replacement.feed(b"new output");
        replacement.close(json!(0), "agent");
        {
            let mut state = h.state.lock().unwrap();
            replacement.created = state.endpoints[&eid].created + 3601.;
            state.endpoints.insert(eid, replacement);
        }
        h.wake.notify_all();
        let bytes = tokio::time::timeout(Duration::from_secs(2), response.into_body().collect())
            .await
            .unwrap()
            .unwrap()
            .to_bytes();
        assert!(
            bytes.is_empty(),
            "replacement bytes or obsolete close event: {bytes:?}"
        );
        server.abort();
    }

    /// Reads the next non-comment event-stream record as (event, data).
    async fn next_event(body: &mut Incoming, buffer: &mut Vec<u8>) -> (String, Value) {
        loop {
            if let Some(end) = buffer.windows(2).position(|w| w == b"\n\n") {
                let record = String::from_utf8(buffer.drain(..end + 2).collect()).unwrap();
                if record.starts_with(':') {
                    continue;
                }
                let mut kind = String::new();
                let mut data = Value::Null;
                for line in record.lines() {
                    if let Some(k) = line.strip_prefix("event: ") {
                        kind = k.to_owned();
                    } else if let Some(d) = line.strip_prefix("data: ") {
                        data = serde_json::from_str(d).unwrap();
                    }
                }
                return (kind, data);
            }
            let frame = tokio::time::timeout(Duration::from_secs(5), body.frame())
                .await
                .expect("an event within five seconds")
                .unwrap()
                .unwrap();
            if let Ok(data) = frame.into_data() {
                buffer.extend_from_slice(&data);
            }
        }
    }

    #[tokio::test]
    async fn task_events_push_the_listing_then_only_what_changed() {
        let (h, eid, _) = fixture();
        let (address, server) = server(h.clone()).await;
        let health =
            json_response(request(address, "GET", "/v1/health", json!({}), "").await).await;
        assert!(health.1["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("task_events")));
        let response = request(address, "GET", "/v1/tasks/events", json!({}), "").await;
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers()["Content-Type"], "text/event-stream");
        let mut body = response.into_body();
        let mut buffer = Vec::new();
        let (kind, snapshot) = next_event(&mut body, &mut buffer).await;
        assert_eq!(kind, "snapshot");
        assert_eq!(snapshot["seq"], 1);
        assert_eq!(snapshot["generation"], json!(h.generation));
        let (_, listing) =
            json_response(request(address, "GET", "/v1/tasks", json!({}), "").await).await;
        let ids = |v: &Value| {
            v.as_array()
                .unwrap()
                .iter()
                .map(|t| t["endpoint_id"].clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(&snapshot["tasks"]), ids(&listing["tasks"]));
        assert_eq!(snapshot["tasks"][0]["current_execution"], true);

        // The agent speaking again changes no projected fact: nothing is pushed.
        // Its first output is pushed at once, the next within the output window.
        let frames = |payload: Value| async move {
            request(address, "POST", "/v1/agent/frames", payload, "")
                .await
                .status()
        };
        assert_eq!(frames(json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"hello")}]})).await, 200);
        let (kind, delta) =
            tokio::time::timeout(Duration::from_secs(1), next_event(&mut body, &mut buffer))
                .await
                .expect("first output is not throttled by the snapshot");
        assert_eq!(kind, "delta");
        assert_eq!(delta["seq"], 2);
        assert_eq!(delta["tasks"][0]["stream_offset"], 5);
        assert_eq!(delta["removed"], json!([]));
        let started = std::time::Instant::now();
        assert_eq!(frames(json!({"machine":"box","frames":[{"endpoint_id":eid,"b64":STANDARD.encode(b"again")}]})).await, 200);
        let (_, delta) = next_event(&mut body, &mut buffer).await;
        assert_eq!(delta["tasks"][0]["stream_offset"], 10);
        assert!(started.elapsed() >= Duration::from_secs_f64(EVENT_OUTPUT_SECS - 0.5));

        // A close is pushed with the agent's own attribution.
        assert_eq!(
            frames(
                json!({"machine":"box","frames":[{"endpoint_id":eid,"closed":true,"exit_code":3}]})
            )
            .await,
            200
        );
        let (_, delta) = next_event(&mut body, &mut buffer).await;
        assert_eq!(delta["tasks"][0]["closed_by"], "agent");
        assert_eq!(delta["tasks"][0]["exit_code"], 3);

        // A second endpoint going quiet past the presumption window is pushed
        // without any request, and deleting the first one reports its removal.
        let other = "c".repeat(32);
        h.register(&json!({"protocol":3,"endpoint_id":other,"machine":"box","label":"quiet","rows":2,"cols":8}), "").unwrap();
        h.wake.notify_all();
        let (_, delta) = next_event(&mut body, &mut buffer).await;
        assert_eq!(delta["tasks"][0]["endpoint_id"], json!(other));
        assert!(delta["tasks"][0]["agent_silent_for_secs"].as_f64().unwrap() <= PRESUMED_SECS);
        h.state
            .lock()
            .unwrap()
            .endpoints
            .get_mut(&other)
            .unwrap()
            .seen = now() - PRESUMED_SECS + 0.3;
        let (_, delta) = next_event(&mut body, &mut buffer).await;
        assert_eq!(delta["tasks"][0]["endpoint_id"], json!(other));
        assert!(delta["tasks"][0]["agent_silent_for_secs"].as_f64().unwrap() > PRESUMED_SECS);
        h.state.lock().unwrap().endpoints.remove(&eid);
        h.wake.notify_all();
        let (_, delta) = next_event(&mut body, &mut buffer).await;
        assert_eq!(delta["removed"], json!([eid]));
        assert_eq!(delta["tasks"], json!([]));
        server.abort();
    }

    #[tokio::test]
    async fn task_events_require_a_subscribe_token_in_the_header() {
        let h = Hub::new(
            vec![
                ("pub".into(), vec!["publish".into()]),
                ("view".into(), vec!["subscribe".into()]),
            ],
            30.,
            3.,
        );
        let (address, server) = server(h).await;
        let get = |token: &'static str, path: &'static str| async move {
            let socket = tokio::net::TcpStream::connect(address).await.unwrap();
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(socket))
                    .await
                    .unwrap();
            tokio::spawn(async move {
                let _ = connection.await;
            });
            let mut builder = hyper::Request::builder()
                .method("GET")
                .uri(path)
                .header("Host", "hub");
            if !token.is_empty() {
                builder = builder.header("Authorization", format!("Bearer {token}"));
            }
            sender
                .send_request(builder.body(Full::new(Bytes::new())).unwrap())
                .await
                .unwrap()
                .status()
                .as_u16()
        };
        assert_eq!(get("", "/v1/tasks/events").await, 401);
        assert_eq!(get("", "/v1/tasks/events?access_token=view").await, 401);
        assert_eq!(get("pub", "/v1/tasks/events").await, 403);
        assert_eq!(get("view", "/v1/tasks/events").await, 200);
        assert_eq!(get("view", "/v1/tasks").await, 200);
        server.abort();
    }
}
