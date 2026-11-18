//! A recorded feed: one message per line, `<seconds> <address> <args…>`, each argument
//! `i:<int>`, `f:<float>`, `d:<double>`, `s:<text>` (space, `%` and line breaks
//! percent-escaped), `T` or `F`. Floats are written so they read back bit-exact (the
//! master is found by equal times). Lines starting with `#` are notes.
//!
//! So the follow mode can be tested without rekordbox: on Linux, in CI, from a gig's log.
use std::io::{self, BufRead, Write};

use crate::feed::Feed;
use crate::osc::{Arg, Msg};

/// One message and when it was heard.
#[derive(Clone, Debug, PartialEq)]
pub struct Heard {
    pub t: f64,
    pub msg: Msg,
}

fn escape(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '%' => o.push_str("%25"),
            ' ' => o.push_str("%20"),
            '\n' => o.push_str("%0A"),
            '\r' => o.push_str("%0D"),
            '\t' => o.push_str("%09"),
            c => o.push(c),
        }
    }
    o
}

fn unescape(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 3 <= b.len() && b[i + 1].is_ascii_hexdigit() && b[i + 2].is_ascii_hexdigit() {
            out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// One line for `h`.
pub fn line(h: &Heard) -> String {
    let mut s = format!("{:.4} {}", h.t, escape(&h.msg.addr));
    for a in &h.msg.args {
        s.push(' ');
        match a {
            Arg::Int(i) => s.push_str(&format!("i:{i}")),
            // `{}` on f32/f64 is the shortest text that reads back to the same bits
            Arg::Float(f) => s.push_str(&format!("f:{f}")),
            Arg::Double(d) => s.push_str(&format!("d:{d}")),
            Arg::Str(t) => s.push_str(&format!("s:{}", escape(t))),
            Arg::Bool(true) => s.push('T'),
            Arg::Bool(false) => s.push('F'),
        }
    }
    s
}

/// A line read back (`None` for notes, blanks and lines it cannot read).
pub fn parse_line(l: &str) -> Option<Heard> {
    let l = l.trim_end();
    if l.is_empty() || l.starts_with('#') {
        return None;
    }
    let mut it = l.split(' ');
    let t: f64 = it.next()?.parse().ok()?;
    let addr = unescape(it.next()?);
    let mut args = Vec::new();
    for a in it {
        args.push(match a {
            "T" => Arg::Bool(true),
            "F" => Arg::Bool(false),
            _ => match a.split_once(':')? {
                ("i", v) => Arg::Int(v.parse().ok()?),
                ("f", v) => Arg::Float(v.parse().ok()?),
                ("d", v) => Arg::Double(v.parse().ok()?),
                ("s", v) => Arg::Str(unescape(v)),
                _ => return None,
            },
        });
    }
    Some(Heard { t, msg: Msg { addr, args } })
}

/// Everything in a capture, in order.
pub fn read(r: impl BufRead) -> io::Result<Vec<Heard>> {
    let mut out = Vec::new();
    for l in r.lines() {
        if let Some(h) = parse_line(&l?) {
            out.push(h);
        }
    }
    Ok(out)
}

pub fn write(w: &mut impl Write, heard: &[Heard]) -> io::Result<()> {
    for h in heard {
        writeln!(w, "{}", line(h))?;
    }
    Ok(())
}

/// Plays a capture into a [`Feed`] on the capture's own clock.
pub struct Replay {
    heard: Vec<Heard>,
    next: usize,
    pub feed: Feed,
}

impl Replay {
    pub fn new(heard: Vec<Heard>) -> Replay {
        Replay { heard, next: 0, feed: Feed::new() }
    }

    /// Feed everything heard up to `t`.
    pub fn until(&mut self, t: f64) -> &Feed {
        while let Some(h) = self.heard.get(self.next).filter(|h| h.t <= t) {
            self.feed.apply(&h.msg, h.t);
            self.next += 1;
        }
        &self.feed
    }

    /// When the capture ends.
    pub fn end(&self) -> f64 {
        self.heard.last().map_or(0.0, |h| h.t)
    }

    pub fn done(&self) -> bool {
        self.next >= self.heard.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_round_trip() {
        let h = Heard {
            t: 12.3456,
            msg: Msg::new(
                "/1/track/title",
                vec![Arg::Str("Whatcha Say (Hide and Seek-Imogen 100% Mix)\nx".into()), Arg::Float(0.1), Arg::Int(-3), Arg::Double(1.0 / 3.0), Arg::Bool(false)],
            ),
        };
        assert_eq!(parse_line(&line(&h)), Some(h));
        let f = Heard { t: 1.0, msg: Msg::new("/0/time", vec![Arg::Float(40.151_4)]) };
        let back = parse_line(&line(&f)).unwrap();
        assert_eq!(back.msg.args[0], Arg::Float(40.151_4));
        assert_eq!(parse_line("# a note"), None);
        assert_eq!(parse_line("1.0 /0/time q:1"), None);
    }
}
