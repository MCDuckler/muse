//! WetOwl Desk: the glass booth of the Look board (design/tokens.json), painted by hand over
//! one blurred stage, driven by wo-deskcore. `--bench 30 [--out DIR]` measures it.
use std::sync::{Arc, mpsc};
use std::time::Instant;

use eframe::egui::{self, Color32, ColorImage, CornerRadius, Rect, TextureHandle, TextureOptions, pos2};
use wo_deskcore::bench::Bench;
use wo_deskcore::theme;
use wo_deskcore::Desk;

mod booth;
mod paint;

use booth::fit_the_design;
use paint::{col, fonts};

pub(crate) struct App {
    desk: Desk,
    backdrop: TextureHandle,
    ball: TextureHandle,
    search: String,
    bench: Option<Bench>,
    shot: Option<mpsc::Receiver<Arc<ColorImage>>>,
    /// CUE held, per deck (CUE acts on press and on release).
    cue_held: [bool; 2],
    /// The nudge held, per deck.
    nudge_held: [i8; 2],
    /// The search as typed, when typing last changed it, what the house was last asked.
    search_at: Option<std::time::Instant>,
    searched: String,
    /// The sign-in form: house address, name, password; and whether the WetOwl app's
    /// sign-in is here to use.
    form: (String, String, String),
    app_sign_in: bool,
    /// The crate row a controller's browse is on, and whether the keys are shown.
    pub(crate) cursor: usize,
    pub(crate) show_keys: bool,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        fonts(&cc.egui_ctx);
        let tex = |name: &str, b: wo_deskcore::Backdrop| {
            cc.egui_ctx.load_texture(name, ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba), TextureOptions::LINEAR)
        };
        // --bench plays and mixes by itself; a desk opened by hand stays quiet
        let bench = Bench::from_args(if glow() { "egui-glow" } else { "egui-wgpu" });
        let desk = Desk::open(bench.is_some());
        App {
            desk,
            backdrop: tex("backdrop", wo_deskcore::backdrop::backdrop(480, 270)),
            ball: tex("ball", wo_deskcore::backdrop::ball()),
            search: String::new(),
            bench,
            shot: None,
            cue_held: [false; 2],
            nudge_held: [0; 2],
            search_at: None,
            searched: String::new(),
            form: (wo_house::DEFAULT_SERVER.to_owned(), String::new(), String::new()),
            app_sign_in: Desk::app_sign_in_here(),
            cursor: 0,
            show_keys: false,
        }
    }

}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let t0 = Instant::now();
        fit_the_design(ui.ctx());
        self.desk.tick();
        // the keyboard, unless a field is being typed in
        if !ui.ctx().egui_wants_keyboard_input() {
            let keys: Vec<(egui::Key, egui::Modifiers)> = ui.input(|i| {
                i.events
                    .iter()
                    .filter_map(|e| match e {
                        egui::Event::Key { key, pressed: true, repeat: false, modifiers, .. } => Some((*key, *modifiers)),
                        _ => None,
                    })
                    .collect()
            });
            for (k, m) in keys {
                self.key(k, m);
            }
        }
        let s = self.desk.snapshot();
        let full = ui.max_rect();
        let p = ui.painter().clone();
        p.rect_filled(full, CornerRadius::ZERO, col(theme::GROUND));
        p.image(self.backdrop.id(), full, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
        self.draw(ui, &p, full, &s);
        let work = t0.elapsed().as_secs_f32() * 1000.0;
        if let Some(b) = &mut self.bench {
            b.size = (full.width() as u32, full.height() as u32);
            if self.shot.is_none() && b.frame(work) {
                let (tx, rx) = mpsc::channel();
                ui.ctx().send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::ScreenshotCallback::new(move |img| {
                    let _ = tx.send(img);
                })));
                self.shot = Some(rx);
            }
            if let Some(rx) = &self.shot
                && let Ok(img) = rx.try_recv() {
                    let rgba: Vec<u8> = img.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
                    println!("{}", b.finish(Some((img.size[0] as u32, img.size[1] as u32, &rgba))));
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                }
        }
        ui.ctx().request_repaint();
    }
}

/// The window's icon (the launcher's, for X11 and Windows; Wayland takes the launcher's).
fn icon() -> egui::IconData {
    let img = image::load_from_memory(include_bytes!("../../../deploy/icon-64.png")).expect("the icon").to_rgba8();
    egui::IconData { width: img.width(), height: img.height(), rgba: img.into_raw() }
}

/// OpenGL on Linux (measured: 60 fps on the HP's Vega 8), wgpu elsewhere;
/// WO_RENDERER=glow|wgpu chooses.
fn glow() -> bool {
    match std::env::var("WO_RENDERER").as_deref() {
        Ok("glow") => true,
        Ok("wgpu") => false,
        _ => cfg!(target_os = "linux"),
    }
}

fn main() -> eframe::Result {
    let renderer = if glow() { eframe::Renderer::Glow } else { eframe::Renderer::Wgpu };
    let options = eframe::NativeOptions {
        renderer,
        viewport: egui::ViewportBuilder::default().with_inner_size([1920.0, 1080.0]).with_title("WetOwl Desk").with_app_id("wetowl-desk").with_icon(icon()),
        ..Default::default()
    };
    eframe::run_native("WetOwl Desk", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}


impl App {
    /// The booth's keys, the v1 booth's map: 1 2 play, Q W sync, Z X start in step, F G
    /// kill the bass, A the Auto DJ, M or Space mix now, S or N not that, ← → the
    /// crossfader (with shift: nudge the master), [ ] a 16-beat loop, ? the keys.
    fn key(&mut self, k: egui::Key, m: egui::Modifiers) {
        use egui::Key as K;
        let d = &mut self.desk;
        match k {
            K::Num1 => d.toggle_play(0),
            K::Num2 => d.toggle_play(1),
            K::Q => d.toggle_sync(0),
            K::W => d.toggle_sync(1),
            K::Z => d.start_in_step(0),
            K::X => d.start_in_step(1),
            K::F => d.kill(0, 0),
            K::G => d.kill(1, 0),
            K::A => {
                let on = d.snapshot().auto;
                d.set_auto(!on);
            }
            K::M | K::Space => d.mix_now(),
            K::S | K::N => d.not_that(),
            K::ArrowLeft | K::ArrowRight => {
                let dir = if k == K::ArrowLeft { -1.0 } else { 1.0 };
                if m.shift {
                    d.nudge_by(d.master(), dir * 0.01);
                } else {
                    let x = d.crossfader() + dir as f32 * 0.05;
                    d.set_crossfader(x);
                }
            }
            K::OpenBracket => d.loop_beats(0, 16.0),
            K::CloseBracket => d.loop_beats(1, 16.0),
            K::Questionmark | K::Slash if m.shift || k == K::Questionmark => self.show_keys = !self.show_keys,
            K::Escape => self.show_keys = false,
            _ => {}
        }
    }
}
