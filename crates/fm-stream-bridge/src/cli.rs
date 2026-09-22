//! Hand-rolled argument parsing that mirrors the reference's argparse
//! surface: the same commands, flags, defaults, required options, `int`
//! coercions, error orderings, and exit-2 usage errors - including the
//! pinned `fm-stream-bridge.py` program name the reference's own argparse
//! configuration forces into every usage and error line.
//!
//! Byte-parity contract: the help and usage texts below are the reference's
//! exact output at the default 80-column width (pinned in the parity test);
//! the reference itself rewraps them under a set `COLUMNS`, the port does
//! not, which is the documented divergence here.  Error orderings follow
//! argparse exactly: scan-time errors (a flag's missing value, a bad int)
//! fire first, then the subcommand's missing-required check, then the merged
//! unrecognized-arguments refusal, which always reports the top-level usage.
//!
//! Epochs and intervals are intentionally bounded to signed 64-bit integers,
//! while accepted spellings and unique long-option prefixes match argparse.

pub const BRIDGE_VERSION: &str = "1.0.0-rust.1";
pub const DEFAULT_FLEET_ID: &str = "firstmate";
pub const DEFAULT_INTERVAL_MS: i64 = 500;
pub const MIN_INTERVAL_MS: i64 = 50;
pub const BRIDGE_STALE_MS: i64 = 1500;

/// The program name the reference's argparse pins (`prog="fm-stream-bridge.py"`),
/// used verbatim in usage and error lines for byte parity.
pub const PROG: &str = "fm-stream-bridge.py";

#[derive(Debug, PartialEq)]
pub enum Command {
    Serve {
        hub: String,
        token_file: String,
        fleet_id: String,
        epoch: Option<i64>,
        interval_ms: i64,
    },
    Snapshot {
        hub: String,
        token_file: String,
        fleet_id: String,
        epoch: Option<i64>,
    },
    Translate {
        fleet_id: String,
        epoch: Option<i64>,
    },
    Compare {
        hub: Option<String>,
        token_file: Option<String>,
        fleet_id: String,
        feed: Option<String>,
        home: Option<String>,
        crew_state: Option<String>,
    },
}

#[derive(Debug, PartialEq)]
pub struct Cli {
    pub protocol: bool,
    pub version: bool,
    pub command: Option<Command>,
}

/// A usage problem: the payload is exactly what goes to stderr before the
/// exit 2 - the usage block, then the argparse-shaped error line.  A
/// `HELP:` payload is not an error: it is `-h`/`--help`, printed to stdout
/// with exit 0.
#[derive(Debug)]
pub struct Usage(pub String);

impl Usage {
    /// A subcommand error: the subcommand's usage, then the reference's
    /// "prog sub:" error line.
    fn sub(command: &str, message: impl std::fmt::Display) -> Self {
        Usage(format!(
            "{}\n{} {command}: error: {message}",
            usage_for(Some(command)),
            PROG
        ))
    }

    /// A top-level error: the top-level usage, then the bare prog error line.
    fn top(message: impl std::fmt::Display) -> Self {
        Usage(format!("{}\n{}: error: {message}", usage_for(None), PROG))
    }

    fn help(command: &str) -> Self {
        Usage(format!("HELP:{command}"))
    }

    pub fn is_help(&self) -> Option<&str> {
        self.0.strip_prefix("HELP:")
    }
}

const MAIN_HELP: &str = "\
usage: fm-stream-bridge.py [-h] [--protocol] [--version]
                           {serve,snapshot,translate,compare} ...

Translate the stream hub into the Bridge UI's live wire format.

positional arguments:
  {serve,snapshot,translate,compare}
    serve               poll the hub and stream records
    snapshot            emit one tick and exit
    translate           replay recorded hub listings
    compare             compare against fm-crew-state.sh

options:
  -h, --help            show this help message and exit
  --protocol            print the hub protocol
  --version             print the adapter version";

const SERVE_HELP: &str = "\
usage: fm-stream-bridge.py serve [-h] --hub HUB --token-file TOKEN_FILE
                                 [--fleet-id FLEET_ID] [--epoch EPOCH]
                                 [--interval-ms INTERVAL_MS]

options:
  -h, --help            show this help message and exit
  --hub HUB             hub base URL
  --token-file TOKEN_FILE
                        file whose first line is a subscribe-class token
  --fleet-id FLEET_ID
  --epoch EPOCH
  --interval-ms INTERVAL_MS";

