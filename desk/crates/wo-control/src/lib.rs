//! DJ controllers for the Desk, the v1 booth's control layer (app/lib/src/state/booth/
//! control) in Rust: the layouts as they were (controllers/*.json), MIDI (midir) and
//! HID (hidapi) read on their own threads, the bytes decoded into named events, and one
//! binding that turns any controller's events into what the booth does.
pub mod binding;
pub mod decode;
pub mod layout;
pub mod manager;

pub use binding::{Action, Binding, Positions};
pub use decode::{Decoder, Event};
pub use layout::{Kind, Layout, Protocol};
pub use manager::{Controller, Manager};
