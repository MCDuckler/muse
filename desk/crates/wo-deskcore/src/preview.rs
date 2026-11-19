//! The browser's preview (rekordbox's: a click on a record's waveform in the Preview
//! column plays it from there): on the engine's spare deck D, in the headphones only, so
//! the room never hears it; with no headphones, out loud only while both decks are still.
//! A second click on it, or another record's, stops it.
use std::thread;

use wo_engine::{Channels, DeckId, Gains};

use crate::records::{Audio, Record};
use crate::{Desk, RATE};

/// Deck D: the spare the sounds also use (they keep to deck C while it plays here).
const PREVIEW: usize = 3;

#[derive(Default)]
pub(crate) struct Preview {
    /// The record previewed, and how long it is (seconds).
    pub(crate) on: Option<(i64, f64)>,
    /// The decoding (its source given back when done, kept while the deck plays it).
    loader: Option<thread::JoinHandle<wo_engine::Source>>,
}

/// What a preview can be: in the headphones, out loud (the decks still), or not now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewWay {
    Headphones,
    Room,
    NotNow,
}

impl Desk {
    /// Where a preview would play now.
    pub fn preview_way(&self) -> PreviewWay {
        if self.headphones() {
            PreviewWay::Headphones
        } else if (0..2).all(|d| !self.engine.deck(DeckId::new(d).unwrap()).read().playing) {
            PreviewWay::Room
        } else {
            PreviewWay::NotNow
        }
    }

    /// The record previewed and where it is in it now (0..1).
    pub fn previewing(&self) -> Option<(i64, f64)> {
        let (id, len) = self.preview.on?;
        let st = self.engine.deck(DeckId::new(PREVIEW).unwrap()).read();
        if !st.playing {
            return None;
        }
        // (the record's own length: the decoded part runs behind at first)
        let len = if len > 0.0 { len } else { st.length.max(1e-3) };
        Some((id, (st.heard / len).clamp(0.0, 1.0)))
    }

    /// `r` previewed from `at` (0..1 of it); the same again stops it. False where it cannot
    /// be now (no headphones and a deck playing, or nothing to play).
    pub fn play_preview(&mut self, r: &Record, at: f64) -> bool {
        if self.preview.on.is_some_and(|(id, _)| id == r.id) && self.previewing().is_some() {
            self.stop_preview();
            return true;
        }
        let way = self.preview_way();
        if way == PreviewWay::NotNow || !r.playable() {
            return false;
        }
        let path = match &r.audio {
            Audio::Usb { path, .. } => Some((path.clone(), true)),
            Audio::File { path, .. } => Some((path.clone(), false)),
            Audio::House { id } => self.house.as_ref().and_then(|h| h.audio(*id).ok()).map(|p| (p, false)),
            _ => None,
        };
        let Some((path, rekordbox)) = path else { return false };
        let Ok(mut source) = self.engine.new_source(Channels::Stereo, RATE as i64 * r.seconds.max(60) as i64) else { return false };
        let deck = self.engine.deck(DeckId::new(PREVIEW).unwrap());
        deck.play(false);
        deck.set_source(0, &source);
        deck.set_gains(0, Gains::FULL, 0.0);
        deck.set_keylock(false);
        deck.set_rate(1.0);
        match way {
            PreviewWay::Headphones => {
                deck.set_level(0.0, 0.0);
                deck.set_cue(1.0, 0.0);
            }
            _ => {
                deck.set_cue(0.0, 0.0);
                deck.set_level(0.8, 0.0);
            }
        }
        deck.seek(at.clamp(0.0, 0.98) * r.seconds as f64);
        deck.play(true);
        self.fx.d_lent = true;
        // decoded on a worker into the source as the deck plays it
        let old = self.preview.loader.take();
        let loader = thread::spawn(move || {
            drop(old.map(|h| h.join()));
            let r = if rekordbox { wo_decode::decode_as_rekordbox(&path, RATE, &mut source) } else { wo_decode::decode(&path, RATE, &mut source) };
            if let Err(e) = r {
                eprintln!("preview {}: {e}", path.display());
            }
            source.finish();
            source
        });
        self.preview.on = Some((r.id, r.seconds as f64));
        self.preview.loader = Some(loader);
        self.changes += 1;
        true
    }

    pub fn stop_preview(&mut self) {
        let deck = self.engine.deck(DeckId::new(PREVIEW).unwrap());
        deck.play(false);
        deck.set_cue(0.0, 0.0);
        self.preview.on = None;
        // the old source let go of once its decoding is done (off this thread)
        if let Some(h) = self.preview.loader.take() {
            thread::spawn(move || drop(h.join()));
        }
        self.fx.d_lent = false;
        self.changes += 1;
    }
}