const SNAPSHOT_HELP: &str = "\
usage: fm-stream-bridge.py snapshot [-h] --hub HUB --token-file TOKEN_FILE
                                    [--fleet-id FLEET_ID] [--epoch EPOCH]

options:
  -h, --help            show this help message and exit
  --hub HUB             hub base URL
  --token-file TOKEN_FILE
                        file whose first line is a subscribe-class token
  --fleet-id FLEET_ID
  --epoch EPOCH";

const TRANSLATE_HELP: &str = "\
usage: fm-stream-bridge.py translate [-h] [--fleet-id FLEET_ID]
                                     [--epoch EPOCH]

options:
  -h, --help           show this help message and exit
  --fleet-id FLEET_ID
  --epoch EPOCH";

const COMPARE_HELP: &str = "\
usage: fm-stream-bridge.py compare [-h] [--hub HUB] [--token-file TOKEN_FILE]
                                   [--fleet-id FLEET_ID] [--feed FEED]
                                   [--home HOME] [--crew-state CREW_STATE]

options:
  -h, --help            show this help message and exit
  --hub HUB             hub base URL
  --token-file TOKEN_FILE
                        file whose first line is a subscribe-class token
  --fleet-id FLEET_ID
  --feed FEED
  --home HOME
  --crew-state CREW_STATE";

pub fn help_for(command: Option<&str>) -> &'static str {
    match command {
        Some("serve") => SERVE_HELP,
        Some("snapshot") => SNAPSHOT_HELP,
        Some("translate") => TRANSLATE_HELP,
        Some("compare") => COMPARE_HELP,
        _ => MAIN_HELP,
    }
}

/// The usage block of a help text: everything before the first blank line.
/// Error payloads embed it, exactly as argparse's `format_usage` does.
fn usage_for(command: Option<&str>) -> &'static str {
    help_for(command).split("\n\n").next().unwrap_or("")
}

/// One option's parse shape.  `int_flags` carries the reference's `type=int`
/// options, whose coercion errors fire at scan time like argparse's.
struct OptSpec {
    name: &'static str,
    is_int: bool,
}

const HUB: OptSpec = OptSpec {
    name: "hub",
    is_int: false,
};
const TOKEN_FILE: OptSpec = OptSpec {
    name: "token-file",
    is_int: false,
};
const FLEET_ID: OptSpec = OptSpec {
    name: "fleet-id",
    is_int: false,
};
const EPOCH: OptSpec = OptSpec {
    name: "epoch",
    is_int: true,
};
const INTERVAL_MS: OptSpec = OptSpec {
    name: "interval-ms",
    is_int: true,
};
const FEED: OptSpec = OptSpec {
    name: "feed",
    is_int: false,
};
const HOME: OptSpec = OptSpec {
    name: "home",
    is_int: false,
};
const CREW_STATE: OptSpec = OptSpec {
    name: "crew-state",
    is_int: false,
};
const PROTOCOL: OptSpec = OptSpec {
    name: "protocol",
    is_int: false,
};
const VERSION: OptSpec = OptSpec {
    name: "version",
    is_int: false,
};

/// Declaration order per subcommand, the order the reference adds arguments
/// in, which drives usage layout and the missing-required message.
struct CommandSpec {
    name: &'static str,
    specs: &'static [&'static OptSpec],
    required: &'static [&'static str],
}

const SERVE_SPEC: CommandSpec = CommandSpec {
    name: "serve",
    specs: &[&HUB, &TOKEN_FILE, &FLEET_ID, &EPOCH, &INTERVAL_MS],
    required: &["hub", "token-file"],
};
const SNAPSHOT_SPEC: CommandSpec = CommandSpec {
    name: "snapshot",
    specs: &[&HUB, &TOKEN_FILE, &FLEET_ID, &EPOCH],
    required: &["hub", "token-file"],
};
const TRANSLATE_SPEC: CommandSpec = CommandSpec {
    name: "translate",
    specs: &[&FLEET_ID, &EPOCH],
    required: &[],
};
const COMPARE_SPEC: CommandSpec = CommandSpec {
    name: "compare",
    specs: &[&HUB, &TOKEN_FILE, &FLEET_ID, &FEED, &HOME, &CREW_STATE],
    required: &[],
};

