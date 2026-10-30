//! The booth's logic, toolkit- and engine-free: a record's beat grid, and what a deck
//! does when a hand moves it (CUE, pads, loops, beat jump, pitch, nudge, brake), ported
//! from the v1 booth (app/lib/src/state/booth). The Auto DJ comes here next.
pub mod grid;
pub mod hands;

pub use grid::Grid;
pub use hands::{Hands, NUDGE, Pad, PadKind, RANGES, Transport};
