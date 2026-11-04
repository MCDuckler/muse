//! The booth's own sounds (v1's fx_sounds.dart + fx_channel.dart): a third voice off to
//! the side of the crossfader, on the engine's deck C.
use wo_booth::steps::FxShot;
use wo_engine::Engine;

#[derive(Default)]
pub(crate) struct Fx {}

impl Fx {
    /// `shot`, `seconds` long, over beats `beat` seconds long: rendered and played now.
    pub fn fire(&mut self, _engine: &Engine, _shot: FxShot, _seconds: f64, _beat: f64) {}
}
