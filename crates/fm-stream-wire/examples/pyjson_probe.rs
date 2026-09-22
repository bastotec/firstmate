use std::io::{self, BufRead, Write};

fn main() {
    let stdin = io::stdin();
    let mut out = io::stdout();
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        match fm_stream_wire::python_json::python_json_error(&line) {
            None => writeln!(out, "OK").unwrap(),
            Some(message) => writeln!(out, "{message}").unwrap(),
        }
    }
}
