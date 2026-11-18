//! rekordbox's decks, live, from rkbx_link (grufkork, GPL-3): it reads rekordbox's memory
//! and sends each deck's record, position, tempo, beat and phrase over OSC/UDP. WetOwl runs
//! it as a process of its own and only listens (plan: ~/.claude/plans/wetowl-rekordbox-windows.md).
//!
//! - [`osc`]: the wire format.
//! - [`feed`]: the decks as it tells them ([`Feed`] → [`View`]): playing, position carried
//!   on between messages, the master steadied, the deck to follow.
//! - [`listen`]: a UDP listener on a thread, optionally recording a capture.
//! - [`capture`]: recorded feeds as text, and replaying them (tests without rekordbox).
//!
//! rkbx_link's `config` needs `osc.enabled true`, `osc.msg.n/time true`,
//! `osc.msg.n/phrase true`, `osc.msg.n/beat/subdiv 1` (and for the bar
//! `osc.msg.master/beat/subdiv 4`); [`CONFIG_LINES`] has them.
pub mod capture;
pub mod feed;
pub mod listen;
pub mod osc;

pub use feed::{DeckView, Feed, PhraseKind, View};
pub use listen::Listener;

/// The rkbx_link `config` lines this crate relies on.
pub const CONFIG_LINES: &[&str] = &[
    "osc.enabled true",
    "osc.destination 127.0.0.1:4460",
    "osc.msg.master/time true",
    "osc.msg.master/phrase true",
    "osc.msg.n/time true",
    "osc.msg.n/phrase true",
    "osc.msg.master/beat/subdiv 4",
    "osc.msg.n/beat/subdiv 1",
];