const COMMANDS: [&CommandSpec; 4] = [&SERVE_SPEC, &SNAPSHOT_SPEC, &TRANSLATE_SPEC, &COMPARE_SPEC];

/// Python's int() tolerates surrounding whitespace and digit separators.
fn parse_int(flag: &str, raw: &str) -> Result<i64, Usage> {
    let trimmed = raw.trim();
    let digits = trimmed
        .strip_prefix('+')
        .or_else(|| trimmed.strip_prefix('-'))
        .unwrap_or(trimmed)
        .as_bytes();
    let valid = !digits.is_empty()
        && digits.iter().enumerate().all(|(index, byte)| {
            byte.is_ascii_digit()
                || (*byte == b'_'
                    && index > 0
                    && index + 1 < digits.len()
                    && digits[index - 1].is_ascii_digit()
                    && digits[index + 1].is_ascii_digit())
        });
    if !valid {
        return Err(Usage(format!(
            "argument {flag}: invalid int value: '{raw}'"
        )));
    }
    trimmed
        .replace('_', "")
        .parse::<i64>()
        .map_err(|_| Usage(format!("argument {flag}: invalid int value: '{raw}'")))
}

enum LongMatch<'a> {
    Help,
    Known(&'a OptSpec),
    Ambiguous(Vec<&'static str>),
    Unknown,
}

fn match_long<'a>(name: &str, specs: &'a [&'a OptSpec]) -> LongMatch<'a> {
    if name == "help" {
        return LongMatch::Help;
    }
    if let Some(spec) = specs.iter().find(|spec| spec.name == name) {
        return LongMatch::Known(spec);
    }
    let mut matches = Vec::new();
    if "help".starts_with(name) {
        matches.push("help");
    }
    matches.extend(
        specs
            .iter()
            .filter(|spec| spec.name.starts_with(name))
            .map(|spec| spec.name),
    );
    match matches.as_slice() {
        ["help"] => LongMatch::Help,
        [only] => LongMatch::Known(
            specs
                .iter()
                .find(|spec| spec.name == *only)
                .expect("the sole non-help match came from specs"),
        ),
        [] => LongMatch::Unknown,
        _ => LongMatch::Ambiguous(matches),
    }
}

fn ambiguous(flag: &str, matches: &[&str]) -> String {
    format!(
        "ambiguous option: --{flag} could match {}",
        matches
            .iter()
            .map(|name| format!("--{name}"))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn ignored_value(name: &str, value: &str) -> String {
    format!("argument --{name}: ignored explicit argument '{value}'")
}

/// Whether a token looks like an option rather than a value: a leading dash
/// that is not a bare `-` and not a negative number, argparse's rule for
/// refusing to consume the next token as an option's argument (and, at scan
/// level, for holding a token as an unknown option rather than filling a
/// positional with it).
fn looks_like_option(token: &str) -> bool {
    if !token.starts_with('-') || token == "-" {
        return false;
    }
    let body = token.strip_prefix('-').unwrap_or(token);
    !is_negative_number(body)
}

/// argparse's negative-number matcher `^-\d+$|^-\d*\.\d+$` on the body:
/// a token like `-5` or `-5.5` is a positional (or a value) whenever the
/// parser has no options that look like negative numbers, which neither
/// level of this CLI has.
fn is_negative_number(body: &str) -> bool {
    let mut seen_digit = false;
    let mut seen_dot = false;
    for ch in body.chars() {
        match ch {
            '0'..='9' => seen_digit = true,
            '.' => {
                if seen_dot {
                    return false;
                }
                seen_dot = true;
            }
            _ => return false,
        }
    }
    seen_digit && !body.ends_with('.')
}

pub fn parse(args: &[String]) -> Result<Cli, Usage> {
    let mut cli = Cli {
        protocol: false,
        version: false,
        command: None,
    };
    let mut extras: Vec<String> = Vec::new();
    let mut positional_only = false;
    let mut index = 0;
    // Global phase: only --protocol/--version/-h/--help before the command.
    // An unknown option is held for the merged unrecognized refusal but never
    // consumes a value, and the first non-option token - negative numbers
    // included - fills the command positional, exactly as argparse assigns
    // tokens: whichever error that assignment produces fires first.
    while index < args.len() {
        let arg = args[index].as_str();
        if !positional_only {
            if arg == "-h" {
                return Err(Usage::help(""));
            }
            if arg == "--" {
                positional_only = true;
                index += 1;
                continue;
            }
            if let Some(stripped) = arg.strip_prefix("--") {
                let (flag, inline) = match stripped.split_once('=') {
                    Some((name, value)) => (name, Some(value)),
                    None => (stripped, None),
                };
                match match_long(flag, &[&PROTOCOL, &VERSION]) {
                    LongMatch::Help => {
                        if let Some(value) = inline {
                            return Err(Usage::top(ignored_value("help", value)));
                        }
                        return Err(Usage::help(""));
                    }
                    LongMatch::Known(known) => {
                        if let Some(value) = inline {
                            return Err(Usage::top(ignored_value(known.name, value)));
                        }
                        cli.protocol = known.name == "protocol" || cli.protocol;
                        cli.version = known.name == "version" || cli.version;
                        index += 1;
                        continue;
                    }
                    LongMatch::Ambiguous(matches) => {
                        return Err(Usage::top(ambiguous(flag, &matches)));
                    }
                    LongMatch::Unknown => {}
                }
            }
            if looks_like_option(arg) {
                extras.push(arg.to_string());
                index += 1;
                continue;
            }
        }
        let spec = match COMMANDS.iter().find(|s| s.name == arg) {
            Some(spec) => spec,
            None => {
                return Err(Usage::top(format!(
                    "argument command: invalid choice: '{arg}' (choose from serve, snapshot, translate, compare)"
                )))
            }
        };
        let collected = collect(spec, &args[index + 1..])?;
        // Unrecognized arguments from both levels merge, top-level ones first,
        // into the reference's single top-level refusal, and only after the
        // subcommand's own scan and required checks have passed.
        extras.extend(collected.extras);
        if !extras.is_empty() {
            return Err(Usage::top(format!(
                "unrecognized arguments: {}",
                extras.join(" ")
            )));
        }
        cli.command = Some(build_command(spec, collected.values)?);
        return Ok(cli);
    }
    if !extras.is_empty() {
        return Err(Usage::top(format!(
            "unrecognized arguments: {}",
            extras.join(" ")
        )));
    }
    Ok(cli)
}

struct Collected {
    values: std::collections::HashMap<&'static str, String>,
    extras: Vec<String>,
}

/// One subcommand's flags, collected with argparse's shape and orderings:
/// `--flag value` or `--flag=value`, later occurrence wins, scan-time errors
/// (missing value, bad int) fire immediately, unknown options and every
/// positional ride back as extras for the merged top-level unrecognized
/// refusal - an unknown option never consumes a value, and after `--` the
/// terminator itself and everything following are positionals.
fn collect(spec: &CommandSpec, args: &[String]) -> Result<Collected, Usage> {
    let mut values: std::collections::HashMap<&'static str, String> =
        std::collections::HashMap::new();
    let mut extras: Vec<String> = Vec::new();
    let mut positional_only = false;
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        if !positional_only {
            if arg == "-h" {
                return Err(Usage::help(spec.name));
            }
            if arg == "--" {
                // The terminator itself rides with the positionals it creates
                // (the reference renders "unrecognized arguments: -- extra").
                positional_only = true;
                extras.push(arg.to_string());
                index += 1;
                continue;
            }
            if let Some(stripped) = arg.strip_prefix("--") {
                let (flag, inline) = match stripped.split_once('=') {
                    Some((name, value)) => (name, Some(value)),
                    None => (stripped, None),
                };
                match match_long(flag, spec.specs) {
                    LongMatch::Help => {
                        if let Some(value) = inline {
                            return Err(Usage::sub(spec.name, ignored_value("help", value)));
                        }
                        return Err(Usage::help(spec.name));
                    }
                    LongMatch::Known(known) => {
                        let value = match inline {
                            Some(value) => value.to_string(),
                            None => match args.get(index + 1) {
                                // A following option-looking token is not a value:
                                // the flag is left hungry, exactly as argparse
                                // leaves it.
                                Some(next) if !looks_like_option(next) => {
                                    index += 1;
                                    next.clone()
                                }
                                _ => {
                                    return Err(Usage::sub(
                                        spec.name,
                                        format!("argument --{}: expected one argument", known.name),
                                    ))
                                }
                            },
                        };
                        if known.is_int {
                            parse_int(&format!("--{}", known.name), &value)
                                .map_err(|Usage(message)| Usage::sub(spec.name, message))?;
                        }
                        values.insert(known.name, value);
                        index += 1;
                        continue;
                    }
                    LongMatch::Ambiguous(matches) => {
                        return Err(Usage::sub(spec.name, ambiguous(flag, &matches)));
                    }
                    LongMatch::Unknown => {}
                }
            }
            if looks_like_option(arg) {
                extras.push(arg.to_string());
                index += 1;
                continue;
            }
        }
        // No subcommand accepts positionals, so a positional token - a
        // negative number or a bare `-` included - is an extra.
        extras.push(arg.to_string());
        index += 1;
    }
    // The subcommand's own required check comes before any extras refusal,
    // argparse's ordering, listing flags in declaration order.
    let missing: Vec<&str> = spec
        .required
        .iter()
        .filter(|name| !values.contains_key(*name))
        .map(|name| *name)
        .collect();
    if !missing.is_empty() {
        let listed: Vec<String> = missing.iter().map(|name| format!("--{name}")).collect();
        return Err(Usage::sub(
            spec.name,
            format!(
                "the following arguments are required: {}",
                listed.join(", ")
            ),
        ));
    }
    Ok(Collected { values, extras })
}

fn build_command(
    spec: &CommandSpec,
    mut values: std::collections::HashMap<&'static str, String>,
) -> Result<Command, Usage> {
    let take = |values: &mut std::collections::HashMap<&'static str, String>, name: &str| {
        values.remove(name)
    };
    let epoch = take(&mut values, "epoch")
        .map(|raw| parse_int("--epoch", &raw))
        .transpose()
        .map_err(|Usage(message)| Usage::sub(spec.name, message))?;
    Ok(match spec.name {
        "serve" => Command::Serve {
            hub: take(&mut values, "hub").unwrap(),
            token_file: take(&mut values, "token-file").unwrap(),
            fleet_id: take(&mut values, "fleet-id").unwrap_or_else(|| DEFAULT_FLEET_ID.to_string()),
            epoch,
            interval_ms: take(&mut values, "interval-ms")
                .map(|raw| parse_int("--interval-ms", &raw))
                .transpose()
                .map_err(|Usage(message)| Usage::sub(spec.name, message))?
                .unwrap_or(DEFAULT_INTERVAL_MS),
        },
        "snapshot" => Command::Snapshot {
            hub: take(&mut values, "hub").unwrap(),
            token_file: take(&mut values, "token-file").unwrap(),
            fleet_id: take(&mut values, "fleet-id").unwrap_or_else(|| DEFAULT_FLEET_ID.to_string()),
            epoch,
        },
        "translate" => Command::Translate {
            fleet_id: take(&mut values, "fleet-id").unwrap_or_else(|| DEFAULT_FLEET_ID.to_string()),
            epoch,
        },
        "compare" => Command::Compare {
            hub: take(&mut values, "hub"),
            token_file: take(&mut values, "token-file"),
            fleet_id: take(&mut values, "fleet-id").unwrap_or_else(|| DEFAULT_FLEET_ID.to_string()),
            feed: take(&mut values, "feed"),
            home: take(&mut values, "home"),
            crew_state: take(&mut values, "crew-state"),
        },
        _ => unreachable!("parse only routes known commands here"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_every_command_with_defaults_and_values() {
        let cli = parse(&args(&[
            "serve",
            "--hub",
            "http://h:1",
            "--token-file",
            "/t",
        ]))
        .unwrap();
        match cli.command.unwrap() {
            Command::Serve {
                hub,
                token_file,
                fleet_id,
                epoch,
                interval_ms,
            } => {
                assert_eq!(hub, "http://h:1");
                assert_eq!(token_file, "/t");
                assert_eq!(fleet_id, "firstmate");
                assert_eq!(epoch, None);
                assert_eq!(interval_ms, 500);
            }
            other => panic!("wrong command {other:?}"),
        }
        let cli = parse(&args(&[
            "serve",
            "--hub=http://h",
            "--token-file",
            "/t",
            "--fleet-id",
            "f2",
            "--epoch",
            "7",
            "--interval-ms",
            "100",
            "--interval-ms",
            "200",
        ]))
        .unwrap();
        match cli.command.unwrap() {
            Command::Serve {
                fleet_id,
                epoch,
                interval_ms,
                ..
            } => {
                assert_eq!(fleet_id, "f2");
                assert_eq!(epoch, Some(7));
                assert_eq!(interval_ms, 200); // last wins, like argparse
            }
            other => panic!("wrong command {other:?}"),
        }
        let cli = parse(&args(&["--protocol", "translate"])).unwrap();
        assert!(cli.protocol && !cli.version);
        let cli = parse(&args(&["--version"])).unwrap();
        assert!(cli.version && cli.command.is_none());
        let cli = parse(&args(&["compare", "--feed", "/feed"])).unwrap();
        match cli.command.unwrap() {
            Command::Compare { feed, hub, .. } => {
                assert_eq!(feed.as_deref(), Some("/feed"));
                assert_eq!(hub, None);
            }
            other => panic!("wrong command {other:?}"),
        }
    }

    #[test]
    fn usage_errors_are_argparse_shaped() {
        assert!(parse(&args(&[])).unwrap().command.is_none());
        assert!(parse(&args(&["serve"])).is_err());
        assert!(parse(&args(&["serve", "--hub", "http://h"])).is_err());
        assert!(parse(&args(&["wat"])).is_err());
        assert!(parse(&args(&[
            "serve",
            "--hub",
            "h",
            "--token-file",
            "t",
            "extra"
        ]))
        .is_err());
        assert!(parse(&args(&[
            "serve",
            "--hub",
            "h",
            "--token-file",
            "t",
            "--nonsense"
        ]))
        .is_err());
        assert!(parse(&args(&["translate", "--epoch", "7.5"])).is_err());
        assert!(parse(&args(&["translate", "--epoch"])).is_err());
        // Global flags are only accepted before the subcommand.
        assert!(parse(&args(&[
            "serve",
            "--hub",
            "h",
            "--token-file",
            "t",
            "--protocol"
        ]))
        .is_err());
        // Help is surfaced as a Usage whose payload names the help text.
        assert_eq!(parse(&args(&["-h"])).unwrap_err().is_help(), Some(""));
        assert_eq!(
            parse(&args(&["compare", "--help"])).unwrap_err().is_help(),
            Some("compare")
        );
    }

    #[test]
    fn error_orderings_match_argparse() {
        // A scan-time bad int beats the missing-required check.
        let error = parse(&args(&["serve", "--epoch", "abc"])).unwrap_err();
        assert!(error.0.contains("invalid int value: 'abc'"), "{}", error.0);
        // A hungry option beats it too.
        let error = parse(&args(&["serve", "--hub"])).unwrap_err();
        assert!(
            error.0.contains("argument --hub: expected one argument"),
            "{}",
            error.0
        );
        // Required-missing beats unrecognized, and lists both in order.
        let error = parse(&args(&["serve", "--unknown", "1"])).unwrap_err();
        assert!(
            error
                .0
                .contains("the following arguments are required: --hub, --token-file"),
            "{}",
            error.0
        );
        // Unrecognized fires only once everything required is present, with
        // the top-level usage and prog.
        let error = parse(&args(&[
            "serve",
            "--hub",
            "h",
            "--token-file",
            "t",
            "--unknown",
            "1",
        ]))
        .unwrap_err();
        assert!(
            error.0.starts_with("usage: fm-stream-bridge.py [-h]"),
            "{}",
            error.0
        );
        assert!(
            error.0.ends_with("unrecognized arguments: --unknown 1"),
            "{}",
            error.0
        );
        // An option-looking token is not eaten as a value.
        let error = parse(&args(&["translate", "--epoch", "--fleet-id", "f"])).unwrap_err();
        assert!(
            error.0.contains("argument --epoch: expected one argument"),
            "{}",
            error.0
        );
        // An unknown option's following positional is its own extra, and a
        // later known flag still parses.
        let error = parse(&args(&["translate", "--nonsense", "7", "--epoch", "8"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: --nonsense 7"),
            "{}",
            error.0
        );
        // But a negative number is a value.
        let cli = parse(&args(&["translate", "--epoch", "-5", "--fleet-id", "f"])).unwrap();
        assert!(matches!(
            cli.command,
            Some(Command::Translate {
                epoch: Some(-5),
                ..
            })
        ));
        // Invalid choice names the full valid set without quotes, exactly
        // as this Python version renders it.
        let error = parse(&args(&["bogus"])).unwrap_err();
        assert!(
            error
                .0
                .ends_with("argument command: invalid choice: 'bogus' (choose from serve, snapshot, translate, compare)"),
            "{}",
            error.0
        );
    }

    #[test]
    fn unknown_options_never_steal_values_or_positionals() {
        // An unknown option is held, but the next non-option token still
        // fills the command, and the invalid choice fires before any
        // unrecognized-arguments refusal.
        let error = parse(&args(&["--nonsense", "1", "translate"])).unwrap_err();
        assert!(error.0.ends_with("argument command: invalid choice: '1' (choose from serve, snapshot, translate, compare)"), "{}", error.0);
        let error = parse(&args(&["--hub", "X", "translate"])).unwrap_err();
        assert!(error.0.ends_with("argument command: invalid choice: 'X' (choose from serve, snapshot, translate, compare)"), "{}", error.0);
        let error = parse(&args(&["-x", "translate"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: -x"),
            "{}",
            error.0
        );
        // A valid command after a held option runs, and only the held token
        // is refused.
        let error = parse(&args(&["--nonsense", "translate"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: --nonsense"),
            "{}",
            error.0
        );
        // The subcommand's own errors fire before the merged refusal.
        let error = parse(&args(&["--nonsense", "serve"])).unwrap_err();
        assert!(
            error
                .0
                .contains("the following arguments are required: --hub, --token-file"),
            "{}",
            error.0
        );
        // Negative numbers are positionals, not options, at both levels.
        let error = parse(&args(&["-5", "translate"])).unwrap_err();
        assert!(error.0.ends_with("argument command: invalid choice: '-5' (choose from serve, snapshot, translate, compare)"), "{}", error.0);
        let error = parse(&args(&["translate", "-5"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: -5"),
            "{}",
            error.0
        );
    }

    #[test]
    fn the_option_terminator_makes_positionals() {
        // After `--` everything is a positional, even option spellings.
        let error = parse(&args(&["--", "value"])).unwrap_err();
        assert!(error.0.ends_with("argument command: invalid choice: 'value' (choose from serve, snapshot, translate, compare)"), "{}", error.0);
        let error = parse(&args(&["--", "--protocol"])).unwrap_err();
        assert!(error.0.ends_with("argument command: invalid choice: '--protocol' (choose from serve, snapshot, translate, compare)"), "{}", error.0);
        let cli = parse(&args(&["--protocol", "--", "translate"])).unwrap();
        assert!(cli.protocol);
        assert!(matches!(cli.command, Some(Command::Translate { .. })));
        // At the sub level the terminator itself rides with the positionals
        // it creates, and no flag after it is read as a flag.
        let error = parse(&args(&["translate", "--", "extra"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: -- extra"),
            "{}",
            error.0
        );
        let error = parse(&args(&["translate", "--", "--epoch", "7"])).unwrap_err();
        assert!(
            error.0.ends_with("unrecognized arguments: -- --epoch 7"),
            "{}",
            error.0
        );
        // A lone terminator selects nothing: the top-level help is the
        // refusal, as when no command is given at all.
        let cli = parse(&args(&["--"])).unwrap();
        assert!(cli.command.is_none());
    }

    #[test]
    fn int_coercion_tolerates_whitespace_signs_and_separators_like_python() {
        let cli = parse(&args(&["translate", "--epoch", " +1_007 "])).unwrap();
        match cli.command.unwrap() {
            Command::Translate { epoch, .. } => assert_eq!(epoch, Some(1007)),
            other => panic!("wrong command {other:?}"),
        }
        assert!(parse(&args(&["translate", "--epoch", "1__007"])).is_err());
    }

    #[test]
    fn unique_long_option_prefixes_match_argparse() {
        let cli = parse(&args(&["--prot", "translate", "--fleet", "f", "--epo=7"])).unwrap();
        assert!(cli.protocol);
        assert!(matches!(
            cli.command,
            Some(Command::Translate {
                fleet_id,
                epoch: Some(7),
            }) if fleet_id == "f"
        ));
        let error = parse(&args(&["compare", "--h", "x"])).unwrap_err();
        assert!(error
            .0
            .ends_with("ambiguous option: --h could match --help, --hub, --home"));
    }

    #[test]
    fn usage_blocks_are_the_heads_of_the_help_texts() {
        assert!(usage_for(None).starts_with("usage: fm-stream-bridge.py [-h]"));
        assert!(usage_for(Some("serve")).starts_with("usage: fm-stream-bridge.py serve"));
        assert!(!usage_for(Some("serve")).contains("\n\n"));
    }
}
