use crate::screen::Screen;
use fm_stream_wire::{is_endpoint_id, is_label, is_machine_name, python_repr_value, HUB_PROTOCOL};
use serde_json::{json, Value};
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use subtle::ConstantTimeEq;

pub const VERSION: &str = "2.0.0";
pub const CAPS: [&str; 4] = [
    "current_execution",
    "idempotent_command_results",
    "result_retry_orderability",
    "endpoint_command_auth",
];
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
pub fn id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}
pub fn equal(a: &str, b: &str) -> bool {
    bool::from(a.as_bytes().ct_eq(b.as_bytes()))
}
pub fn truth(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64() != Some(0.),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}
pub fn string(v: &Value) -> String {
    if !truth(v) {
        String::new()
    } else if let Some(s) = v.as_str() {
        s.to_owned()
    } else {
        python_repr_value(v)
    }
}
pub fn rounded(n: f64) -> f64 {
    (n * 1000.).round() / 1000.
}
#[derive(Debug, Clone)]
pub struct Error {
    pub status: u16,
    pub code: String,
    pub message: String,
    pub details: Value,
}
impl Error {
    pub fn new(status: u16, code: &str, message: impl Into<String>) -> Self {
        Self {
            status,
            code: code.into(),
            message: message.into(),
            details: json!({}),
        }
    }
    pub fn body(&self) -> Value {
        let mut body = self.details.clone();
        body["ok"] = json!(false);
        body["error"] = json!(self.code);
        body["message"] = json!(self.message);
        body
    }
}
pub type Result<T> = std::result::Result<T, Error>;
pub struct Endpoint {
    pub id: String,
    pub machine: String,
    pub label: String,
    pub cwd: String,
    pub rows: usize,
    pub cols: usize,
    pub retry: bool,
    pub capability: String,
    pub created: f64,
    pub closed: f64,
    pub closed_by: String,
    pub exit: Value,
    pub presumed: bool,
    pub heard: bool,
    pub seen: f64,
    pub state: Value,
    pub received: f64,
    pub screen: Screen,
    pub ring: VecDeque<u8>,
    pub end: u64,
}
impl Endpoint {
    pub fn leaf(&self) -> String {
        format!("{}/{}", self.machine, self.label)
    }
    pub fn silent(&self) -> f64 {
        (now() - self.seen).max(0.)
    }
    pub fn age(&self) -> Option<f64> {
        if self.received == 0. {
            None
        } else {
            Some((now() - self.received).max(0.))
        }
    }
    pub fn describe(&self) -> Value {
        json!({"endpoint_id":self.id,"machine":self.machine,"label":self.label,"cwd":self.cwd,"rows":self.rows,"cols":self.cols,"created_at":self.created,"closed_at":if self.closed==0. {Value::Null} else {json!(self.closed)},"closed_by":if self.closed_by.is_empty() {Value::Null} else {json!(self.closed_by)},"exit_code":self.exit,"stream_offset":self.end,"state_age_secs":self.age().map(rounded),"agent_silent_for_secs":rounded(self.silent())})
    }
    pub fn close(&mut self, exit: Value, by: &str) {
        self.capability.clear();
        if self.closed == 0. {
            self.closed = now();
            self.closed_by = by.into();
            self.exit = exit;
        } else if by == "agent" {
            self.closed_by = by.into();
            self.exit = exit;
        }
    }
    pub fn feed(&mut self, data: &[u8]) {
        self.seen = now();
        self.end += data.len() as u64;
        self.ring.extend(data);
        let overflow = self.ring.len().saturating_sub(262144);
        self.ring.drain(..overflow);
        self.screen.feed(data);
    }
    pub fn bytes(&self, offset: u64) -> (u64, Vec<u8>) {
        let start = self.end - self.ring.len() as u64;
        let offset = offset.max(start).min(self.end);
        (
            offset,
            self.ring
                .iter()
                .skip((offset - start) as usize)
                .copied()
                .collect(),
        )
    }
}
pub struct Command {
    pub id: String,
    pub endpoint: String,
    pub endpoint_created: f64,
    pub kind: String,
    pub payload: Value,
    pub taken: f64,
    pub done: bool,
    pub ok: bool,
    pub error: String,
    pub withdrawn: bool,
}
impl Command {
    pub fn describe(&self) -> Value {
        json!({"command_id":self.id,"endpoint_id":self.endpoint,"kind":self.kind,"payload":self.payload})
    }
}
pub struct Machine {
    pub first: f64,
    pub seen: f64,
    pub queue: VecDeque<String>,
    pub pending: BTreeMap<String, String>,
    pub completed: BTreeMap<String, (bool, String, f64, String)>,
}
impl Machine {
    fn new() -> Self {
        Self {
            first: now(),
            seen: now(),
            queue: VecDeque::new(),
            pending: BTreeMap::new(),
            completed: BTreeMap::new(),
        }
    }
    pub fn describe(&self, name: &str, max_age: f64) -> Value {
        let silent = (now() - self.seen).max(0.);
        json!({"machine":name,"first_seen":self.first,"last_seen":self.seen,"silent_for_secs":rounded(silent),"reachable":silent<=max_age})
    }
}
#[derive(Clone)]
pub struct Order {
    pub id: String,
    pub leaf: String,
    pub requested: String,
    pub text: String,
    pub execution: String,
    pub endpoint: Option<String>,
    pub endpoint_created: f64,
    pub gone_snapshot: bool,
    pub created: f64,
    pub command: Option<Arc<Mutex<Command>>>,
    pub refusal: Option<(String, String)>,
    pub uncertainty: Option<(String, String)>,
    pub status: u16,
    pub answered: bool,
}
pub struct State {
    pub endpoints: BTreeMap<String, Endpoint>,
    pub machines: BTreeMap<String, Machine>,
    pub commands: BTreeMap<String, Arc<Mutex<Command>>>,
    pub orders: VecDeque<Arc<Mutex<Order>>>,
}
pub struct Hub {
    pub state: Mutex<State>,
    pub wake: Condvar,
    pub tokens: Vec<(String, Vec<String>)>,
    pub started: f64,
    pub generation: String,
    pub max_age: f64,
    pub ack: f64,
}
impl Hub {
    pub fn new(tokens: Vec<(String, Vec<String>)>, max_age: f64, ack: f64) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State {
                endpoints: BTreeMap::new(),
                machines: BTreeMap::new(),
                commands: BTreeMap::new(),
                orders: VecDeque::new(),
            }),
            wake: Condvar::new(),
            tokens,
            started: now(),
            generation: id(),
            max_age,
            ack,
        })
    }
    pub fn classes(&self, token: &str) -> Vec<String> {
        let mut granted = vec![];
        for (stored, classes) in &self.tokens {
            if equal(stored, token) {
                granted = classes.clone();
            }
        }
        granted
    }
    pub fn touch(s: &mut State, machine: &str) {
        s.machines
            .entry(machine.into())
            .or_insert_with(Machine::new)
            .seen = now();
    }
    pub fn get<'a>(s: &'a State, id: &str) -> Result<&'a Endpoint> {
        s.endpoints
            .get(id)
            .ok_or_else(|| Error::new(404, "no_such_endpoint", format!("no endpoint {id}")))
    }
    pub fn authorize(e: &Endpoint, machine: &str, cap: &str) -> Result<()> {
        if e.machine != machine
            || cap.is_empty()
            || e.capability.is_empty()
            || !equal(&e.capability, cap)
        {
            return Err(Error::new(
                403,
                "endpoint_unauthorized",
                "a valid endpoint command capability is required",
            ));
        }
        Ok(())
    }
    pub fn spoke(s: &mut State, eid: &str) -> Result<()> {
        let e = Self::get(s, eid)?;
        if e.presumed || !e.heard || e.silent() > 10. {
            for other in s.endpoints.values() {
                if other.id != e.id
                    && other.closed == 0.
                    && other.heard
                    && other.silent() <= 10.
                    && other.machine == e.machine
                    && other.label == e.label
                {
                    return Err(Error::new(
                        410,
                        "endpoint_superseded",
                        format!(
                            "machine {} serves {} from another endpoint, not from {}",
                            e.machine, e.label, e.id
                        ),
                    ));
                }
            }
        }
        let e = s.endpoints.get_mut(eid).unwrap();
        e.presumed = false;
        e.seen = now();
        e.heard = true;
        Ok(())
    }
    pub fn reap(s: &mut State) {
        for e in s.endpoints.values_mut() {
            if e.closed == 0. && e.silent() > 10. {
                e.presumed = true;
            }
        }
        for order in &s.orders {
            let mut order = order.lock().unwrap();
            if let Some(endpoint) = order
                .endpoint
                .as_ref()
                .and_then(|id| s.endpoints.get(id))
                .filter(|e| e.created == order.endpoint_created)
            {
                order.gone_snapshot = endpoint.closed_by == "agent";
            }
        }
        s.endpoints
            .retain(|_, e| !(e.closed > 0. && e.closed < now() - 3600. || e.silent() > 3600.));
        for m in s.machines.values_mut() {
            m.pending.retain(|cid, _| {
                s.commands.get(cid).is_some_and(|c| {
                    let c = c.lock().unwrap();
                    c.done || c.taken >= now() - 900.
                })
            });
            m.completed.retain(|_, c| c.2 >= now() - 900.);
        }
        let retained: std::collections::BTreeSet<String> = s
            .machines
            .values()
            .flat_map(|m| {
                m.queue
                    .iter()
                    .chain(m.pending.keys())
                    .chain(m.completed.keys())
            })
            .cloned()
            .collect();
        s.commands.retain(|id, _| retained.contains(id));
    }
    pub fn current<'a>(members: &[&'a Endpoint]) -> Option<&'a Endpoint> {
        members
            .iter()
            .rev()
            .find(|e| e.heard && e.closed == 0.)
            .or_else(|| members.iter().rev().find(|e| e.closed == 0.))
            .or_else(|| members.last())
            .copied()
    }
    pub fn members<'a>(s: &'a State, leaf: &str) -> Vec<&'a Endpoint> {
        let mut es: Vec<_> = s.endpoints.values().filter(|e| e.leaf() == leaf).collect();
        es.sort_by(|a, b| a.created.total_cmp(&b.created));
        es
    }
    pub fn listing(s: &State) -> Vec<Value> {
        let mut es: Vec<_> = s.endpoints.values().collect();
        es.sort_by(|a, b| {
            a.machine
                .cmp(&b.machine)
                .then(a.created.total_cmp(&b.created))
        });
        let mut groups: BTreeMap<(&str, &str), Vec<&Endpoint>> = BTreeMap::new();
        for e in &es {
            groups.entry((&e.machine, &e.label)).or_default().push(e);
        }
        let current: BTreeMap<_, _> = groups
            .into_iter()
            .map(|(leaf, members)| (leaf, Self::current(&members).unwrap().id.as_str()))
            .collect();
        es.iter()
            .map(|e| {
                let mut record = e.describe();
                record["current_execution"] =
                    json!(current[&(e.machine.as_str(), e.label.as_str())] == e.id);
                record
            })
            .collect()
    }
    pub fn register(&self, p: &Value, cap: &str) -> Result<Value> {
        if p["protocol"].as_i64() != Some(HUB_PROTOCOL) {
            return Err(Error::new(426,"protocol_mismatch",format!("endpoint speaks protocol {} but this hub implements {}; restart the endpoint with matching software",python_repr_value(&p["protocol"]),HUB_PROTOCOL)));
        }
        let eid = string(&p["endpoint_id"]);
        let machine = string(&p["machine"]);
        let label = string(&p["label"]);
        if !is_endpoint_id(&eid) {
            return Err(Error::new(
                400,
                "bad_endpoint_id",
                "endpoint_id must be 32 lowercase hex characters",
            ));
        }
        if !is_machine_name(&machine) {
            return Err(Error::new(
                400,
                "bad_machine",
                "machine must be 1-128 characters of [A-Za-z0-9._-]",
            ));
        }
        if !is_label(&label) {
            return Err(Error::new(
                400,
                "bad_label",
                "label must be 1-128 characters of [A-Za-z0-9._@%+-]",
            ));
        }
        let rows = positive(&p["rows"], 40, "rows")?;
        let cols = positive(&p["cols"], 200, "cols")?;
        let caps = if p.get("capabilities").is_none() {
            vec![]
        } else {
            p["capabilities"]
                .as_array()
                .filter(|a| a.iter().all(Value::is_string))
                .ok_or_else(|| {
                    Error::new(
                        400,
                        "bad_capabilities",
                        "capabilities must be an array of strings",
                    )
                })?
                .clone()
        };
        let retry = caps.iter().any(|c| c == "idempotent_command_results");
        let screen = Screen::try_new(rows, cols)
            .map_err(|_| Error::new(500, "internal", "cannot allocate endpoint screen"))?;
        let mut s = self.state.lock().unwrap();
        Self::reap(&mut s);
        if let Some(e) = s.endpoints.get(&eid) {
            if e.machine != machine {
                return Err(Error::new(
                    409,
                    "endpoint_owned_elsewhere",
                    format!("endpoint {eid} is registered to machine {}", e.machine),
                ));
            }
            if e.retry != retry {
                return Err(Error::new(
                    409,
                    "endpoint_capabilities_changed",
                    format!("endpoint {eid} cannot change its registered capabilities"),
                ));
            }
            Self::authorize(e, &machine, cap)?;
        } else {
            for e in s.endpoints.values() {
                if e.closed == 0.
                    && !e.presumed
                    && e.heard
                    && e.machine == machine
                    && e.label == label
                {
                    return Err(Error::new(
                        409,
                        "duplicate_label",
                        format!("machine {machine} already has a live endpoint labelled {label}"),
                    ));
                }
            }
            s.endpoints.insert(
                eid.clone(),
                Endpoint {
                    id: eid.clone(),
                    machine: machine.clone(),
                    label,
                    cwd: string(&p["cwd"]),
                    rows,
                    cols,
                    retry,
                    capability: if cap.is_empty() {
                        format!("{}{}", id(), id())
                    } else {
                        cap.into()
                    },
                    created: now(),
                    closed: 0.,
                    closed_by: String::new(),
                    exit: Value::Null,
                    presumed: false,
                    heard: false,
                    seen: now(),
                    state: json!({}),
                    received: 0.,
                    screen,
                    ring: VecDeque::new(),
                    end: 0,
                },
            );
        }
        Self::touch(&mut s, &machine);
        let e = &s.endpoints[&eid];
        Ok(json!({"ok":true,"endpoint":e.describe(),"command_capability":e.capability}))
    }
    pub fn delete(&self, eid: &str) -> Result<Value> {
        let (created, machine) = {
            let s = self.state.lock().unwrap();
            let e = Self::get(&s, eid)?;
            (e.created, e.machine.clone())
        };
        let delivered =
            match self.submit_to(eid, "kill", json!({"signal":"TERM"}), None, Some(created)) {
                Ok(()) => true,
                Err(error) if error.code == "no_agent_ack" => {
                    let mut s = self.state.lock().unwrap();
                    if let Some(e) = s.endpoints.get_mut(eid).filter(|e| e.created == created) {
                        e.close(Value::Null, "hub");
                        self.wake.notify_all();
                    }
                    false
                }
                Err(error) => return Err(error),
            };
        Ok(json!({"ok":true,"closed":eid,"machine":machine,"delivered":delivered}))
    }
    pub fn submit(
        &self,
        eid: &str,
        kind: &str,
        payload: Value,
        order: Option<&Arc<Mutex<Order>>>,
    ) -> Result<()> {
        self.submit_to(eid, kind, payload, order, None)
    }
    fn submit_to(
        &self,
        eid: &str,
        kind: &str,
        payload: Value,
        order: Option<&Arc<Mutex<Order>>>,
        expected: Option<f64>,
    ) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        let e = Self::get(&s, eid)?;
        if expected.is_some_and(|created| created != e.created) {
            return Err(Error::new(
                409,
                "endpoint_changed",
                "the endpoint registration changed before command delivery",
            ));
        }
        if e.closed > 0. {
            return Err(Error::new(
                409,
                "endpoint_closed",
                format!("endpoint {eid} has closed"),
            ));
        }
        let machine = e.machine.clone();
        let endpoint_created = e.created;
        let cid = id();
        if !s.machines.contains_key(&machine) {
            return Err(Error::new(
                503,
                "machine_unknown",
                format!("no agent has ever reported machine {machine}"),
            ));
        }
        let command = Arc::new(Mutex::new(Command {
            id: cid.clone(),
            endpoint: eid.into(),
            endpoint_created,
            kind: kind.into(),
            payload,
            taken: 0.,
            done: false,
            ok: false,
            error: String::new(),
            withdrawn: false,
        }));
        s.commands.insert(cid.clone(), command.clone());
        if let Some(order) = order {
            order.lock().unwrap().command = Some(command.clone());
        }
        s.machines
            .get_mut(&machine)
            .unwrap()
            .queue
            .push_back(cid.clone());
        self.wake.notify_all();
        let deadline = now() + self.ack;
        while !command.lock().unwrap().done && now() < deadline {
            let remaining = (deadline - now()).max(0.);
            s = self
                .wake
                .wait_timeout(s, Duration::from_secs_f64(remaining))
                .unwrap()
                .0;
        }
        if !command.lock().unwrap().done {
            let m = s.machines.get_mut(&machine).unwrap();
            let pos = m.queue.iter().position(|id| id == &cid);
            if let Some(pos) = pos {
                m.queue.remove(pos);
                command.lock().unwrap().withdrawn = true;
                s.commands.remove(&cid);
            }
            let silent = (now() - s.machines[&machine].seen).max(0.);
            let taken = !command.lock().unwrap().withdrawn;
            let message = if taken {
                format!("the agent on machine {machine} took the {kind} but did not acknowledge it within {}s (last heard from {silent:.1}s ago); whether it reached the worker is NOT known",self.ack)
            } else {
                format!("the agent on machine {machine} did not acknowledge within {}s (last heard from {silent:.1}s ago); the {kind} was NOT delivered",self.ack)
            };
            let mut error = Error::new(504, "no_agent_ack", message);
            error.details = json!({"taken":taken});
            return Err(error);
        }
        let c = command.lock().unwrap();
        if !c.ok {
            let mut error = Error::new(
                502,
                "agent_refused",
                if c.error.is_empty() {
                    format!("the owning agent refused the {kind}")
                } else {
                    c.error.clone()
                },
            );
            error.details = json!({"taken":true});
            return Err(error);
        }
        Ok(())
    }
    pub fn take(&self, machine: &str, eid: &str, wait: f64, cap: &str) -> Result<Vec<Value>> {
        let deadline = now() + wait;
        let mut s = self.state.lock().unwrap();
        let mut result = vec![];
        loop {
            Self::authorize(Self::get(&s, eid)?, machine, cap)?;
            let created = Self::get(&s, eid)?.created;
            let pos = s.machines.get(machine).and_then(|m| {
                m.queue.iter().position(|cid| {
                    s.commands.get(cid).is_some_and(|c| {
                        let c = c.lock().unwrap();
                        c.endpoint == eid && c.endpoint_created == created
                    })
                })
            });
            if let Some(pos) = pos {
                let cid = s
                    .machines
                    .get_mut(machine)
                    .unwrap()
                    .queue
                    .remove(pos)
                    .unwrap();
                let mut c = s.commands[&cid].lock().unwrap();
                c.taken = now();
                result.push(c.describe());
                drop(c);
                s.machines
                    .get_mut(machine)
                    .unwrap()
                    .pending
                    .insert(cid, eid.into());
                break;
            }
            if now() >= deadline {
                break;
            }
            s = self
                .wake
                .wait_timeout(s, Duration::from_secs_f64((deadline - now()).max(0.)))
                .unwrap()
                .0;
        }
        Self::touch(&mut s, machine);
        Self::spoke(&mut s, eid)?;
        Ok(result)
    }
    pub fn complete(
        &self,
        machine: &str,
        cid: &str,
        ok: bool,
        error: &str,
        cap: &str,
    ) -> Result<()> {
        let mut s = self.state.lock().unwrap();
        Self::touch(&mut s, machine);
        s.machines
            .get_mut(machine)
            .unwrap()
            .completed
            .retain(|_, c| c.2 >= now() - 900.);
        let m = &s.machines[machine];
        if let Some(eid) = m.pending.get(cid).cloned() {
            let endpoint = Self::get(&s, &eid)?;
            Self::authorize(endpoint, machine, cap)?;
            if s.commands[cid].lock().unwrap().endpoint_created != endpoint.created {
                return Err(Error::new(
                    403,
                    "endpoint_unauthorized",
                    "a valid endpoint command capability is required",
                ));
            }
            s.machines.get_mut(machine).unwrap().pending.remove(cid);
            let command = s.commands.remove(cid).unwrap();
            let mut c = command.lock().unwrap();
            c.done = true;
            c.ok = ok;
            c.error = error.into();
            drop(c);
            s.machines
                .get_mut(machine)
                .unwrap()
                .completed
                .insert(cid.into(), (ok, error.into(), now(), eid));
            self.wake.notify_all();
            return Ok(());
        }
        if let Some((old_ok, old_error, _, eid)) = m.completed.get(cid) {
            Self::authorize(Self::get(&s, eid)?, machine, cap)?;
            if *old_ok != ok || old_error != error {
                return Err(Error::new(
                    409,
                    "result_conflict",
                    format!("command {cid} already has a different result"),
                ));
            }
            return Ok(());
        }
        Err(Error::new(
            404,
            "no_such_command",
            format!("machine {machine} holds no command {cid}"),
        ))
    }
    pub fn order_record(s: &State, o: &Order) -> Value {
        let (outcome, reason, message, delivered) = if let Some((r, m)) = &o.refusal {
            ("refused", r.clone(), m.clone(), json!(false))
        } else if let Some((r, m)) = &o.uncertainty {
            ("unconfirmed", r.clone(), m.clone(), Value::Null)
        } else if let Some(command) = &o.command {
            let c = command.lock().unwrap();
            if c.done {
                if c.ok {
                    ("accepted", String::new(), String::new(), json!(true))
                } else {
                    (
                        "refused",
                        "agent_refused".into(),
                        if c.error.is_empty() {
                            "the owning agent refused the order".into()
                        } else {
                            c.error.clone()
                        },
                        json!(false),
                    )
                }
            } else if c.withdrawn {
                (
                    "refused",
                    "no_agent_ack".into(),
                    "no agent took the order, so it was not delivered".into(),
                    json!(false),
                )
            } else if c.taken > 0. {
                ("unconfirmed","no_agent_ack".into(),"the owning agent took the order and has not acknowledged it, so whether the worker received it is not known".into(),Value::Null)
            } else {
                (
                    "unconfirmed",
                    "queued".into(),
                    "the order is queued for the owning agent and has not been taken".into(),
                    Value::Null,
                )
            }
        } else if !o.answered {
            (
                "unconfirmed",
                "routing".into(),
                "the order is still being placed, so nothing is known yet of its delivery".into(),
                Value::Null,
            )
        } else {
            (
                "refused",
                "not_submitted".into(),
                "no command was ever made for this order, so nothing was delivered".into(),
                json!(false),
            )
        };
        let mut r = json!({"order_id":o.id,"leaf_worker_id":o.leaf,"requested_execution_id":o.requested,"execution_id":o.execution,"outcome":outcome,"delivered":delivered,"worker_gone":o.endpoint.as_ref().and_then(|id|s.endpoints.get(id)).filter(|e|e.created==o.endpoint_created).map(|e|e.closed_by=="agent").unwrap_or(o.gone_snapshot),"requested_at":o.created});
        if !reason.is_empty() {
            r["reason"] = json!(reason);
        }
        if !message.is_empty() {
            r["reason_message"] = json!(message);
        }
        r
    }
    fn order_answer(s: &State, o: &Order) -> Result<Value> {
        let mut r = Self::order_record(s, o);
        if r["outcome"] == "accepted" {
            r["ok"] = json!(true);
            Ok(r)
        } else {
            let mut e = Error::new(
                o.status,
                r["reason"].as_str().unwrap_or("unconfirmed"),
                r["reason_message"].as_str().unwrap_or(""),
            );
            e.details = r;
            Err(e)
        }
    }
    pub fn place(&self, leaf: &str, execution: &str, text: &str, oid: &str) -> Result<Value> {
        let mut s = self.state.lock().unwrap();
        let mut created = now();
        let mut replace_position = None;
        if let Some(existing) = s
            .orders
            .iter()
            .find(|o| o.lock().unwrap().id == oid)
            .cloned()
        {
            let old = existing.lock().unwrap();
            if old.leaf != leaf || old.requested != execution || old.text != text {
                return Err(Error::new(
                    409,
                    "order_id_conflict",
                    format!("order_id {oid} is already bound to a different order"),
                ));
            }
            if old.uncertainty.is_none() {
                drop(old);
                let deadline = now() + 6. + self.ack + 5.;
                while !existing.lock().unwrap().answered && now() < deadline {
                    s = self
                        .wake
                        .wait_timeout(s, Duration::from_secs_f64((deadline - now()).max(0.)))
                        .unwrap()
                        .0;
                }
                return Self::order_answer(&s, &existing.lock().unwrap());
            }
            created = old.created;
            drop(old);
            replace_position = s.orders.iter().position(|o| Arc::ptr_eq(o, &existing));
        }
        let order = Arc::new(Mutex::new(Order {
            id: oid.into(),
            leaf: leaf.into(),
            requested: execution.into(),
            text: text.into(),
            execution: String::new(),
            endpoint: None,
            endpoint_created: 0.,
            gone_snapshot: false,
            created,
            command: None,
            refusal: None,
            uncertainty: None,
            status: 200,
            answered: false,
        }));
        if let Some(position) = replace_position {
            s.orders[position] = order.clone();
        } else {
            s.orders.push_back(order.clone());
        }
        while s.orders.len() > 512 {
            s.orders.pop_front();
        }
        Self::reap(&mut s);
        let deadline = now() + 6.;
        while Self::members(&s, leaf).is_empty() && now() < deadline {
            s = self
                .wake
                .wait_timeout(s, Duration::from_millis(250))
                .unwrap()
                .0;
        }
        let current = Self::current(&Self::members(&s, leaf));
        let selected = current.map(|e| e.id.clone());
        let endpoint_created = current.map(|e| e.created).unwrap_or_default();
        let gone_snapshot = current.is_some_and(|e| e.closed_by == "agent");
        let refusal = if let Some(e) = current {
            if e.id != execution {
                if Self::members(&s, leaf).iter().any(|e| e.id == execution) {
                    Some((409,"execution_superseded",format!("leaf {leaf} is now execution {}; the order was aimed at {execution} and was not delivered",e.id)))
                } else {
                    Some((404,"execution_not_found",format!("this hub holds no execution {execution} for leaf {leaf} (its current execution is {})",e.id)))
                }
            } else if e.closed_by == "agent" {
                Some((410,"worker_gone",format!("the agent owning execution {} reported its worker ended (exit {}), so the order was not delivered",e.id,if e.exit.is_null() {"None".into()} else if let Some(text)=e.exit.as_str() {text.to_owned()} else {python_repr_value(&e.exit)})))
            } else if e.closed > 0. {
                Some((409,"hub_closed_record",format!("the hub closed its record of execution {} because it could no longer steer it; the order was not delivered, and this is not evidence about the worker",e.id)))
            } else if !e.retry {
                Some((409,"endpoint_not_orderable",format!("execution {} did not advertise reliable result acknowledgement, so the order was not delivered",e.id)))
            } else {
                None
            }
        } else {
            None
        };
        {
            let mut o = order.lock().unwrap();
            o.endpoint = selected.clone();
            o.endpoint_created = endpoint_created;
            o.gone_snapshot = gone_snapshot;
            o.execution = selected.clone().unwrap_or_default();
            if let Some((status, code, message)) = refusal {
                o.status = status;
                o.refusal = Some((code.into(), message));
                o.answered = true;
            }
            if selected.is_none() {
                o.uncertainty=Some(("membership_unresolved".into(),format!("this hub holds no endpoint for leaf {leaf}, which is not evidence that its worker is gone")));
                o.answered = true;
            }
            if o.answered {
                let o = o.clone();
                self.wake.notify_all();
                return Self::order_answer(&s, &o);
            }
        }
        drop(s);
        let result = self.submit(
            selected.as_deref().unwrap(),
            "input",
            json!({"text":text,"keys":null,"submit":true}),
            Some(&order),
        );
        let s = self.state.lock().unwrap();
        let mut o = order.lock().unwrap();
        let taken = o
            .command
            .as_ref()
            .is_some_and(|c| c.lock().unwrap().taken > 0.);
        o.answered = true;
        if let Err(e) = &result {
            o.status = e.status;
            if !taken {
                o.refusal = Some((e.code.clone(), e.message.clone()));
            }
        }
        let o = o.clone();
        self.wake.notify_all();
        if let Err(mut e) = result {
            e.details = Self::order_record(&s, &o);
            Err(e)
        } else {
            Self::order_answer(&s, &o)
        }
    }
}
pub fn positive(v: &Value, default: usize, name: &str) -> Result<usize> {
    if v.is_null() {
        return Ok(default);
    }
    let parsed = if let Some(b) = v.as_bool() {
        Some(i64::from(b))
    } else if let Some(n) = v.as_i64() {
        Some(n)
    } else if let Some(n) = v.as_f64() {
        Some(n as i64)
    } else {
        v.as_str().and_then(|s| s.trim().parse().ok())
    };
    parsed
        .filter(|n| *n > 0)
        .map(|n| n as usize)
        .ok_or_else(|| {
            Error::new(
                400,
                &format!("bad_{name}"),
                format!("{name} must be a positive integer"),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Arc<Hub>, String, String) {
        let hub = Hub::new(vec![("test".into(), vec!["publish".into()])], 30., 0.01);
        let eid = "a".repeat(32);
        let result=hub.register(&json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","capabilities":["idempotent_command_results"]}),"").unwrap();
        let capability = result["command_capability"].as_str().unwrap().to_owned();
        (hub, eid, capability)
    }
    #[test]
    fn listing_selects_current_execution_once_per_retained_leaf() {
        let hub = Hub::new(vec![], 30., 0.01);
        for index in 0..2000 {
            hub.register(
                &json!({"protocol":3,"endpoint_id":format!("{index:032x}"),
                    "machine":format!("box-{}", (index / 4) % 2),
                    "label":format!("worker-{}", index / 4),"rows":1,"cols":1}),
                "",
            )
            .unwrap();
        }
        let mut s = hub.state.lock().unwrap();
        let created = now();
        for index in 0..2000 {
            let member = index % 4;
            let group = index / 4;
            let e = s.endpoints.get_mut(&format!("{index:032x}")).unwrap();
            e.created = created + index as f64;
            e.heard = match group % 4 {
                0 => member == 0,
                3 => member == 0 || member == 2,
                _ => false,
            };
            if group % 4 == 2 || group % 4 < 2 && member == 3 {
                e.close(json!(0), "agent");
            }
        }
        let records = Hub::listing(&s);
        assert_eq!(records.len(), 2000);
        let current: Vec<_> = records
            .iter()
            .filter(|r| r["current_execution"] == true)
            .collect();
        assert_eq!(current.len(), 500);
        for record in current {
            let group: usize = record["label"]
                .as_str()
                .unwrap()
                .strip_prefix("worker-")
                .unwrap()
                .parse()
                .unwrap();
            let member = match group % 4 {
                0 => 0,
                1 | 3 => 2,
                _ => 3,
            };
            assert_eq!(
                record["endpoint_id"],
                format!("{:032x}", group * 4 + member)
            );
        }
        for pair in records.windows(2) {
            let machine = pair[0]["machine"]
                .as_str()
                .unwrap()
                .cmp(pair[1]["machine"].as_str().unwrap());
            assert!(
                machine.is_lt()
                    || machine.is_eq()
                        && pair[0]["created_at"].as_f64().unwrap()
                            <= pair[1]["created_at"].as_f64().unwrap()
            );
        }
    }
    #[test]
    fn silence_releases_identity_without_claiming_worker_gone() {
        let (hub, eid, _) = fixture();
        let mut s = hub.state.lock().unwrap();
        s.endpoints.get_mut(&eid).unwrap().seen = now() - 11.;
        Hub::reap(&mut s);
        let record = Hub::listing(&s).pop().unwrap();
        assert!(record["closed_by"].is_null());
        assert!(record["closed_at"].is_null());
        assert_eq!(record["current_execution"], true);
        assert!(s.endpoints[&eid].presumed);
    }
    #[test]
    fn close_moves_from_presumption_to_fact_and_revokes_capability() {
        let (hub, eid, cap) = fixture();
        let mut s = hub.state.lock().unwrap();
        let e = s.endpoints.get_mut(&eid).unwrap();
        e.close(Value::Null, "hub");
        e.close(json!(7), "agent");
        e.close(Value::Null, "hub");
        assert_eq!(e.closed_by, "agent");
        assert_eq!(e.exit, json!(7));
        assert_eq!(
            Hub::authorize(e, "box", &cap).unwrap_err().code,
            "endpoint_unauthorized"
        );
    }
    #[test]
    fn command_traffic_prunes_expired_results_without_health_poll() {
        let (hub, eid, cap) = fixture();
        let cid = "b".repeat(32);
        {
            let mut s = hub.state.lock().unwrap();
            s.machines
                .get_mut("box")
                .unwrap()
                .completed
                .insert(cid.clone(), (true, "".into(), now() - 901., eid));
        }
        assert_eq!(
            hub.complete("box", &cid, true, "", &cap).unwrap_err().code,
            "no_such_command"
        );
    }
    #[test]
    fn completed_commands_release_payloads_and_preserve_result_retries() {
        let (mut hub, eid, cap) = fixture();
        Arc::get_mut(&mut hub).unwrap().ack = 5.;
        let submit_hub = hub.clone();
        let execution = eid.clone();
        let request = std::thread::spawn(move || {
            submit_hub.submit(&execution, "input", json!({"text":"hello"}), None)
        });
        let commands = hub.take("box", &eid, 5., &cap).unwrap();
        assert_eq!(commands.len(), 1);
        let cid = commands[0]["command_id"].as_str().unwrap();
        let weak = Arc::downgrade(&hub.state.lock().unwrap().commands[cid]);
        assert_eq!(
            hub.complete("box", cid, true, "", "invalid")
                .unwrap_err()
                .code,
            "endpoint_unauthorized"
        );
        assert!(hub.state.lock().unwrap().commands.contains_key(cid));
        hub.complete("box", cid, true, "", &cap).unwrap();
        assert!(!hub.state.lock().unwrap().commands.contains_key(cid));
        request.join().unwrap().unwrap();
        assert!(weak.upgrade().is_none());
        hub.complete("box", cid, true, "", &cap).unwrap();
        assert_eq!(
            hub.complete("box", cid, false, "refused", &cap)
                .unwrap_err()
                .code,
            "result_conflict"
        );
    }
    #[test]
    fn completed_orders_keep_their_journal_without_global_command_payloads() {
        let (mut hub, eid, cap) = fixture();
        Arc::get_mut(&mut hub).unwrap().ack = 5.;
        let order_hub = hub.clone();
        let execution = eid.clone();
        let request = std::thread::spawn(move || {
            order_hub.place("box/worker", &execution, "hello", "completed")
        });
        let commands = hub.take("box", &eid, 5., &cap).unwrap();
        assert_eq!(commands.len(), 1);
        let cid = commands[0]["command_id"].as_str().unwrap();
        hub.complete("box", cid, true, "", &cap).unwrap();
        assert!(!hub.state.lock().unwrap().commands.contains_key(cid));
        assert_eq!(request.join().unwrap().unwrap()["outcome"], "accepted");
        assert_eq!(
            hub.place("box/worker", &eid, "hello", "completed").unwrap()["outcome"],
            "accepted"
        );
        assert!(hub.take("box", &eid, 0., &cap).unwrap().is_empty());
    }
    #[test]
    fn withdrawn_orders_release_global_commands_and_never_redeliver() {
        let (hub, eid, cap) = fixture();
        let first = hub
            .place("box/worker", &eid, "hello", "withdrawn")
            .unwrap_err();
        assert_eq!(first.details["delivered"], false);
        assert!(hub.state.lock().unwrap().commands.is_empty());
        let resent = hub
            .place("box/worker", &eid, "hello", "withdrawn")
            .unwrap_err();
        assert_eq!(resent.details["outcome"], "refused");
        assert_eq!(resent.details["delivered"], false);
        assert!(hub.take("box", &eid, 0., &cap).unwrap().is_empty());
    }
    #[test]
    fn pending_commands_and_journal_keep_their_own_reference_lifetimes() {
        let (hub, eid, cap) = fixture();
        let order_hub = hub.clone();
        let execution = eid.clone();
        let request =
            std::thread::spawn(move || order_hub.place("box/worker", &execution, "hello", "order"));
        let mut commands = vec![];
        for _ in 0..100 {
            commands = hub.take("box", &eid, 0., &cap).unwrap();
            if !commands.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let cid = commands[0]["command_id"].as_str().unwrap();
        let first = request.join().unwrap().unwrap_err();
        assert_eq!(first.details["delivered"], Value::Null);
        {
            let mut s = hub.state.lock().unwrap();
            s.commands[cid].lock().unwrap().taken = now() - 901.;
            Hub::reap(&mut s);
            assert!(!s.commands.contains_key(cid));
        }
        let resent = hub.place("box/worker", &eid, "hello", "order").unwrap_err();
        assert_eq!(resent.details["outcome"], "unconfirmed");
        assert_eq!(resent.details["delivered"], Value::Null);
        assert_eq!(
            hub.complete("box", cid, true, "", &cap).unwrap_err().code,
            "no_such_command"
        );
    }
    #[test]
    fn order_holds_authoritative_close_after_endpoint_retention_expires() {
        let (hub, eid, _) = fixture();
        {
            let mut s = hub.state.lock().unwrap();
            s.endpoints.get_mut(&eid).unwrap().close(json!(0), "agent");
        }
        let record = hub
            .place("box/worker", &eid, "hello", "closed")
            .unwrap_err();
        assert_eq!(record.details["worker_gone"], true);
        {
            let mut s = hub.state.lock().unwrap();
            s.endpoints.get_mut(&eid).unwrap().closed = now() - 3601.;
            Hub::reap(&mut s);
            assert!(s.endpoints.is_empty());
        }
        let retained = hub
            .place("box/worker", &eid, "hello", "closed")
            .unwrap_err();
        assert_eq!(retained.details["worker_gone"], true);
    }
    #[test]
    fn an_active_order_answers_even_after_the_journal_evicts_its_id() {
        let hub = Hub::new(vec![], 30., 5.);
        let eid = "a".repeat(32);
        let legacy = "b".repeat(32);
        let response=hub.register(&json!({"protocol":3,"endpoint_id":eid,"machine":"box","label":"worker","capabilities":["idempotent_command_results"]}),"").unwrap();
        let cap = response["command_capability"].as_str().unwrap().to_owned();
        hub.register(
            &json!({"protocol":3,"endpoint_id":legacy,"machine":"box","label":"legacy"}),
            "",
        )
        .unwrap();
        let worker_hub = hub.clone();
        let execution = eid.clone();
        let request = std::thread::spawn(move || {
            worker_hub.place("box/worker", &execution, "hello", "evicted")
        });
        let mut commands = vec![];
        for _ in 0..100 {
            commands = hub.take("box", &eid, 0., &cap).unwrap();
            if !commands.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        for i in 0..512 {
            assert_eq!(
                hub.place("box/legacy", &legacy, "hello", &format!("volume-{i}"))
                    .unwrap_err()
                    .code,
                "endpoint_not_orderable"
            );
        }
        hub.complete(
            "box",
            commands[0]["command_id"].as_str().unwrap(),
            true,
            "",
            &cap,
        )
        .unwrap();
        assert_eq!(request.join().unwrap().unwrap()["outcome"], "accepted");
    }
}
