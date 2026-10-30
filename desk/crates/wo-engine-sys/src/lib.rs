//! The booth engine's C API (`app/native/engine/src/we_engine.h`), word for word.
//! The header is the documentation; `wo-engine` is the safe face of it.
#![allow(non_camel_case_types)]

use std::ffi::c_char;

pub const WE_DECKS: usize = 4;
pub const WE_SOURCES: usize = 6;
pub const WE_MASTER: i32 = WE_DECKS as i32;
pub const WE_SPECTRUM: usize = 32;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct we_load_state {
    pub average: f64,
    pub worst: f64,
    pub late: i64,
    pub faster: i32,
    pub period: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct we_deck_state {
    pub heard: f64,
    pub at: f64,
    pub rate: f64,
    pub length: f64,
    pub loop_a: f64,
    pub loop_b: f64,
    pub phase_error: f64,
    pub moves: i64,
    pub playing: i32,
    pub looping: i32,
    pub synced: i32,
    pub braking: i32,
    pub ended: i32,
    pub peak_l: f32,
    pub peak_r: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct we_features_state {
    pub at: f64,
    pub sub: f32,
    pub low: f32,
    pub mid: f32,
    pub high: f32,
    pub air: f32,
    pub kick: f32,
    pub snare: f32,
    pub hat: f32,
    pub onset: f32,
    pub rms: f32,
    pub peak: f32,
    pub spectrum: [f32; WE_SPECTRUM],
    pub rows: i32,
}

unsafe extern "C" {
    // the engine
    pub fn we_start(rate: i32, device: i32) -> i32;
    pub fn we_stop();
    pub fn we_error() -> *const c_char;
    pub fn we_rate() -> i32;
    pub fn we_latency() -> f64;
    pub fn we_now() -> f64;
    pub fn we_load(out: *mut we_load_state);
    pub fn we_stretch(faster: i32);
    pub fn we_render(out: *mut f32, frames: i32, decks: *mut *mut f32);

    // sources
    pub fn we_source_new(channels: i32, frames_hint: i64) -> i32;
    pub fn we_source_append(source: i32, pcm: *const i16, frames: i64) -> i32;
    pub fn we_source_done(source: i32);
    pub fn we_source_frames(source: i32) -> i64;
    pub fn we_source_free(source: i32);

    // decks
    pub fn we_deck_source(deck: i32, slot: i32, source: i32);
    pub fn we_deck_source_gain(deck: i32, slot: i32, gain: f32, drums: f32, rest: f32, vocals: f32, ramp: f64);
    pub fn we_deck_play(deck: i32, playing: i32);
    pub fn we_deck_seek(deck: i32, t: f64);
    pub fn we_deck_rate(deck: i32, rate: f64);
    pub fn we_deck_bend(deck: i32, factor: f64);
    pub fn we_deck_keylock(deck: i32, on: i32);
    pub fn we_deck_shift(deck: i32, semitones: f64);
    pub fn we_deck_beats(deck: i32, times: *const f64, count: i32);
    pub fn we_deck_sync(deck: i32, master: i32, every: i32, offset: f64);
    pub fn we_deck_bar_one(deck: i32, beat_index: i32);
    pub fn we_deck_start(deck: i32, master: i32, every: i32, at: f64, offset: f64);
    pub fn we_deck_sync_offset(deck: i32, offset: f64);
    pub fn we_deck_sync_octave(deck: i32, octave: f64);
    pub fn we_deck_align(deck: i32, master: i32, every: i32, offset: f64);
    pub fn we_deck_loop(deck: i32, a: f64, b: f64);
    pub fn we_deck_loop_beats(deck: i32, beats: f64, bar: i32);
    pub fn we_deck_level(deck: i32, gain: f32, ramp: f64);
    pub fn we_deck_eq(deck: i32, low: f32, mid: f32, high: f32, ramp: f64);
    pub fn we_deck_filter(deck: i32, knob: f32);
    pub fn we_deck_gate(deck: i32, depth: f32, period: f64, origin: f64);
    pub fn we_deck_echo(deck: i32, send: f32, dry: f32, beat: f64);
    pub fn we_deck_brake(deck: i32, seconds: f64);
    pub fn we_master_level(gain: f32);

    // what a deck is doing, what is heard
    pub fn we_deck_read(deck: i32, out: *mut we_deck_state);
    pub fn we_features(bus: i32, from: f64, to: f64, out: *mut we_features_state) -> i32;
    pub fn we_scope(bus: i32, at: f64, out: *mut f32, n: i32) -> i32;
    pub fn we_deck_position(deck: i32) -> f64;
}

#[cfg(test)]
mod tests {
    use super::*;

    // The structs cross the boundary by pointer: their sizes must be the C ones.
    #[test]
    fn layouts_match_the_header() {
        assert_eq!(std::mem::size_of::<we_load_state>(), 32);
        assert_eq!(std::mem::size_of::<we_deck_state>(), 96);
        assert_eq!(std::mem::size_of::<we_features_state>(), 8 + 11 * 4 + 32 * 4 + 4);
    }

    #[test]
    fn starts_offline_and_renders_silence() {
        unsafe {
            assert_eq!(we_start(48000, 0), 0);
            assert_eq!(we_rate(), 48000);
            let mut out = vec![1.0f32; 480 * 2];
            we_render(out.as_mut_ptr(), 480, std::ptr::null_mut());
            assert!(out.iter().all(|&x| x == 0.0));
            we_stop();
        }
    }
}
