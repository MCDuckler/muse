//! rekordbox's decks, live, from rkbx_link (grufkork, GPL-3): it reads rekordbox's memory
//! and sends each deck's record, position, tempo, beat and phrase over OSC/UDP. WetOwl runs
//! it as a process of its own and only listens (plan: ~/.claude/plans/wetowl-rekordbox-windows.md).
//!
//! - [`osc`]: the wire format.
//! - [`feed`]: the decks as it tells them ([`Feed`] → [`View`]): playing, position carried
//!   on between messages, the master steadied, the deck to follow.
//! - [`listen`]: a UDP listener on a thread, optionally recording a capture.
//! - [`capture`]: recorded feeds as text, and replaying them (tests without rekordbox).
//! - [`runner`]: rkbx_link found, set up, run and watched for the user.
//!
//! rkbx_link's `config` needs its OSC on, per-deck time and phrase, and the beat
//! subdivisions; [`runner::configure`] sets them up.
pub mod capture;
pub mod feed;
pub mod listen;
pub mod osc;
pub mod runner;

pub use feed::{DeckView, Feed, PhraseKind, View};
pub use listen::Listener;
