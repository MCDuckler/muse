//! The icons: drawn as strokes on a 24-unit grid (the Lucide way: 2-unit strokes, round
//! ends), scaled into whatever square they are given — never font glyphs, so every icon has
//! the same weight and sits on the same middle.
use eframe::egui::{Color32, Painter, Pos2, Rect, Shape, Stroke, pos2, vec2};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Icon {
    Play,
    Pause,
    Cue,
    Sync,
    Lock,
    Loop,
    Back4,
    Ahead4,
    Brake,
    Kill,
    Search,
    Settings,
    Heart,
    HeartFull,
    Eye,
    Screen,
    Plus,
    Close,
    ChevronLeft,
    ChevronRight,
    ChevronDown,
    Check,
    Undo,
    Bolt,
    Next,
    Previous,
    Snow,
    Power,
    Shuffle,
    Keys,
    Layers,
    Dice,
    Dot,
    ArrowUp,
    ArrowDown,
    Similar,
    ThumbDown,
    AutoMix,
    List,
    Timeline,
    House,
    Controller,
    Gauge,
    User,
    Pin,
    LogOut,
    Mic,
    MicOff,
    Drum,
    Note,
    Grid,
    Sections,
    Disc,
    Alert,
    Info,
    CheckCircle,
    Live,
}

/// Points of the 24 grid into `r`.
struct G {
    o: Pos2,
    k: f32,
}

impl G {
    fn p(&self, x: f32, y: f32) -> Pos2 {
        pos2(self.o.x + x * self.k, self.o.y + y * self.k)
    }
}

