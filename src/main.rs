//! hecate-greetd: a greetd greeter that is hecate's own lock screen.

mod export;
mod greeter;
mod sessions;
mod sys;

use std::process::ExitCode;

const USAGE: &str = "\
hecate-greetd: greetd greeter for hecate, showing the shell's lock screen

Usage:
  hecate-greetd session [-- <hecate args>]   greetd's default_session command (as the greeter)
  hecate-greetd ui                           the login screen, autostarted by the greeter's hecate
  hecate-greetd sync [--json]                share your look with the login screen (your shell runs it)
  hecate-greetd preview                      show the login screen with your look, in your session
  hecate-greetd users | sessions             print who and what the login screen offers, as JSON
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("session") => {
            let rest = match args.iter().position(|a| a == "--") {
                Some(i) => args[i + 1..].to_vec(),
                None => Vec::new(),
            };
            greeter::session(&rest)
        }
        Some("ui") => greeter::ui(),
        Some("sync") => export::sync().map(|status| {
            if args.iter().any(|a| a == "--json") {
                println!("{status}");
            } else if status["shared"] == true {
                println!(
                    "synced {} for the login screen: {} files, displays {}",
                    status["user"].as_str().unwrap_or("?"),
                    status["files"],
                    status["outputs"]
                );
            } else {
                println!("not shared (greeter.share is off in the shell config); export cleared");
            }
        }),
        Some("preview") => greeter::preview(),
        Some("users") => serde_json::to_string_pretty(&sessions::users())
            .map(|s| println!("{s}"))
            .map_err(std::io::Error::other),
        Some("sessions") => serde_json::to_string_pretty(&sessions::sessions())
            .map(|s| println!("{s}"))
            .map_err(std::io::Error::other),
        Some("-h" | "--help" | "help") => {
            print!("{USAGE}");
            Ok(())
        }
        Some("-V" | "--version") => {
            println!("hecate-greetd {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("hecate-greetd: {e}");
            ExitCode::FAILURE
        }
    }
}
