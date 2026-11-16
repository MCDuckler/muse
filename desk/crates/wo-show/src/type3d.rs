//! The 3D type's say (v1: state/show/show_type3d.dart's TypeSpec): the hands' words, set in a
//! display face, extruded into solid letters and turned in space to the music. The Desk keeps
//! it in the show document's pool (`pool.type3d`) and sends it on the cue's macros while the
//! scene is on; the stage's wo-type3d bakes and moves the letters.
//!
//!   lines    what it says — one line at a time, the next on the change; `{title}` and
//!            `{artist}` are the record's own;
//!   font     the face;
//!   motions  how it turns — a phrase picks one;
//!   looks    what it is made of — a phrase picks one;
//!   deforms  how the music bends it — a phrase picks two;
//!   turn     how one line becomes the next;
//!   colour   the record's palette, or a fixed one;
//!   knobs    size, depth, bevel, speed, the beat's push, the glow, the bend (1 is as drawn).
use serde_json::{Map, Value, json};

macro_rules! named {
    ($(#[$m:meta])* $name:ident { $($v:ident = $s:literal),* $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name { $($v),* }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$v),*];
            pub fn name(self) -> &'static str {
                match self { $($name::$v => $s),* }
            }
            pub fn by_name(s: &str) -> Option<$name> {
                Self::ALL.iter().copied().find(|x| x.name() == s)
            }
            /// Its place in the list (the shader's numbering for the looks).
            pub fn index(self) -> usize {
                self as usize
            }
        }
    };
}

named!(
    /// How the letters move.
    TypeMotion { Spin = "spin", Tumble = "tumble", Swing = "swing", Flip = "flip", Wave = "wave", Twist = "twist", Orbit = "orbit", Zoom = "zoom", Bounce = "bounce", Drift = "drift", Still = "still" }
);
named!(
    /// What the letters are made of (type3d.frag's uLook, by index).
    TypeLook { Chrome = "chrome", Neon = "neon", Solid = "solid", Outline = "outline", Hologram = "hologram", Iridescent = "iridescent", Glass = "glass", Aurora = "aurora", Pop = "pop", Stripes = "stripes", Mercury = "mercury" }
);
named!(
    /// How the music bends the letters.
    TypeDeform { Inflate = "inflate", Ripple = "ripple", Melt = "melt", Slice = "slice", Shatter = "shatter", Wobble = "wobble", Squash = "squash", Arc = "arc", Stack = "stack", Repeat = "repeat" }
);
named!(
    /// How one line becomes the next.
    TypeTurn { Morph = "morph", Flip = "flip", Glitch = "glitch" }
);
named!(
    /// When the next line comes.
    TypeChange { Beat = "beat", Bar = "bar", TwoBars = "twoBars", Phrase = "phrase", EightBars = "eightBars", Never = "never" }
);
named!(
    /// The colours: the record's palette, or a fixed set.
    TypeColour { Record = "record", Purple = "purple", Sunset = "sunset", Ice = "ice", Gold = "gold", Mono = "mono" }
);
named!(
    /// The faces (v1's names; the files under app/assets/fonts).
    TypeFont { Bebas = "bebas", Orbitron = "orbitron", Bungee = "bungee", Pixel = "pixel", Monoton = "monoton", Rubik = "rubik", Righteous = "righteous", Syne = "syne", Archivo = "archivo", Serif = "serif", Marker = "marker", Courier = "courier" }
);

impl TypeFont {
    pub fn label(self) -> &'static str {
        match self {
            TypeFont::Bebas => "Bebas",
            TypeFont::Orbitron => "Orbitron",
            TypeFont::Bungee => "Bungee",
            TypeFont::Pixel => "Pixel",
            TypeFont::Monoton => "Monoton",
            TypeFont::Rubik => "Rubik Mono",
            TypeFont::Righteous => "Righteous",
            TypeFont::Syne => "Syne",
            TypeFont::Archivo => "Archivo",
            TypeFont::Serif => "Serif",
            TypeFont::Marker => "Marker",
            TypeFont::Courier => "Courier",
        }
    }
}

/// The 3D type's say.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(from = "Value", into = "Value")]
pub struct TypeSpec {
    pub lines: Vec<String>,
    pub font: TypeFont,
    /// Each in its list's order, none twice.
    pub motions: Vec<TypeMotion>,
    pub looks: Vec<TypeLook>,
    /// None is none: the letters as cut.
    pub deforms: Vec<TypeDeform>,
    pub turn: TypeTurn,
    pub colour: TypeColour,
    pub change: TypeChange,
    pub size: f64,
    pub depth: f64,
    pub bevel: f64,
    pub speed: f64,
    pub beat: f64,
    pub glow: f64,
    pub bend: f64,
}

/// The knobs' reach.
pub const KNOB_RANGE: (f64, f64) = (0.0, 3.0);

impl Default for TypeSpec {
    fn default() -> Self {
        TypeSpec {
            lines: vec!["WETOWL".into()],
            font: TypeFont::Bebas,
            motions: vec![TypeMotion::Spin, TypeMotion::Swing, TypeMotion::Flip, TypeMotion::Wave, TypeMotion::Twist],
            looks: vec![TypeLook::Chrome, TypeLook::Neon, TypeLook::Iridescent, TypeLook::Glass],
            deforms: vec![TypeDeform::Inflate, TypeDeform::Ripple, TypeDeform::Slice, TypeDeform::Shatter],
            turn: TypeTurn::Morph,
            colour: TypeColour::Record,
            change: TypeChange::Phrase,
            size: 1.0,
            depth: 1.0,
            bevel: 1.0,
            speed: 1.0,
            beat: 1.0,
            glow: 1.0,
            bend: 1.0,
        }
    }
}

