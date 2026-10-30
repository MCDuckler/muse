//! The booth's logic, toolkit- and engine-free: a record's beat grid, and what a deck
//! does when a hand moves it (CUE, pads, loops, beat jump, pitch, nudge, brake), ported
//! from the v1 booth (app/lib/src/state/booth), and how the booth mixes on its own.
pub mod grid;
pub mod hands;
pub mod mix;

pub use grid::Grid;
pub use hands::{Hands, NUDGE, Pad, PadKind, RANGES, Transport};
pub use mix::{Moves, Style, Timing, Transition};
