// The package whose functions are taken as values from main.
package tools
import std.io

pub fn shout(message: string) -> string { return "{message}!" }
pub fn twice(value: int) -> int { return value * 2 }
pub fn log_line(line: string) { io.println("log {line}") }
fn hidden(value: int) -> int { return value }
pub fn pick<T>(move value: T) -> T { return move value }
