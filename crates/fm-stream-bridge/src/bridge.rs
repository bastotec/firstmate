//! Bridge state: per-leaf sequence counters and the listing-to-records
//! translation, ported from the reference's `Bridge` class.

use std::collections::HashMap;
use std::time::Instant;

use fm_stream_wire::{resolve_listing, LeafEndpoint, LeafHeartbeat};

use crate::hub::BridgeError;

/// A leaf worker's id: "<machine>/<label>".
pub type LeafId = String;

/// The bridge's per-process state.  Two consecutive polls of the same listing
/// must differ: `sequence` counts the records already emitted per leaf, so a
/// flat but live stream visibly moves.
pub struct Bridge {
    fleet_id: String,
    epoch: i64,
    sequences: HashMap<LeafId, u64>,
}

impl Bridge {
    pub fn new(fleet_id: &str, epoch: i64) -> Self {
        Bridge {
            fleet_id: fleet_id.to_string(),
            epoch,
            sequences: HashMap::new(),
        }
    }

    /// Translate one hub `/v1/tasks` answer into the records to emit, taken
    /// at the given producer clock and stamped with the hub-arrival clock.
    /// Both clocks are milliseconds and both are validated finite and
    /// non-negative by the caller.
    pub fn translate(
        &mut self,
        listing: &serde_json::Value,
        at_ms: f64,
        received_ms: f64,
    ) -> Result<Vec<LeafHeartbeat>, BridgeError> {
        let leaves: Vec<LeafEndpoint> = resolve_listing(listing)
            .map_err(|_| BridgeError("the hub listing carries no tasks array".to_string()))?;
        let mut records = Vec::with_capacity(leaves.len());
        for endpoint in leaves {
            let leaf = endpoint.leaf_id();
            let sequence = self.sequences.get(&leaf).copied().unwrap_or(0) + 1;
            self.sequences.insert(leaf.clone(), sequence);
            let state = endpoint.heartbeat_state();
            records.push(LeafHeartbeat {
                fleet_id: self.fleet_id.clone(),
                leaf_worker_id: leaf,
                parent_mate_id: endpoint.machine,
                execution_id: endpoint.endpoint_id,
                stream_epoch: self.epoch,
                sequence,
                state,
                producer_monotonic_ms: at_ms,
                hub_arrival_ms: received_ms,
            });
        }
        Ok(records)
    }
}

/// The producer's own monotonic clock: milliseconds since the bridge started,
/// rounded to three decimals like the reference.  Independent of the wall
/// clock so records keep flowing and sequences keep counting while the
/// bridge's process lives, however the host's date shifts.
pub struct Clock {
    started: Instant,
}

impl Clock {
    pub fn new() -> Self {
        Clock {
            started: Instant::now(),
        }
    }

    /// Milliseconds since start, rounded to three decimal places.
    pub fn ms(&self) -> f64 {
        round_three_decimals(self.started.elapsed().as_secs_f64() * 1000.0)
    }
}

fn round_three_decimals(value: f64) -> f64 {
    (value * 1000.0).round_ties_even() / 1000.0
}

impl Default for Clock {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn translate_sequences_per_leaf_and_restarts_from_zero() {
        let listing = json!({"tasks": [
            {"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "box-a",
             "label": "t1", "closed_by": null, "exit_code": null},
            {"endpoint_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "machine": "box-a",
             "label": "t2", "closed_by": null, "exit_code": null},
        ]});
        let mut bridge = Bridge::new("fleet-t", 0);
        let first = bridge.translate(&listing, 500.0, 501.0).unwrap();
        let second = bridge.translate(&listing, 1000.0, 1001.0).unwrap();
        assert_eq!(first[0].sequence, 1);
        assert_eq!(second[0].sequence, 2);
        // A fresh bridge (as after a restart) counts from one again.
        let mut fresh = Bridge::new("fleet-t", 0);
        let again = fresh.translate(&listing, 0.0, 0.0).unwrap();
        assert_eq!(again[0].sequence, 1);
    }

    #[test]
    fn translate_rejects_a_listing_without_tasks() {
        let mut bridge = Bridge::new("fleet-t", 0);
        assert!(bridge.translate(&json!({}), 0.0, 0.0).is_err());
    }

    #[test]
    fn clock_is_milliseconds_rounded_to_three_decimals() {
        let clock = Clock::new();
        let a = clock.ms();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let b = clock.ms();
        assert!(b > a);
        // The value is a multiple of 0.001 to rounding precision.
        let scaled = (b * 1000.0).round();
        assert!((scaled / 1000.0 - b).abs() < 1e-9);
        assert_eq!(round_three_decimals(1.2345), 1.234);
        assert_eq!(round_three_decimals(1.2355), 1.236);
    }
}
