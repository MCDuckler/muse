//! Reading JSON the way v1's `fromJson`s do: a value of the wrong kind is the default, a
//! name not known is the fallback, numbers are clamped where v1 clamps them.
use serde_json::{Map, Value};

pub type Obj = Map<String, Value>;

pub fn num(v: Option<&Value>, or: f64) -> f64 {
    v.and_then(Value::as_f64).unwrap_or(or)
}

pub fn str_or(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).map(str::to_owned)
}

/// `'${v}'` in Dart: a string as it is, a number or a bool written out.
pub fn text(v: Option<&Value>) -> Option<String> {
    match v? {
        Value::String(s) => Some(s.clone()),
        Value::Null => None,
        Value::Number(n) => Some(n.to_string()),
        Value::Bool(b) => Some(b.to_string()),
        other => Some(other.to_string()),
    }
}

pub fn obj(v: Option<&Value>) -> Option<&Obj> {
    v.and_then(Value::as_object)
}

pub fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array).map(|a| a.iter().filter_map(|x| text(Some(x))).collect()).unwrap_or_default()
}

/// A map of numbers (knobs): the entries that are numbers.
pub fn knobs(v: Option<&Value>) -> Vec<(String, f64)> {
    let mut out: Vec<(String, f64)> = obj(v).map(|m| m.iter().filter_map(|(k, v)| v.as_f64().map(|x| (k.clone(), x))).collect()).unwrap_or_default();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub fn knobs_json(k: &[(String, f64)]) -> Value {
    Value::Object(k.iter().map(|(n, v)| (n.clone(), f(*v))).collect())
}

/// A number as v1 writes it (an integer-valued double still a double: `1.0`).
pub fn f(v: f64) -> Value {
    serde_json::Number::from_f64(v).map(Value::Number).unwrap_or(Value::Null)
}

/// An enum by name, or `fallback` for anything else.
pub trait Named: Sized + Copy + 'static {
    const ALL: &'static [Self];
    fn name(self) -> &'static str;
    fn by_name(n: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|v| v.name() == n)
    }
    fn of(v: Option<&Value>, fallback: Self) -> Self {
        v.and_then(Value::as_str).and_then(Self::by_name).unwrap_or(fallback)
    }
    fn index(self) -> usize {
        Self::ALL.iter().position(|v| v.name() == self.name()).unwrap()
    }
}

/// Declares a `Named` enum: `named!(Mask { None = "none", Keyhole = "keyhole" })`.
#[macro_export]
macro_rules! named {
    ($(#[$m:meta])* $vis:vis enum $name:ident { $($(#[$vm:meta])* $v:ident = $s:literal),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        $vis enum $name { $($(#[$vm])* $v),+ }
        impl $crate::json::Named for $name {
            const ALL: &'static [Self] = &[$(Self::$v),+];
            fn name(self) -> &'static str { match self { $(Self::$v => $s),+ } }
        }
    };
}
