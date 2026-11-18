//! Just enough OSC 1.0 to read rkbx_link: messages and bundles with int, float,
//! double, string and true/false arguments. Anything else is skipped whole.

/// One OSC argument.
#[derive(Clone, Debug, PartialEq)]
pub enum Arg {
    Int(i32),
    Float(f32),
    Double(f64),
    Str(String),
    Bool(bool),
}

impl Arg {
    /// The argument as a number, whatever its type (strings: none).
    pub fn num(&self) -> Option<f64> {
        match self {
            Arg::Int(i) => Some(*i as f64),
            Arg::Float(f) => Some(*f as f64),
            Arg::Double(d) => Some(*d),
            Arg::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
            Arg::Str(_) => None,
        }
    }

    pub fn text(&self) -> Option<&str> {
        match self {
            Arg::Str(s) => Some(s),
            _ => None,
        }
    }
}

/// One OSC message: an address and its arguments.
#[derive(Clone, Debug, PartialEq)]
pub struct Msg {
    pub addr: String,
    pub args: Vec<Arg>,
}

impl Msg {
    pub fn new(addr: &str, args: Vec<Arg>) -> Msg {
        Msg { addr: addr.to_owned(), args }
    }

    /// The first argument as a number.
    pub fn num(&self) -> Option<f64> {
        self.args.first()?.num()
    }

    /// The first argument as text.
    pub fn text(&self) -> Option<&str> {
        self.args.first()?.text()
    }
}

/// The messages in one UDP packet (a bundle is flattened, its time tag ignored: rkbx_link
/// sends everything "now"). A malformed packet gives what could be read before the fault.
pub fn parse(packet: &[u8]) -> Vec<Msg> {
    let mut out = Vec::new();
    walk(packet, &mut out, 0);
    out
}

fn walk(b: &[u8], out: &mut Vec<Msg>, depth: usize) {
    if depth > 8 {
        return;
    }
    if b.starts_with(b"#bundle\0") {
        let mut i = 16;
        while i + 4 <= b.len() {
            let n = u32::from_be_bytes(b[i..i + 4].try_into().unwrap()) as usize;
            let Some(inner) = b.get(i + 4..i + 4 + n) else { return };
            walk(inner, out, depth + 1);
            i += 4 + n;
        }
        return;
    }
    if let Some(m) = message(b) {
        out.push(m);
    }
}

fn message(b: &[u8]) -> Option<Msg> {
    let (addr, mut i) = string(b, 0)?;
    if !addr.starts_with('/') {
        return None;
    }
    let (tags, j) = string(b, i).unwrap_or((",".into(), i));
    i = j;
    let mut args = Vec::new();
    for t in tags.chars().skip(1) {
        match t {
            'i' => {
                args.push(Arg::Int(i32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?)));
                i += 4;
            }
            'f' => {
                args.push(Arg::Float(f32::from_be_bytes(b.get(i..i + 4)?.try_into().ok()?)));
                i += 4;
            }
            'd' => {
                args.push(Arg::Double(f64::from_be_bytes(b.get(i..i + 8)?.try_into().ok()?)));
                i += 8;
            }
            'h' | 't' => i += 8,
            's' | 'S' => {
                let (s, j) = string(b, i)?;
                args.push(Arg::Str(s));
                i = j;
            }
            'T' => args.push(Arg::Bool(true)),
            'F' => args.push(Arg::Bool(false)),
            'N' | 'I' => {}
            _ => return Some(Msg { addr, args }),
        }
    }
    Some(Msg { addr, args })
}

/// A NUL-terminated, 4-byte padded string at `i`, and where the next field starts.
fn string(b: &[u8], i: usize) -> Option<(String, usize)> {
    let rest = b.get(i..)?;
    let n = rest.iter().position(|&c| c == 0)?;
    let s = String::from_utf8_lossy(&rest[..n]).into_owned();
    Some((s, (i + n + 4) & !3))
}

/// A message as OSC bytes (for tests and for replaying to another listener).
pub fn encode(m: &Msg) -> Vec<u8> {
    fn pad(v: &mut Vec<u8>, s: &[u8]) {
        v.extend_from_slice(s);
        v.push(0);
        while !v.len().is_multiple_of(4) {
            v.push(0);
        }
    }
    let mut v = Vec::new();
    pad(&mut v, m.addr.as_bytes());
    let mut tags = String::from(",");
    for a in &m.args {
        tags.push(match a {
            Arg::Int(_) => 'i',
            Arg::Float(_) => 'f',
            Arg::Double(_) => 'd',
            Arg::Str(_) => 's',
            Arg::Bool(true) => 'T',
            Arg::Bool(false) => 'F',
        });
    }
    pad(&mut v, tags.as_bytes());
    for a in &m.args {
        match a {
            Arg::Int(i) => v.extend_from_slice(&i.to_be_bytes()),
            Arg::Float(f) => v.extend_from_slice(&f.to_be_bytes()),
            Arg::Double(d) => v.extend_from_slice(&d.to_be_bytes()),
            Arg::Str(s) => pad(&mut v, s.as_bytes()),
            Arg::Bool(_) => {}
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let m = Msg::new("/0/track/title", vec![Arg::Str("Cairo FM".into())]);
        assert_eq!(parse(&encode(&m)), vec![m]);
        let m = Msg::new("/master/time", vec![Arg::Float(40.25), Arg::Int(3), Arg::Bool(true)]);
        assert_eq!(parse(&encode(&m)), vec![m]);
    }

    #[test]
    fn bundle_is_flattened() {
        let a = encode(&Msg::new("/0/time", vec![Arg::Float(1.0)]));
        let b = encode(&Msg::new("/1/time", vec![Arg::Float(2.0)]));
        let mut p = b"#bundle\0".to_vec();
        p.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 1]);
        for x in [&a, &b] {
            p.extend_from_slice(&(x.len() as u32).to_be_bytes());
            p.extend_from_slice(x);
        }
        let got = parse(&p);
        assert_eq!(got.len(), 2);
        assert_eq!(got[1].addr, "/1/time");
        assert_eq!(got[1].num(), Some(2.0));
    }

    #[test]
    fn junk_is_harmless() {
        assert!(parse(b"").is_empty());
        assert!(parse(b"garbage").is_empty());
        let mut cut = encode(&Msg::new("/0/time", vec![Arg::Float(1.0)]));
        cut.truncate(cut.len() - 2);
        assert!(parse(&cut).is_empty());
    }
}
