//! The footage, frame by frame, for a stage: the cue's clip found in this machine's library,
//! its clock run, its frame asked of the player (or decoded at once, for a shot), and what the
//! stage should upload and draw — without the GPU (wo-render's VideoDraw is made of it).
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use wo_show::state::ShowState;
use wo_show::video::{ClipMeta, VideoClock, VideoCue, VideoMode, VideoTint};

use crate::library::Library;
use crate::player::Player;
use crate::proxy::{Picture, Proxy};

/// What the stage does with the footage this frame.
#[derive(Clone, Debug)]
pub struct FeedFrame {
    /// A new frame for picture `slot`.
    pub upload: Option<Arc<Picture>>,
    /// The picture the clip on is in (the other: the last clip's).
    pub slot: usize,
    /// The clip on over the last one, 0..1.
    pub k: f32,
    pub aspect: [f32; 2],
    /// wo-render's numbering: fill 0, fit 1, blur 2; as is 0, duotone 1, mono 2, sepia 3.
    pub fit: u32,
    pub tint: u32,
    pub dim: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub punch: f32,
    pub film: f32,
    pub mirror: bool,
    pub mode: VideoMode,
    pub frame: usize,
}

enum Decode {
    Thread(Player),
    /// At once, on the caller's thread (a shot, a test): every frame is the one asked for.
    Now(Option<(PathBuf, Proxy)>),
}

pub struct Feed {
    lib: Option<Library>,
    decode: Decode,
    clock: VideoClock,
    metas: HashMap<String, Option<ClipMeta>>,
    n: Option<u32>,
    slot: usize,
    /// The clip on has had a frame shown.
    ready: bool,
    shown: Option<(PathBuf, usize)>,
    aspect: [f32; 2],
    /// Said once each: the clips not here.
    pub missing: Vec<String>,
}

impl Feed {
    pub fn new(lib: Option<Library>) -> Feed {
        Feed::with(lib, Decode::Thread(Player::new()))
    }

    /// Every frame decoded before it is given (shots, tests).
    pub fn at_once(lib: Option<Library>) -> Feed {
        Feed::with(lib, Decode::Now(None))
    }

    fn with(lib: Option<Library>, decode: Decode) -> Feed {
        Feed { lib, decode, clock: VideoClock::default(), metas: HashMap::new(), n: None, slot: 0, ready: false, shown: None, aspect: [16.0 / 9.0; 2], missing: vec![] }
    }

    /// The clips' facts read again (the library changed).
    pub fn forget(&mut self) {
        self.metas.clear();
    }

    /// No footage wanted now.
    pub fn idle(&mut self) {
        if let Decode::Thread(p) = &self.decode {
            p.idle();
        }
        self.shown = None;
    }

    /// A proxy that would not open, once (from the player's thread).
    pub fn take_broken(&mut self) -> Option<String> {
        match &self.decode {
            Decode::Thread(p) => p.take_broken().map(|(path, e)| format!("{}: {e}", path.display())),
            Decode::Now(_) => None,
        }
    }

    /// This frame's footage: None where there is no cue, or its clip is not here.
    pub fn frame(&mut self, cue: Option<&VideoCue>, st: &ShowState, dt: f64) -> Option<FeedFrame> {
        let cue = cue?;
        let lib = self.lib.as_ref()?;
        let meta = self.metas.entry(cue.clip.clone()).or_insert_with(|| lib.meta(&cue.clip)).clone();
        let Some(meta) = meta else {
            if !self.missing.contains(&cue.clip) {
                self.missing.push(cue.clip.clone());
            }
            return None;
        };
        if self.n != Some(cue.n) {
            // a new clip into the other picture (the last one's kept to dissolve from)
            if self.n.is_some() && self.ready {
                self.slot = 1 - self.slot;
                self.aspect[1] = self.aspect[0];
            }
            self.n = Some(cue.n);
            self.ready = false;
            self.aspect[0] = meta.aspect();
        }
        let at = self.clock.tick(cue, &meta, st, dt);
        let path = lib.proxy(&cue.clip);
        let rate = meta.fps * dt.max(1.0 / 120.0) * cue.spec.speed;
        let ahead = crate::ahead(at.frame, meta.frames, rate);
        let got: Option<(usize, Arc<Picture>)> = match &mut self.decode {
            Decode::Thread(p) => {
                p.ask(&path, at.frame, &ahead);
                p.newest().filter(|s| s.path == path).map(|s| (s.frame, s.picture))
            }
            Decode::Now(open) => {
                if open.as_ref().is_none_or(|(p, _)| *p != path) {
                    *open = Proxy::open(&path).ok().map(|p| (path.clone(), p));
                }
                open.as_mut().and_then(|(_, p)| p.rgba(at.frame).ok()).map(|pic| (at.frame, Arc::new(pic)))
            }
        };
        let mut upload = None;
        if let Some((f, pic)) = got
            && self.shown.as_ref() != Some(&(path.clone(), f))
        {
            self.shown = Some((path, f));
            self.ready = true;
            upload = Some(pic);
        }
        let spec = &cue.spec;
        let tint = match spec.tint {
            // footage with next to no colour of its own takes the record's
            VideoTint::Auto => {
                if meta.colour < 0.08 {
                    1
                } else {
                    0
                }
            }
            VideoTint::Off => 0,
            VideoTint::Duotone => 1,
            VideoTint::Mono => 2,
            VideoTint::Sepia => 3,
        };
        Some(FeedFrame {
            upload,
            slot: self.slot,
            // until the new clip has a frame, the last clip's picture
            k: if self.ready { at.k } else { 0.0 },
            aspect: self.aspect,
            fit: spec.fit.index() as u32,
            tint,
            dim: spec.dim as f32,
            contrast: spec.contrast as f32,
            saturation: spec.saturation as f32,
            punch: spec.punch as f32,
            film: spec.film as f32,
            mirror: spec.mirror,
            mode: at.mode,
            frame: at.frame,
        })
    }
}