impl TypeSpec {
    /// The line `n`th in turn, with the record's words in it.
    pub fn line_at(&self, n: i64, title: Option<&str>, artist: Option<&str>) -> String {
        let said: Vec<&str> = self.lines.iter().map(|l| l.trim()).filter(|l| !l.is_empty()).collect();
        if said.is_empty() {
            return "WETOWL".into();
        }
        let line = said[n.rem_euclid(said.len() as i64) as usize];
        let out = line.replace("{title}", title.unwrap_or("")).replace("{artist}", artist.unwrap_or(""));
        let out = out.trim();
        if out.is_empty() { "WETOWL".into() } else { out.into() }
    }

    pub fn to_json(&self) -> Value {
        fn names<T: Copy>(v: &[T], all: &[T], name: fn(T) -> &'static str, eq: fn(&T, &T) -> bool) -> Vec<&'static str> {
            all.iter().filter(|a| v.iter().any(|x| eq(x, a))).map(|a| name(*a)).collect()
        }
        json!({
            "lines": self.lines,
            "font": self.font.name(),
            "motions": names(&self.motions, TypeMotion::ALL, TypeMotion::name, PartialEq::eq),
            "looks": names(&self.looks, TypeLook::ALL, TypeLook::name, PartialEq::eq),
            "deforms": names(&self.deforms, TypeDeform::ALL, TypeDeform::name, PartialEq::eq),
            "turn": self.turn.name(),
            "colour": self.colour.name(),
            "change": self.change.name(),
            "size": self.size,
            "depth": self.depth,
            "bevel": self.bevel,
            "speed": self.speed,
            "beat": self.beat,
            "glow": self.glow,
            "bend": self.bend,
        })
    }

    /// Read as v1 reads it: what is missing or not understood is the standard's; a knob
    /// clamped to its reach; a set left empty is the standard's, but for the bends.
    pub fn from_json(j: &Value) -> TypeSpec {
        let s = TypeSpec::default();
        let Some(j) = j.as_object() else { return s };
        let k = |key: &str, rest: f64| j.get(key).and_then(Value::as_f64).map_or(rest, |v| v.clamp(KNOB_RANGE.0, KNOB_RANGE.1));
        fn set<T: Copy>(j: &Map<String, Value>, key: &str, all: &[T], name: fn(T) -> &'static str, rest: &[T], none_is_none: bool) -> Vec<T> {
            let Some(v) = j.get(key).and_then(Value::as_array) else { return rest.to_vec() };
            let got: Vec<T> = all.iter().copied().filter(|x| v.iter().any(|n| n.as_str() == Some(name(*x)))).collect();
            if got.is_empty() && !none_is_none { rest.to_vec() } else { got }
        }
        let one = |key: &str| j.get(key).and_then(Value::as_str).unwrap_or("");
        TypeSpec {
            lines: j.get("lines").and_then(Value::as_array).map_or(s.lines.clone(), |v| v.iter().filter_map(|l| l.as_str().map(str::to_owned)).collect()),
            font: TypeFont::by_name(one("font")).unwrap_or(s.font),
            motions: set(j, "motions", TypeMotion::ALL, TypeMotion::name, &s.motions, false),
            looks: set(j, "looks", TypeLook::ALL, TypeLook::name, &s.looks, false),
            deforms: set(j, "deforms", TypeDeform::ALL, TypeDeform::name, &s.deforms, true),
            turn: TypeTurn::by_name(one("turn")).unwrap_or(s.turn),
            colour: TypeColour::by_name(one("colour")).unwrap_or(s.colour),
            change: TypeChange::by_name(one("change")).unwrap_or(s.change),
            size: k("size", s.size),
            depth: k("depth", s.depth),
            bevel: k("bevel", s.bevel),
            speed: k("speed", s.speed),
            beat: k("beat", s.beat),
            glow: k("glow", s.glow),
            bend: k("bend", s.bend),
        }
    }
}

impl From<Value> for TypeSpec {
    fn from(v: Value) -> Self {
        TypeSpec::from_json(&v)
    }
}

impl From<TypeSpec> for Value {
    fn from(s: TypeSpec) -> Self {
        s.to_json()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_as_v1_reads() {
        let s = TypeSpec::from_json(&json!({"lines": ["HI", "{title} / {artist}"], "font": "pixel", "motions": [], "deforms": [], "size": 9, "looks": ["neon", "nope"]}));
        assert_eq!(s.font, TypeFont::Pixel);
        assert_eq!(s.motions, TypeSpec::default().motions, "an empty set is the standard's");
        assert!(s.deforms.is_empty(), "but no bends is no bends");
        assert_eq!(s.looks, vec![TypeLook::Neon]);
        assert_eq!(s.size, 3.0);
        assert_eq!(s.line_at(3, Some("Song"), Some("Act")), "Song / Act");
        assert_eq!(s.line_at(1, None, None), "/");
        assert_eq!(TypeSpec::from_json(&json!({"lines": ["{title}"]})).line_at(0, None, None), "WETOWL");
        assert_eq!(TypeSpec::from_json(&s.to_json()), s);
        assert_eq!(TypeSpec::from_json(&Value::Null), TypeSpec::default());
    }

    #[test]
    fn the_looks_number_as_the_shader_does() {
        assert_eq!(TypeLook::Glass.index(), 6);
        assert_eq!(TypeLook::Mercury.index(), 10);
    }
}
