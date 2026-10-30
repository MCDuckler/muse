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
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        fonts(&cc.egui_ctx);
        let tex = |name: &str, b: wo_deskcore::Backdrop| {
            cc.egui_ctx.load_texture(name, ColorImage::from_rgba_unmultiplied([b.width as usize, b.height as usize], &b.rgba), TextureOptions::LINEAR)
        };
        let desk = Desk::open();
        App {
            desk,
            backdrop: tex("backdrop", wo_deskcore::backdrop::backdrop(480, 270)),
            ball: tex("ball", wo_deskcore::backdrop::ball()),
            search: String::new(),
            bench: Bench::from_args(if std::env::var("WO_RENDERER").as_deref() == Ok("glow") { "egui-glow" } else { "egui-wgpu" }),
            shot: None,
        }
    }

}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let t0 = Instant::now();
        fit_the_design(ui.ctx());
        self.desk.tick();
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

fn main() -> eframe::Result {
    let renderer = match std::env::var("WO_RENDERER").as_deref() {
        Ok("glow") => eframe::Renderer::Glow,
        _ => eframe::Renderer::Wgpu,
    };
    let options = eframe::NativeOptions {
        renderer,
        viewport: egui::ViewportBuilder::default().with_inner_size([1920.0, 1080.0]).with_title("WetOwl Desk").with_app_id("wetowl-desk"),
        ..Default::default()
    };
    eframe::run_native("WetOwl Desk", options, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}

