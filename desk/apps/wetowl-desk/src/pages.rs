//! Every page and every overlay drawn headless — no window, no GPU, the shapes tessellated —
//! at the window sizes the Desk meets (a laptop zoomed, the smallest laid out, 1080p, 1440p),
//! with a set playing: nothing panics, nothing leaves the window, and a frame stays cheap.
use std::time::Instant;

use eframe::egui::{self, Rect, pos2, vec2};
use wo_deskcore::Desk;

use crate::show::Page;
use crate::{App, Overlay};

#[test]
#[cfg_attr(windows, ignore = "Windows' known folders cannot be moved aside for a test")]
fn every_page_and_overlay_draws_at_every_size() {
    // a Desk of its own: no sign-in, no sound card, no controllers, its folders in a
    // scratch place (the user's are not touched)
    let home = std::env::temp_dir().join(format!("wo-desk-pages-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    // SAFETY: this test is the only one in the crate that reads the environment, and sets it
    // before the Desk starts its threads.
    unsafe {
        // (a Mac's folders are under HOME)
        for (k, v) in [("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data"), ("HOME", "home")] {
            std::env::set_var(k, home.join(v));
        }
        std::env::set_var("WO_AUDIO", "off");
        std::env::set_var("WO_CONTROLLERS", "off");
    }
    let ctx = egui::Context::default();
    let desk = Desk::open(true);
    let mut app = App::with(&ctx, desk, None, false);
    let mut t = 0.0f64;
    let mut slowest = (0.0f32, String::new());
    let mut total = 0.0f32;
    let mut frames = 0;
    for size in [vec2(1280.0, 720.0), vec2(1400.0, 840.0), vec2(1920.0, 1080.0), vec2(2560.0, 1440.0)] {
        for page in [Page::Booth, Page::Show, Page::Kit] {
            for overlay in [None, Some(Overlay::Keys), Some(Overlay::Settings)] {
                if page == Page::Kit && overlay.is_some() {
                    continue;
                }
                app.page = page;
                app.overlay = overlay;
                for n in 0..8 {
                    t += 1.0 / 60.0;
                    app.desk.lock().unwrap().tick();
                    // as a window gives it: its pixels in points at the zoom (the screen's own
                    // scale 1 here)
                    let points = size / ctx.zoom_factor();
                    let input = egui::RawInput { screen_rect: Some(Rect::from_min_size(pos2(0.0, 0.0), points)), time: Some(t), ..Default::default() };
                    let t0 = Instant::now();
                    let mut window = Rect::NOTHING;
                    let out = ctx.run_ui(input, |ui| {
                        window = app.frame(ui).0;
                    });
                    let ppp = out.pixels_per_point;
                    let meshes = ctx.tessellate(out.shapes, ppp);
                    let ms = t0.elapsed().as_secs_f32() * 1000.0;
                    let what = format!("{page:?} {overlay:?} at {}×{}", size.x, size.y);
                    assert!(!meshes.is_empty(), "{what}: nothing drawn");
                    // the window is the screen (zoomed below the smallest laid out: from the frame
                    // after a resize on)
                    let zoom = ctx.zoom_factor();
                    assert!(n < 2 || (window.width() * zoom - size.x).abs() < 2.0 && (window.height() * zoom - size.y).abs() < 2.0, "{what}: the page is {window:?} at zoom {zoom}");
                    // the first frames lay out text and textures: the rest are the steady cost
                    if n >= 4 {
                        total += ms;
                        frames += 1;
                        if ms > slowest.0 {
                            slowest = (ms, what);
                        }
                    }
                }
            }
        }
    }
    let average = total / frames as f32;
    eprintln!("{frames} frames, {average:.2} ms on average; slowest {:.2} ms ({})", slowest.0, slowest.1);
    // generous for a CI machine (the HP's Ryzen 3500U: about 2 ms)
    assert!(average < 25.0, "a frame takes {average:.1} ms headless");
    let _ = std::fs::remove_dir_all(&home);
}
