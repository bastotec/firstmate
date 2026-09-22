//! fm-stream-bridge - translate the stream hub into the Bridge UI's live
//! wire format.  Rust port of `bin/fm-stream-bridge.py`; the Python adapter
//! remains the deployed reference until the port's parity is proven, and
//! `tests/fm-stream-bridge-rust.test.sh` diffs the two byte-for-byte.
//!
//! The port contract, kept throughout: same CLI surface (drop-in), same
//! exit statuses (0 ok; 2 usage, refused credential, wrong protocol, bad
//! input; 1 unreachable hub from snapshot; 130 interrupted), same stdout
//! bytes, same refusal classes.  See the crate-level docs of `fm_stream_wire`
//! for the byte-level encoder contract.

mod bridge;
mod cli;
mod commands;
mod compare;
mod hub;

use std::process::ExitCode;

use cli::Command;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let parsed = match cli::parse(&args) {
        Ok(parsed) => parsed,
        Err(usage) => {
            // -h/--help is not an error: print the asked-for help to stdout,
            // exit 0.  Every other usage problem is argparse's class: the
            // payload already carries the usage block and the error line.
            if let Some(which) = usage.is_help() {
                println!(
                    "{}",
                    cli::help_for(if which.is_empty() { None } else { Some(which) })
                );
                return ExitCode::from(0);
            }
            eprintln!("{}", usage.0);
            return ExitCode::from(2);
        }
    };
    // --protocol and --version resolve only after the whole command line
    // parsed successfully, exactly as the reference's argparse ordering does.
    if parsed.protocol {
        println!("{}", fm_stream_wire::HUB_PROTOCOL);
        return ExitCode::from(0);
    }
    if parsed.version {
        println!("{}", cli::BRIDGE_VERSION);
        return ExitCode::from(0);
    }
    let Some(command) = parsed.command else {
        eprintln!("{}", cli::help_for(None));
        return ExitCode::from(2);
    };
    // Every subcommand carries a fleet id; none may be empty.
    if command_fleet_id(&command).is_empty() {
        eprintln!("fm-stream-bridge: --fleet-id must not be empty");
        return ExitCode::from(2);
    }
    // serve/snapshot/translate carry an epoch; compare does not.
    if let Some(epoch) = command_epoch(&command) {
        if epoch < 0 {
            eprintln!("fm-stream-bridge: --epoch must not be negative");
            return ExitCode::from(2);
        }
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("fm-stream-bridge: cannot start: {error}");
            return ExitCode::from(1);
        }
    };
    let code: i32 = runtime.block_on(async {
        // An interrupt is the reference's KeyboardInterrupt: exit 130, from
        // any command, rather than a partial record or a traceback.
        tokio::spawn(async {
            let _ = tokio::signal::ctrl_c().await;
            std::process::exit(130);
        });
        match commands::run(command).await {
            Ok(code) => code,
            Err(commands::Failure::Refused(message)) => {
                eprintln!("fm-stream-bridge: {message}");
                2
            }
            Err(commands::Failure::Unreachable(message)) => {
                // Snapshot reports its own unreachable exit; this arm only
                // guards against future call sites.
                eprintln!("fm-stream-bridge: {message}");
                1
            }
            Err(commands::Failure::Stdio(message)) => {
                eprintln!("fm-stream-bridge: standard stream failed: {message}");
                1
            }
        }
    });
    ExitCode::from(code as u8)
}

fn command_fleet_id(command: &Command) -> &str {
    match command {
        Command::Serve { fleet_id, .. }
        | Command::Snapshot { fleet_id, .. }
        | Command::Translate { fleet_id, .. }
        | Command::Compare { fleet_id, .. } => fleet_id,
    }
}

fn command_epoch(command: &Command) -> Option<i64> {
    match command {
        Command::Serve { epoch, .. }
        | Command::Snapshot { epoch, .. }
        | Command::Translate { epoch, .. } => *epoch,
        Command::Compare { .. } => None,
    }
}