/// `icon` in the square `r`, in `color`.
pub fn paint(p: &Painter, r: Rect, icon: Icon, color: Color32) {
    let side = r.width().min(r.height());
    let g = G { o: r.center() - vec2(side, side) / 2.0, k: side / 24.0 };
    let w = (2.0 * g.k).max(1.4);
    let s = Stroke::new(w, color);
    let line = |pts: &[(f32, f32)]| { p.add(Shape::line(pts.iter().map(|&(x, y)| g.p(x, y)).collect(), s)); };
    let closed = |pts: &[(f32, f32)]| { p.add(Shape::closed_line(pts.iter().map(|&(x, y)| g.p(x, y)).collect(), s)); };
    let fill = |pts: &[(f32, f32)]| { p.add(Shape::convex_polygon(pts.iter().map(|&(x, y)| g.p(x, y)).collect(), color, Stroke::NONE)); };
    let circle = |x: f32, y: f32, rr: f32| { p.circle_stroke(g.p(x, y), rr * g.k, s); };
    let arc = |x: f32, y: f32, rr: f32, a0: f32, a1: f32| {
        let n = 20;
        let pts: Vec<Pos2> = (0..=n)
            .map(|i| {
                let a = (a0 + (a1 - a0) * i as f32 / n as f32).to_radians();
                g.p(x + rr * a.cos(), y + rr * a.sin())
            })
            .collect();
        p.add(Shape::line(pts, s));
    };
    // a rectangle with round corners (radius `rr`), closed
    let rrect = |x0: f32, y0: f32, x1: f32, y1: f32, rr: f32| {
        let mut pts = vec![];
        for (cx, cy, a0) in [(x1 - rr, y0 + rr, -90.0f32), (x1 - rr, y1 - rr, 0.0), (x0 + rr, y1 - rr, 90.0), (x0 + rr, y0 + rr, 180.0)] {
            for i in 0..=5 {
                let a = (a0 + 90.0 * i as f32 / 5.0).to_radians();
                pts.push(g.p(cx + rr * a.cos(), cy + rr * a.sin()));
            }
        }
        p.add(Shape::closed_line(pts, s));
    };
    let dot = |x: f32, y: f32, rr: f32| {
        p.circle_filled(g.p(x, y), rr * g.k, color);
    };
    match icon {
        Icon::Play => fill(&[(7.0, 4.5), (19.5, 12.0), (7.0, 19.5)]),
        Icon::Pause => {
            fill(&[(6.5, 5.0), (10.0, 5.0), (10.0, 19.0), (6.5, 19.0)]);
            fill(&[(14.0, 5.0), (17.5, 5.0), (17.5, 19.0), (14.0, 19.0)]);
        }
        Icon::Cue => {
            circle(12.0, 12.0, 8.0);
            p.circle_filled(g.p(12.0, 12.0), 3.0 * g.k, color);
        }
        Icon::Sync => {
            arc(12.0, 12.0, 7.5, 200.0, 340.0);
            line(&[(17.5, 5.5), (19.2, 9.4), (15.2, 10.2)]);
            arc(12.0, 12.0, 7.5, 20.0, 160.0);
            line(&[(6.5, 18.5), (4.8, 14.6), (8.8, 13.8)]);
        }
        Icon::Lock => {
            rrect(5.0, 11.0, 19.0, 20.5, 2.0);
            arc(12.0, 9.0, 4.0, 180.0, 360.0);
            line(&[(8.0, 9.0), (8.0, 11.0)]);
            line(&[(16.0, 9.0), (16.0, 11.0)]);
        }
        Icon::Loop => {
            arc(8.0, 12.0, 4.5, 90.0, 270.0);
            arc(16.0, 12.0, 4.5, -90.0, 90.0);
            line(&[(8.0, 7.5), (16.0, 7.5)]);
            line(&[(8.0, 16.5), (16.0, 16.5)]);
            line(&[(13.5, 5.0), (16.0, 7.5), (13.5, 10.0)]);
        }
        Icon::Back4 => {
            line(&[(11.0, 6.0), (5.0, 12.0), (11.0, 18.0)]);
            line(&[(19.0, 6.0), (13.0, 12.0), (19.0, 18.0)]);
        }
        Icon::Ahead4 => {
            line(&[(5.0, 6.0), (11.0, 12.0), (5.0, 18.0)]);
            line(&[(13.0, 6.0), (19.0, 12.0), (13.0, 18.0)]);
        }
        Icon::Brake => {
            arc(12.0, 13.0, 7.5, 160.0, 380.0);
            line(&[(12.0, 13.0), (16.0, 8.5)]);
        }
        Icon::Kill => {
            closed(&[(4.0, 9.5), (8.0, 9.5), (12.5, 5.5), (12.5, 18.5), (8.0, 14.5), (4.0, 14.5)]);
            line(&[(16.0, 9.0), (21.0, 15.0)]);
            line(&[(21.0, 9.0), (16.0, 15.0)]);
        }
        Icon::Search => {
            circle(10.5, 10.5, 6.0);
            line(&[(15.0, 15.0), (20.0, 20.0)]);
        }
        Icon::Settings => {
            circle(12.0, 12.0, 3.0);
            for i in 0..8 {
                let a = (i as f32 * 45.0).to_radians();
                line(&[(12.0 + 6.0 * a.cos(), 12.0 + 6.0 * a.sin()), (12.0 + 9.0 * a.cos(), 12.0 + 9.0 * a.sin())]);
            }
            circle(12.0, 12.0, 6.5);
        }
        Icon::Heart | Icon::HeartFull => {
            let pts: Vec<(f32, f32)> = (0..=40)
                .map(|i| {
                    let t = i as f32 / 40.0 * std::f32::consts::TAU;
                    // a heart curve, fitted to the grid
                    let x = 16.0 * t.sin().powi(3);
                    let y = 13.0 * t.cos() - 5.0 * (2.0 * t).cos() - 2.0 * (3.0 * t).cos() - (4.0 * t).cos();
                    (12.0 + x * 0.52, 11.5 - y * 0.52)
                })
                .collect();
            if icon == Icon::HeartFull {
                // a heart is not convex: a fan from its middle, as one plain mesh (feathered
                // thin triangles at its cusp would spike); the outline smooths its edge
                let mut m = eframe::egui::Mesh::default();
                m.colored_vertex(g.p(12.0, 12.0), color);
                for &(x, y) in &pts {
                    m.colored_vertex(g.p(x, y), color);
                }
                for i in 1..pts.len() as u32 {
                    m.add_triangle(0, i, i + 1);
                }
                p.add(m);
            }
            closed(&pts);
        }
        Icon::Eye => {
            arc(12.0, 20.0, 11.0, 222.0, 318.0);
            arc(12.0, 4.0, 11.0, 42.0, 138.0);
            circle(12.0, 12.0, 3.0);
        }
        Icon::Screen => {
            rrect(3.0, 4.5, 21.0, 16.0, 2.0);
            line(&[(9.0, 20.0), (15.0, 20.0)]);
            line(&[(12.0, 16.0), (12.0, 20.0)]);
        }
        Icon::Plus => {
            line(&[(12.0, 5.0), (12.0, 19.0)]);
            line(&[(5.0, 12.0), (19.0, 12.0)]);
        }
        Icon::Close => {
            line(&[(6.0, 6.0), (18.0, 18.0)]);
            line(&[(18.0, 6.0), (6.0, 18.0)]);
        }
        Icon::ChevronLeft => line(&[(15.0, 5.0), (8.0, 12.0), (15.0, 19.0)]),
        Icon::ChevronRight => line(&[(9.0, 5.0), (16.0, 12.0), (9.0, 19.0)]),
        Icon::ChevronDown => line(&[(5.0, 9.0), (12.0, 16.0), (19.0, 9.0)]),
        Icon::Check => line(&[(5.0, 12.5), (10.0, 17.5), (19.0, 7.0)]),
        Icon::Undo => {
            arc(13.0, 13.5, 6.5, -90.0, 150.0);
            line(&[(13.0, 7.0), (6.0, 7.0)]);
            line(&[(9.0, 4.0), (6.0, 7.0), (9.0, 10.0)]);
        }
        Icon::Bolt => closed(&[(13.0, 3.0), (5.0, 13.5), (11.0, 13.5), (10.0, 21.0), (19.0, 10.0), (13.0, 10.0)]),
        Icon::Next => {
            fill(&[(5.0, 5.5), (15.0, 12.0), (5.0, 18.5)]);
            line(&[(18.5, 5.5), (18.5, 18.5)]);
        }
        Icon::Previous => {
            fill(&[(19.0, 5.5), (9.0, 12.0), (19.0, 18.5)]);
            line(&[(5.5, 5.5), (5.5, 18.5)]);
        }
        Icon::Snow => {
            for i in 0..3 {
                let a = (i as f32 * 60.0 + 90.0).to_radians();
                line(&[(12.0 - 8.5 * a.cos(), 12.0 - 8.5 * a.sin()), (12.0 + 8.5 * a.cos(), 12.0 + 8.5 * a.sin())]);
            }
        }
        Icon::Power => {
            arc(12.0, 13.0, 7.5, -50.0, 230.0);
            line(&[(12.0, 3.5), (12.0, 11.0)]);
        }
        Icon::Shuffle => {
            line(&[(3.5, 7.0), (8.0, 7.0), (16.0, 17.0), (20.5, 17.0)]);
            line(&[(3.5, 17.0), (8.0, 17.0), (16.0, 7.0), (20.5, 7.0)]);
            line(&[(18.0, 4.5), (20.5, 7.0), (18.0, 9.5)]);
            line(&[(18.0, 14.5), (20.5, 17.0), (18.0, 19.5)]);
        }
        Icon::Keys => {
            rrect(2.5, 6.0, 21.5, 18.0, 2.0);
            for x in [6.5, 10.0, 13.5, 17.0] {
                p.circle_filled(g.p(x, 10.0), 0.9 * g.k, color);
            }
            line(&[(8.0, 14.0), (16.0, 14.0)]);
        }
        Icon::Layers => {
            closed(&[(12.0, 3.5), (21.0, 8.5), (12.0, 13.5), (3.0, 8.5)]);
            line(&[(3.0, 12.5), (12.0, 17.5), (21.0, 12.5)]);
            line(&[(3.0, 16.0), (12.0, 21.0), (21.0, 16.0)]);
        }
        Icon::Dice => {
            rrect(4.0, 4.0, 20.0, 20.0, 3.0);
            for (x, y) in [(8.5, 8.5), (15.5, 15.5), (12.0, 12.0)] {
                p.circle_filled(g.p(x, y), 1.4 * g.k, color);
            }
        }
        Icon::Dot => {
            p.circle_filled(g.p(12.0, 12.0), 4.0 * g.k, color);
        }
        Icon::ArrowUp => {
            line(&[(12.0, 19.0), (12.0, 5.0)]);
            line(&[(6.0, 11.0), (12.0, 5.0), (18.0, 11.0)]);
        }
        Icon::ArrowDown => {
            line(&[(12.0, 5.0), (12.0, 19.0)]);
            line(&[(6.0, 13.0), (12.0, 19.0), (18.0, 13.0)]);
        }
        Icon::Similar => {
            for y in [9.0f32, 15.0] {
                let pts: Vec<(f32, f32)> = (0..=16).map(|i| {
                    let x = 4.0 + i as f32;
                    (x, y - 1.8 * ((x - 4.0) / 16.0 * std::f32::consts::TAU).sin())
                }).collect();
                line(&pts);
            }
        }
        Icon::ThumbDown => {
            rrect(17.0, 3.0, 21.0, 14.0, 1.0);
            closed(&[(17.0, 3.0), (7.0, 3.0), (5.2, 4.6), (3.2, 12.4), (4.7, 14.5), (10.0, 14.5), (9.2, 19.0), (10.8, 21.0), (12.4, 21.0), (17.0, 14.0)]);
        }
        Icon::AutoMix => {
            let ease = |t: f32| t * t * (3.0 - 2.0 * t);
            let a: Vec<(f32, f32)> = (0..=12).map(|i| { let t = i as f32 / 12.0; (3.0 + 18.0 * t, 6.0 + 12.0 * ease(t)) }).collect();
            let b: Vec<(f32, f32)> = (0..=12).map(|i| { let t = i as f32 / 12.0; (3.0 + 18.0 * t, 18.0 - 12.0 * ease(t)) }).collect();
            line(&a);
            line(&b);
        }
        Icon::List => {
            for y in [6.0, 12.0, 18.0] {
                line(&[(9.0, y), (20.0, y)]);
                dot(4.5, y, 1.3);
            }
        }
        Icon::Timeline => {
            line(&[(4.0, 4.0), (4.0, 20.0), (20.0, 20.0)]);
            line(&[(8.0, 8.0), (14.0, 8.0)]);
            line(&[(11.0, 12.0), (19.0, 12.0)]);
            line(&[(8.0, 16.0), (15.0, 16.0)]);
        }
        Icon::House => {
            closed(&[(4.0, 10.5), (12.0, 3.8), (20.0, 10.5), (20.0, 20.0), (4.0, 20.0)]);
            line(&[(10.0, 20.0), (10.0, 14.0), (14.0, 14.0), (14.0, 20.0)]);
        }
        Icon::Controller => {
            rrect(2.5, 6.0, 21.5, 18.0, 2.5);
            circle(8.5, 12.0, 2.8);
            line(&[(15.0, 9.0), (15.0, 15.0)]);
            line(&[(18.5, 9.0), (18.5, 15.0)]);
        }
        Icon::Gauge => {
            arc(12.0, 15.0, 8.5, 180.0, 360.0);
            line(&[(12.0, 15.0), (16.5, 9.5)]);
            dot(12.0, 15.0, 1.6);
        }
        Icon::User => {
            circle(12.0, 8.0, 4.0);
            arc(12.0, 21.0, 7.0, 180.0, 360.0);
        }
        Icon::Pin => {
            let pts: Vec<(f32, f32)> = (0..=16).map(|i| {
                let a = (140.0 + 260.0 * i as f32 / 16.0f32).to_radians();
                (12.0 + 6.5 * a.cos(), 9.5 + 6.5 * a.sin())
            }).collect();
            let mut all = pts.clone();
            all.push((12.0, 21.5));
            closed(&all);
            circle(12.0, 9.5, 2.2);
        }
        Icon::LogOut => {
            line(&[(10.0, 4.0), (5.0, 4.0), (5.0, 20.0), (10.0, 20.0)]);
            line(&[(10.0, 12.0), (20.0, 12.0)]);
            line(&[(16.0, 8.0), (20.0, 12.0), (16.0, 16.0)]);
        }
        Icon::Mic | Icon::MicOff => {
            arc(12.0, 6.5, 3.0, 180.0, 360.0);
            line(&[(9.0, 6.5), (9.0, 11.0)]);
            line(&[(15.0, 6.5), (15.0, 11.0)]);
            arc(12.0, 11.0, 3.0, 0.0, 180.0);
            arc(12.0, 11.0, 6.5, 0.0, 180.0);
            line(&[(12.0, 17.5), (12.0, 21.0)]);
            if icon == Icon::MicOff {
                line(&[(4.0, 4.0), (20.0, 20.0)]);
            }
        }
        Icon::Drum => {
            let ell = |cy: f32, a0: f32, a1: f32| {
                let pts: Vec<(f32, f32)> = (0..=20).map(|i| {
                    let a = (a0 + (a1 - a0) * i as f32 / 20.0).to_radians();
                    (12.0 + 8.5 * a.cos(), cy + 3.2 * a.sin())
                }).collect();
                line(&pts);
            };
            ell(8.5, 0.0, 360.0);
            ell(16.5, 0.0, 180.0);
            line(&[(3.5, 8.5), (3.5, 16.5)]);
            line(&[(20.5, 8.5), (20.5, 16.5)]);
            line(&[(14.0, 7.0), (19.5, 2.5)]);
        }
        Icon::Note => {
            line(&[(9.0, 18.0), (9.0, 5.0), (21.0, 3.0), (21.0, 16.0)]);
            circle(6.0, 18.0, 3.0);
            circle(18.0, 16.0, 3.0);
        }
        Icon::Grid => {
            line(&[(4.0, 4.0), (4.0, 20.0)]);
            for x in [9.5, 15.0, 20.5] {
                line(&[(x, 9.0), (x, 15.0)]);
            }
        }
        Icon::Sections => {
            rrect(2.5, 12.0, 8.0, 20.0, 1.2);
            rrect(9.5, 5.0, 15.0, 20.0, 1.2);
            rrect(16.5, 9.0, 21.5, 20.0, 1.2);
        }
        Icon::Disc => {
            circle(12.0, 12.0, 9.0);
            circle(12.0, 12.0, 2.5);
            arc(12.0, 12.0, 5.8, 200.0, 280.0);
        }
        Icon::Alert => {
            closed(&[(12.0, 3.5), (21.5, 20.0), (2.5, 20.0)]);
            line(&[(12.0, 9.5), (12.0, 13.5)]);
            dot(12.0, 16.8, 1.3);
        }
        Icon::Info => {
            circle(12.0, 12.0, 9.0);
            line(&[(12.0, 11.0), (12.0, 16.5)]);
            dot(12.0, 7.8, 1.3);
        }
        Icon::CheckCircle => {
            circle(12.0, 12.0, 9.0);
            line(&[(8.0, 12.2), (11.0, 15.0), (16.5, 9.3)]);
        }
        Icon::Live => {
            dot(12.0, 12.0, 2.2);
            arc(12.0, 12.0, 5.5, -40.0, 40.0);
            arc(12.0, 12.0, 5.5, 140.0, 220.0);
            arc(12.0, 12.0, 9.5, -40.0, 40.0);
            arc(12.0, 12.0, 9.5, 140.0, 220.0);
        }
    }
}
