//! The show, without a GPU (plan: ~/.claude/plans/wetowl-stage-rust.md §2.2, P1): what the
//! stage draws (the rig), what the director picks from (the combinations, the plan), and the
//! rules it picks by — ported from v1's Dart (app/lib/src/state/show), whose tests are the
//! spec. Everything here reads and writes v1's JSON as v1 does, so show.json, the sets and the
//! favourites stay shared while both exist.
pub mod combos;
pub mod json;
pub mod plan;
pub mod rig;

pub use combos::{Combo, Fx, Mask, Mix};
pub use rig::{Figure, Ground, Look, SceneMeta, ShowRig};
