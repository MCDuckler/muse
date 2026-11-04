//! A record's parts on its deck — the v1 booth's parts pads (console_deck.dart `_parts`,
//! mixer.dart `StemLevels`): the WHOLE record, its DRUMS, the MUSIC without them, the
//! record with NO VOX, the VOCALS alone.
//!
//! The record stays in the deck's source slot 0. Its stems — drums, bass and the rest,
//! voice: one six-channel Opus file from the house (wo_house::House::stems) — go in slot 1
//! on the same timeline, and a part crossfades between the two. The stems line up with the
//! record within a couple of samples (wo-decode's stems test), so changing parts changes
//! what is heard, never where.
//!
//! The stems are asked for when a record goes on a deck. The house answers 202 while a
//! computer in the pool makes them (asking queues them); the Desk asks again every
//! [`RETRY`] while the record is on. A part pressed before they are here is kept, and
//! applied the moment they are.
use std::thread;
use std::time::{Duration, Instant};

use wo_engine::{Channels, DeckId, Gains, Source};

use crate::library::Done;
use crate::records::{Audio, Record};
use crate::{Desk, RATE};

/// How often a record whose stems are being made is asked about again.
pub const RETRY: Duration = Duration::from_secs(10);

/// How long a part takes to change (v1's hand press: 120 ms).
pub const RAMP: f64 = 0.12;

pub use wo_booth::Part;

/// Where a deck's stems are.
#[derive(Clone, Debug, Default, PartialEq)]
pub enum Stems {
    /// Not a record stems are had for (a synthesised one, a file with no stems kept).
    #[default]
    None,
    /// Asked for: the house's answer, or the file decoding.
    Asking,
    /// Being made by the pool; asked again in a while.
    Making,
    /// Not for this record (too long to take apart).
    Never,
    /// On the deck: any part plays at once.
    Ready,
    /// Could not be had, in words.
    Failed(String),
}

impl Stems {
    pub fn ready(&self) -> bool {
        matches!(self, Stems::Ready)
    }
}

/// What the stems' worker hands back.
pub(crate) enum Got {
    Ready(Source),
    Making,
    Never,
    None,
    Failed(String),
}

/// One deck's stems: where they are, the part asked for.
#[derive(Default)]
pub(crate) struct DeckStems {
    pub state: Stems,
    pub source: Option<Source>,
    pub part: Part,
    pub retry_at: Option<Instant>,
    /// A transition's own levels for the stems while it runs (None: the part's).
    pub mix: Option<wo_booth::Levels>,
}

impl Desk {
    /// The part asked for on deck `d`: at once where its stems are on the deck, else as
    /// soon as they are (asked for again now if they were being made).
    pub fn set_part(&mut self, d: usize, part: Part) {
        let s = &mut self.slots[d].stems;
        s.part = part;
        if s.state == Stems::Making && part != Part::Whole {
            s.retry_at = None;
            self.ask_stems(d, false);
        }
        self.apply_part(d, RAMP);
    }

    /// The part playing on deck `d` and where its stems are.
    pub fn part(&self, d: usize) -> (Part, Stems) {
        let s = &self.slots[d].stems;
        (s.part, s.state.clone())
    }

    /// A new record on deck `d`: the last one's stems off it, the whole record on, and its
    /// own stems asked for.
    pub(crate) fn reset_stems(&mut self, d: usize) {
        let deck = self.engine.deck(DeckId::new(d).unwrap());
        deck.clear_source(1);
        deck.set_gains(1, Gains { gain: 0.0, ..Gains::FULL }, 0.0);
        self.slots[d].stems = DeckStems::default();
        self.ask_stems(d, false);
    }

