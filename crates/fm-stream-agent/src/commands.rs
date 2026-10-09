//! Take, application and bounded result publication are independent. A network
//! outage never blocks original-turn reconciliation or permits successor delivery.
use super::{
    diag, hub_json, now,
    receiver::{Decision, Receiver},
    Agent, Error, RESULT_POST_SECS, RESULT_RETRY_SECS,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io;
use std::sync::{atomic::Ordering, mpsc, Arc};
use std::time::{Duration, Instant};

struct Receipt {
    command: Value,
    response: Arc<hub_json::Response>,
    due: Instant,
}
impl Agent {
    fn is_deck(&self) -> bool {
        self.pty.foreground(None).iter().any(|process| {
            let args = process["args"].as_str().unwrap_or("");
            args.split(' ')
                .next()
                .unwrap_or("")
                .contains("fm-deck-worker")
                || args.contains("fm-deck-worker.sh")
        })
    }
    fn native_apply(
        &self,
        receiver: Option<&Receiver>,
        command: &mut Value,
        response: &hub_json::Response,
        fresh: bool,
    ) -> io::Result<Decision> {
        if let Some(result) = command.get("_application_result") {
            return Ok(Decision::Confirmed(
                result[0].as_bool().unwrap_or(false),
                result[1].as_str().unwrap_or("").into(),
            ));
        }
        let payload = command["payload"].clone();
        if command["kind"] == "steer" {
            if command["endpoint_id"] != self.id {
                return Ok(Decision::Confirmed(
                    false,
                    "stale execution; steer was not applied".into(),
                ));
            }
            let order = payload["order_id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or(command["command_id"].as_str())
                .unwrap_or("")
                .to_owned();
            let id = command["command_id"].as_str().unwrap_or("").to_owned();
            let execution = payload["execution_id"].as_str().unwrap_or("");
            let text = payload["text"].as_str().unwrap_or("");
            if fresh
                && command.get("_application_result").is_none()
                && command["_legacy_prepared"] != true
            {
                if let Some(receiver) = receiver {
                    let reconcile = command["_reservation_attempted"] == true;
                    command["_reservation_attempted"] = json!(true);
                    match receiver.apply(
                        &order,
                        execution,
                        text,
                        || self.pty.alive(),
                        reconcile,
                        &mut command["_steering_reservation"],
                        &id,
                        true,
                    )? {
                        Decision::Legacy => {
                            if self.is_deck() {
                                command["_application_result"] = json!([
                                    false,
                                    "Deck steering interface unavailable; no PTY fallback"
                                ]);
                            } else {
                                command["_legacy_prepared"] = json!(true);
                            }
                        }
                        Decision::Confirmed(ok, error) => {
                            command["_application_result"] = json!([ok, error]);
                        }
                        Decision::Pending(note) if note == "Deck application reserved" => {
                            command["_native_prepared"] = json!(true);
                        }
                        pending => return Ok(pending),
                    }
                }
            }
            if let Some(result) = command.get("_application_result") {
                return Ok(Decision::Confirmed(
                    result[0].as_bool().unwrap_or(false),
                    result[1].as_str().unwrap_or("").into(),
                ));
            }
            let reconcile = !fresh || command["_native_prepared"] == true;
            if command["_legacy_prepared"] != true {
                if let Some(receiver) = receiver {
                    match receiver.apply(
                        &order,
                        execution,
                        text,
                        || self.pty.alive(),
                        reconcile,
                        &mut command["_steering_reservation"],
                        &id,
                        false,
                    )? {
                        Decision::Legacy => (),
                        result => return Ok(result),
                    }
                }
            }
            if reconcile {
                return Ok(Decision::Pending(
                    "native steering binding unavailable; application unconfirmed".into(),
                ));
            }
            if self.is_deck() {
                return Ok(Decision::Confirmed(
                    false,
                    "Deck steering interface unavailable; no PTY fallback".into(),
                ));
            }
            let mut input = command.clone();
            input["kind"] = json!("input");
            return Ok(applied(self.apply(&input, response)));
        }
        Ok(applied(self.apply(command, response)))
    }
    pub(super) fn commands(&self) {
        let receiver = Receiver::from_status(&self.options.status_path, &self.id);
        let empty = Arc::new(hub_json::decode(b"{}", false).unwrap());
        let mut receipts: BTreeMap<String, Receipt> = BTreeMap::new();
        let mut pending: BTreeMap<String, Receipt> = BTreeMap::new();
        let mut outcomes: BTreeMap<String, Value> = BTreeMap::new();
        let mut loaded = receiver.is_none();
        let mut load_due = Instant::now();
        let mut poll_due = Instant::now();
        let mut take_started = Instant::now();
        let mut backoff = 2.0f64;
        let mut shutdown: Option<Instant> = None;
        let mut wake_generation = self.wake.snapshot();
        let path = format!(
            "/v1/agent/commands?machine={}&endpoint={}&wait={}",
            self.options.machine, self.id, self.options.poll_secs as u64
        );
        std::thread::scope(|scope| {
            let mut take: Option<mpsc::Receiver<Result<hub_json::Response, Error>>> = None;
            let mut post: Option<(String, mpsc::Receiver<bool>)> = None;
            loop {
                // Taken before looking at the threads, so a take or post that
                // finishes after this point still ends this iteration's wait.
                let tick = self.tick.snapshot();
                let instant = Instant::now();
                let wall = now();
                let stopping =
                    self.stop.load(Ordering::SeqCst) || self.stood_down.load(Ordering::SeqCst);
                if stopping && shutdown.is_none() {
                    shutdown = Some(instant + Duration::from_secs(RESULT_RETRY_SECS));
                    for receipt in pending.values_mut() {
                        receipt.due = instant;
                    }
                }
                if let Some(deadline) = *self.result_deadline.lock().unwrap() {
                    shutdown = Some(shutdown.unwrap_or(deadline).min(deadline));
                }
                if shutdown
                    .is_some_and(|at| instant >= at + Duration::from_secs(2 * RESULT_POST_SECS + 1))
                {
                    break;
                }
                if let Some(answer) = take.as_ref().and_then(completed) {
                    take = None;
                    match answer {
                        Ok(answer) => {
                            backoff = 2.0;
                            // Poll again at once after a command (the next key
                            // is likely close behind); an empty answer keeps the
                            // old 100 ms floor, so a zero wait never spins.
                            poll_due = if answer["commands"]
                                .as_array()
                                .is_some_and(|commands| !commands.is_empty())
                            {
                                instant
                            } else {
                                take_started + Duration::from_millis(100)
                            };
                            let answer = Arc::new(answer);
                            for command in answer["commands"].as_array().into_iter().flatten() {
                                if let Some(id) = command["command_id"].as_str() {
                                    receipts.insert(
                                        id.into(),
                                        Receipt {
                                            command: command.clone(),
                                            response: answer.clone(),
                                            due: instant,
                                        },
                                    );
                                }
                            }
                        }
                        Err(Error::Superseded) => self.stand_down(),
                        Err(error) => {
                            diag(&self.options, "command-poll-failed", error);
                            poll_due = instant + Duration::from_secs_f64(backoff);
                            backoff = (backoff * 2.0).min(60.0);
                        }
                    }
                }
                if let Some(settled) = post.as_ref().and_then(|(_, task)| completed(task)) {
                    let (id, _) = post.take().unwrap();
                    let record = outcomes.get_mut(&id).unwrap();
                    let mut limit = record["expires_at"].as_f64().unwrap();
                    if let Some(at) = shutdown {
                        let wall_deadline = if at >= instant {
                            wall + at.duration_since(instant).as_secs_f64()
                        } else {
                            wall - instant.duration_since(at).as_secs_f64()
                        };
                        limit = limit.min(wall_deadline);
                    }
                    record["settled"] = json!(
                        settled
                            || (wall >= limit
                                && record["_last_attempt_at"].as_f64().unwrap_or(0.0) >= limit)
                    );
                    let backoff = record["backoff"].as_f64().unwrap_or(2.0);
                    record["retry_at"] = json!((wall + backoff).min(limit));
                    record["backoff"] = json!((backoff * 2.0).min(60.0));
                    record["_dirty"] = json!(true);
                }
                if !loaded && instant >= load_due {
                    match receiver.as_ref().unwrap().recover() {
                        Ok((commands, saved)) => {
                            for mut record in saved {
                                if record["settled"] != true
                                    && wall > record["expires_at"].as_f64().unwrap_or(0.0)
                                {
                                    record["settled"] = json!(true);
                                    record["_dirty"] = json!(true);
                                }
                                if let Some(id) =
                                    record["result"]["command_id"].as_str().map(str::to_owned)
                                {
                                    outcomes.insert(id, record);
                                }
                            }
                            for command in commands {
                                let id = command["command_id"].as_str().unwrap().to_owned();
                                pending.insert(
                                    id,
                                    Receipt {
                                        command,
                                        response: empty.clone(),
                                        due: instant,
                                    },
                                );
                            }
                            loaded = true;
                        }
                        Err(error) => {
                            diag(&self.options, "command-recovery-failed", error);
                            load_due = instant + Duration::from_secs(5);
                        }
                    }
                }
                if !self.stood_down.load(Ordering::SeqCst) {
                    for fresh in [false, true] {
                        let map = if fresh { &mut receipts } else { &mut pending };
                        let ready: Vec<_> = map
                            .iter()
                            .filter(|(_, r)| r.due <= Instant::now())
                            .map(|(id, _)| id.clone())
                            .collect();
                        for id in ready {
                            // Remove before borrowing both queues for scheduling.
                            let mut receipt = if fresh {
                                receipts.remove(&id).unwrap()
                            } else {
                                pending.remove(&id).unwrap()
                            };
                            if outcomes
                                .get_mut(&id)
                                .is_some_and(|record| persist(receiver.as_ref(), record))
                            {
                                continue;
                            }
                            match self.native_apply(
                                receiver.as_ref(),
                                &mut receipt.command,
                                &receipt.response,
                                fresh,
                            ) {
                                Ok(Decision::Confirmed(ok, error)) => {
                                    receipt.command["_application_result"] = json!([ok, error]);
                                    let record = outcomes.entry(id.clone()).or_insert_with(|| {
                                        let order = receipt.command["payload"]["order_id"].as_str().filter(|s| !s.is_empty()).unwrap_or(&id);
                                        json!({"order_id":order,"result":{"machine":self.options.machine,"command_id":id,"ok":ok,"error":error},"expires_at":now()+RESULT_RETRY_SECS as f64,"retry_at":now(),"backoff":2.0,"settled":false,"_dirty":true})
                                    });
                                    if !persist(receiver.as_ref(), record) {
                                        receipt.due = Instant::now() + Duration::from_secs(5);
                                        if !fresh || receipt.command["_native_prepared"] == true {
                                            pending.insert(id, receipt);
                                        } else {
                                            receipts.insert(id, receipt);
                                        }
                                    }
                                }
                                Ok(Decision::Pending(note)) => {
                                    receipt.due = Instant::now()
                                        + if note == "Deck application pending" {
                                            Duration::from_millis(100)
                                        } else {
                                            Duration::from_secs(5)
                                        };
                                    if !fresh || receipt.command["_native_prepared"] == true {
                                        pending.insert(id, receipt);
                                    } else {
                                        receipts.insert(id, receipt);
                                    }
                                }
                                Err(error) => {
                                    diag(&self.options, "command-apply-failed", error);
                                    receipt.due = Instant::now() + Duration::from_secs(5);
                                    if !fresh || receipt.command["_native_prepared"] == true {
                                        pending.insert(id, receipt);
                                    } else {
                                        receipts.insert(id, receipt);
                                    }
                                }
                                Ok(Decision::Legacy) => {
                                    unreachable!("native application resolves legacy")
                                }
                            }
                        }
                    }
                } else {
                    receipts.clear();
                    pending.clear();
                }
                for record in outcomes.values_mut() {
                    if !persist(receiver.as_ref(), record)
                        && record["_persist_failed"] != true
                        && record["_dirty"] == true
                    {
                        record["_persist_failed"] = json!(true);
                        diag(
                            &self.options,
                            "result-persist-failed",
                            format_args!(
                                "order {} result could not be persisted; retrying",
                                record["order_id"].as_str().unwrap_or("")
                            ),
                        );
                    } else if record["_persist_failed"] == true && record["_dirty"] != true {
                        record["_persist_failed"] = json!(false);
                    }
                }
                let stopping =
                    self.stop.load(Ordering::SeqCst) || self.stood_down.load(Ordering::SeqCst);
                if stopping
                    && take.is_none()
                    && receipts.is_empty()
                    && post.is_none()
                    && outcomes
                        .values()
                        .all(|record| record["settled"] == true && record["_dirty"] != true)
                {
                    break;
                }
                if !stopping && loaded && receipts.is_empty() && take.is_none() {
                    let generation = self.wake.snapshot();
                    if generation != wake_generation {
                        poll_due = Instant::now();
                        wake_generation = generation;
                    }
                    if Instant::now() >= poll_due {
                        take_started = Instant::now();
                        let path = &path;
                        let (done, completion) = mpsc::channel();
                        take = Some(completion);
                        scope.spawn(move || {
                            let answer = self.hub.call(
                                "GET",
                                path,
                                None,
                                Duration::from_secs_f64(self.options.poll_secs + 15.0),
                            );
                            let _ = done.send(answer);
                            self.tick.notify();
                        });
                    }
                }
                if post.is_none() {
                    let ready = outcomes
                        .iter()
                        .filter(|(_, record)| {
                            record["settled"] != true
                                && record["_dirty"] != true
                                && record["retry_at"].as_f64().unwrap_or(0.0) <= now()
                        })
                        .min_by(|(_, a), (_, b)| {
                            a["retry_at"]
                                .as_f64()
                                .unwrap_or(0.0)
                                .total_cmp(&b["retry_at"].as_f64().unwrap_or(0.0))
                        })
                        .map(|(id, _)| id.clone());
                    if let Some(id) = ready {
                        let record = outcomes.get_mut(&id).unwrap();
                        record["_last_attempt_at"] = json!(now());
                        let result = record["result"].clone();
                        let (done, completion) = mpsc::channel();
                        let options = &self.options;
                        post = Some((id, completion));
                        scope.spawn(move || {
                            let answer = self.hub.call(
                                "POST",
                                "/v1/agent/results",
                                Some(&result),
                                Duration::from_secs(RESULT_POST_SECS),
                            );
                            // A definitive rejection settles; an UNMATCHED
                            // command id does not, because it is not a
                            // verdict on this result and the hub may still
                            // be able to accept it.
                            let settled = matches!(answer, Ok(_) | Err(Error::Rejected));
                            if !settled {
                                diag(
                                    options,
                                    "result-ack-failed",
                                    format_args!("result could not be posted: {}", answer.err().unwrap()),
                                );
                            }
                            let _ = done.send(settled);
                            self.tick.notify();
                        });
                    }
                }
                // Timers (retries, Deck application) still run on this
                // 100 ms cadence; a returning take or post ends it at once.
                self.tick.settle(tick, Duration::from_millis(100));
            }
        });
    }
}
fn completed<T>(receiver: &mpsc::Receiver<T>) -> Option<T> {
    match receiver.try_recv() {
        Ok(value) => Some(value),
        Err(mpsc::TryRecvError::Empty) => None,
        Err(mpsc::TryRecvError::Disconnected) => panic!("command worker disconnected"),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::Wake;

    #[test]
    fn completion_is_consumable_before_the_worker_returns() {
        let wake = Arc::new(Wake::default());
        let generation = wake.snapshot();
        let (done, completion) = mpsc::channel();
        let (exit, hold) = mpsc::channel();
        let worker_wake = wake.clone();
        let worker = std::thread::spawn(move || {
            done.send(true).unwrap();
            worker_wake.notify();
            hold.recv().unwrap();
        });
        wake.settle(generation, Duration::from_secs(1));
        let result = completed(&completion);
        let running = !worker.is_finished();
        exit.send(()).unwrap();
        worker.join().unwrap();
        assert_eq!(result, Some(true));
        assert!(running);
    }
}
fn applied(result: Result<(), Error>) -> Decision {
    match result {
        Ok(()) => Decision::Confirmed(true, String::new()),
        Err(error) => Decision::Confirmed(false, error.to_string()),
    }
}
fn persist(receiver: Option<&Receiver>, record: &mut Value) -> bool {
    if record["_dirty"] != true {
        return true;
    }
    if record["_persist_at"].as_f64().is_some_and(|at| at > now()) {
        return false;
    }
    if let Some(receiver) = receiver {
        if receiver
            .save_result(
                record["order_id"].as_str().unwrap_or(""),
                record["result"]["command_id"].as_str().unwrap_or(""),
                record,
            )
            .is_err()
        {
            record["_persist_at"] = json!(now() + 5.0);
            return false;
        }
    }
    record["_dirty"] = json!(false);
    true
}
