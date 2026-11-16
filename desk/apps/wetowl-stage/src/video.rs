//! The footage on the Rust stage: the cue's clip from this machine's library (wo_video), its
//! frame decoded on the player's thread and put into the stage's picture, and how it is drawn
//! — as the ground under a look, or as the scene itself.
use wo_render::video::{VideoDraw, VideoLook};
use wo_render::{Gpu, Stage};
use wo_show::frame::{GroundDraw, StageFrame};
use wo_show::scenes::SceneBook;
use wo_show::state::ShowState;
use wo_video::{Feed, FeedFrame, Library};

/// Whether `scene` (by id) is the footage itself.
pub fn filmed(book: &SceneBook, scene: Option<&str>) -> bool {
    scene.and_then(|s| book.scenes.get(s)).is_some_and(|s| s.layers.iter().any(|l| l.sim.as_deref() == Some("video")))
}

/// The stage's VideoDraw for a feed's frame (its new picture uploaded first).
pub fn draw_of(stage: &mut Stage, gpu: &Gpu, ff: &FeedFrame, palette: &[[f32; 3]; 3], figure: bool) -> VideoDraw {
    if let Some(p) = &ff.upload {
        stage.video_frame(gpu, ff.slot, p.w, p.h, &p.rgba);
    }
    let [ink, mid, paper] = wo_render::video::tones(palette);
    VideoDraw {
        slot: ff.slot,
        figure,
        look: VideoLook {
            aspect: ff.aspect,
            k: ff.k,
            fit: ff.fit,
            tint: ff.tint,
            dim: ff.dim,
            contrast: ff.contrast,
            saturation: ff.saturation,
            punch: ff.punch,
            film: ff.film,
            mirror: ff.mirror,
            ink,
            mid,
            paper,
        },
    }
}

pub struct VideoRun {
    pub feed: Feed,
    said: bool,
}

impl VideoRun {
    pub fn new(lib: Option<Library>) -> VideoRun {
        VideoRun { feed: Feed::new(lib), said: false }
    }

    /// The footage for this frame into `stage.video` (None where the frame shows none).
    pub fn frame(&mut self, stage: &mut Stage, gpu: &Gpu, book: &SceneBook, st: &ShowState, f: &StageFrame, dt: f64) {
        let figure = f.figure.is_none() && filmed(book, f.scene.as_deref());
        let ground = f.blend.is_some() && f.ground == GroundDraw::Video;
        if !figure && !ground {
            if stage.video.take().is_some() {
                self.feed.idle();
            }
            return;
        }
        stage.video = self.feed.frame(st.macros.video.as_ref(), st, dt).map(|ff| draw_of(stage, gpu, &ff, &f.palette, figure));
        if let Some(b) = self.feed.take_broken() {
            eprintln!("stage: footage: {b}");
        }
        if !self.said && !self.feed.missing.is_empty() {
            self.said = true;
            eprintln!("stage: footage not here: {}", self.feed.missing.join(", "));
        }
    }
}