    /// Asks for deck `d`'s stems on a worker thread, decoding them there when they come.
    /// `soon`: ahead of time (the house queues it behind records wanted now).
    pub(crate) fn ask_stems(&mut self, d: usize, soon: bool) {
        let record: Record = self.slots[d].record.clone();
        let local = match &record.audio {
            Audio::House { .. } => false,
            Audio::File { .. } if record.id > 0 => true,
            _ => {
                self.slots[d].stems.state = Stems::None;
                return;
            }
        };
        self.slots[d].stems.state = Stems::Asking;
        let (engine, house, tx, turn) = (self.engine.clone(), self.house.clone(), self.done_tx.clone(), self.load_gen[d]);
        thread::spawn(move || {
            let id = record.id;
            let found = if local {
                // the WetOwl app's own, beside the record it fetched
                wo_house::app_folder()
                    .map(|a| a.join("stems").join(wo_house::stems_file(id)))
                    .filter(|p| p.exists())
                    .map_or(Ok(wo_house::Stems::Never), |p| Ok(wo_house::Stems::Ready(p)))
                    .map(|s| if s == wo_house::Stems::Never { None } else { Some(s) })
            } else {
                match house {
                    Some(h) => h.stems(id, soon).map(Some).map_err(|e| e.to_string()),
                    None => Err("not signed in to the house".into()),
                }
            };
            let got = match found {
                Ok(None) => Got::None,
                Ok(Some(wo_house::Stems::Never)) => Got::Never,
                Ok(Some(wo_house::Stems::Making)) => Got::Making,
                Ok(Some(wo_house::Stems::Ready(path))) => {
                    let frames = RATE as i64 * (record.seconds.max(60) as i64 + 2);
                    match engine.new_source(Channels::Stems, frames) {
                        Ok(mut source) => match wo_decode::decode_stems(&path, RATE, &mut source) {
                            Ok(_) => {
                                source.finish();
                                Got::Ready(source)
                            }
                            Err(e) => {
                                // a damaged download: gone, so the next ask fetches it again
                                if !local {
                                    let _ = std::fs::remove_file(&path);
                                }
                                Got::Failed(e.to_string())
                            }
                        },
                        Err(e) => Got::Failed(e.to_string()),
                    }
                }
                Err(e) => Got::Failed(e),
            };
            let _ = tx.send(Done::Stems { slot: d, turn, got });
        });
    }

    /// The stems' worker's answer for deck `d`.
    pub(crate) fn got_stems(&mut self, d: usize, got: Got) {
        let s = &mut self.slots[d].stems;
        s.retry_at = None;
        s.state = match got {
            Got::Ready(source) => {
                let deck = self.engine.deck(DeckId::new(d).unwrap());
                deck.set_gains(1, Gains { gain: 0.0, ..Gains::FULL }, 0.0);
                deck.set_source(1, &source);
                s.source = Some(source);
                Stems::Ready
            }
            Got::Making => {
                s.retry_at = Some(Instant::now() + RETRY);
                Stems::Making
            }
            Got::Never => Stems::Never,
            Got::None => Stems::None,
            Got::Failed(why) => {
                eprintln!("stems of {}: {why}", self.slots[d].record.title);
                s.retry_at = Some(Instant::now() + RETRY * 3);
                Stems::Failed(why)
            }
        };
        self.apply_part(d, RAMP);
    }

    /// Asks again for stems being made (or that failed) once their wait is over.
    pub(crate) fn stems_tick(&mut self) {
        let now = Instant::now();
        for d in 0..2 {
            if self.slots[d].stems.retry_at.is_some_and(|t| now >= t) {
                self.slots[d].stems.retry_at = None;
                self.ask_stems(d, false);
            }
        }
    }

    /// The part on deck `d` into the engine: the record in slot 0 for the whole (or while
    /// the stems are not on the deck), else the stems at the part's levels in slot 1.
    pub(crate) fn apply_part(&self, d: usize, ramp: f64) {
        let deck = self.engine.deck(DeckId::new(d).unwrap());
        let s = &self.slots[d].stems;
        let levels = s.mix.or((s.part != Part::Whole).then(|| s.part.levels()));
        if let (Some(_), Some(l)) = (&s.source, levels) {
            let [drums, rest, vocals] = l.as_array();
            deck.set_gains(0, Gains { gain: 0.0, ..Gains::FULL }, ramp);
            deck.set_gains(1, Gains { gain: 1.0, drums, rest, vocals }, ramp);
        } else {
            deck.set_gains(0, Gains::FULL, ramp);
            deck.set_gains(1, Gains { gain: 0.0, ..Gains::FULL }, ramp);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parts_are_v1s_levels() {
        // mixer.dart StemLevels.of
        assert_eq!(Part::Drums.levels().as_array(), [1.0, 0.0, 0.0]);
        assert_eq!(Part::Music.levels().as_array(), [0.0, 1.0, 1.0]);
        assert_eq!(Part::Instrumental.levels().as_array(), [1.0, 1.0, 0.0]);
        assert_eq!(Part::Vocals.levels().as_array(), [0.0, 0.0, 1.0]);
        assert_eq!(Part::Whole.levels().as_array(), [1.0; 3]);
        let words: Vec<_> = Part::ALL.iter().map(|p| p.word()).collect();
        assert_eq!(words, ["WHOLE", "DRUMS", "MUSIC", "NO VOX", "VOCALS"]);
    }
}
