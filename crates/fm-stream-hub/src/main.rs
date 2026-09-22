//! fm-stream-hub - skeleton of the Rust port.
//!
//! The hub is not ported yet: `bin/fm-stream-hub.py` remains the reference
//! and the deployed implementation.  This skeleton exists so the workspace
//! shape, the wire dependency, and the version/protocol surface land first;
//! the port task replaces the refusal below with the real server, built on
//! the tokio/axum stack the workspace already pins.
//!
//! The refusal is deliberate and loud: a half-built hub must never look
//! callable, because agents would register against a hub that forgets them.

use std::process::ExitCode;

const NOT_IMPLEMENTED: &str =
    "the Rust hub port is not implemented yet; bin/fm-stream-hub.py remains the reference";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [flag] if flag == "--protocol" => {
            println!("{}", fm_stream_wire::HUB_PROTOCOL);
            ExitCode::from(0)
        }
        [flag] if flag == "--version" => {
            println!("0.1.0-skeleton");
            ExitCode::from(0)
        }
        [command] if command == "serve" => {
            eprintln!("fm-stream-hub: {NOT_IMPLEMENTED}");
            ExitCode::from(2)
        }
        _ => {
            eprintln!("usage: fm-stream-hub [--protocol | --version | serve]");
            ExitCode::from(2)
        }
    }
}

#[cfg(test)]
mod tests {
    // The binary's thin dispatch is proven by the parity test script; the
    // unit here pins the refusal so the skeleton cannot silently become a
    // pretend hub.
    #[test]
    fn the_refusal_message_names_the_reference() {
        assert!(super::NOT_IMPLEMENTED.contains("not implemented"));
        assert!(super::NOT_IMPLEMENTED.contains("fm-stream-hub.py"));
    }
}
