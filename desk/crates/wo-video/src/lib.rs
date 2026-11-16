//! Footage for the Rust stage (plan: ~/.claude/plans/wetowl-video-scene.md).
//!
//! The hands put clips in a folder ([library::Library]); each is made, once, into a proxy
//! ([import]: ffmpeg → every frame a JPEG, at most 540 high and 30 a second, its black bars
//! and leader cut, its light and motion read). The stage asks a [player::Player] for the frame
//! wo_show::video::VideoClock says, and the player decodes it on its own thread.
pub mod feed;
pub mod import;
pub mod library;
pub mod player;
pub mod proxy;

pub use feed::{Feed, FeedFrame};
pub use import::{Stored, import, tools_found};
pub use library::{Library, Pending};
pub use player::{Player, Shown};
pub use proxy::{Picture, Proxy};

/// The frames after `frame` the clock will want soon: the next few at `rate` frames a frame
/// (more when it runs fast), round the clip's end.
pub fn ahead(frame: usize, frames: usize, rate: f64) -> Vec<usize> {
    if frames == 0 {
        return vec![];
    }
    let step = rate.abs().clamp(0.0, 4.0);
    (1..=4).map(|i| (frame as f64 + (i as f64 * step).ceil()) as usize % frames).filter(|f| *f != frame).collect()
}
