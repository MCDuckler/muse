//! The crate drawn as rekordbox's browser in its layout: dense rows (18 px), its columns
//! — #, artwork, Preview, Track Title, Artist, Album, Genre, BPM, Key, Time, Rating, Date
//! Added (and the Desk's own Fits) — dropping the least needed as the browser narrows,
//! rows shaded in turn, the selected row blue, a record on a deck in green with its deck's
//! number. What the rows do (load, drag, menus, the controller's cursor) is the crate's.
use eframe::egui::{self, Align2, Color32, CornerRadius, Painter, Pos2, Rect, Sense, Shape, Stroke, Ui, pos2, vec2};
use wo_deskcore::{Desk, Row, Snapshot, theme};

use crate::club::{LINE, MUTED, TEXT, words};
use crate::paint::col;
use crate::ui::kit;
use crate::wave::{self, Anchor, Columns};
use crate::{App, Sort};

/// A row's height.
pub(crate) const ROW: f32 = 18.0;

const fn rgb(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

const SELECTED: Color32 = rgb(0x0B4F86);
const LOADED: Color32 = rgb(0x2BC46B);
/// A record played today (its row, as rekordbox's played tracks).
const PLAYED: Color32 = rgb(0x6FA7C9);
const SHADE: Color32 = rgb(0x1F1F22);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Col {
    Num,
    Art,
    Preview,
    Title,
    Artist,
    Album,
    Genre,
    Bpm,
    Key,
    Time,
    Rating,
    Added,
    Fits,
}

impl Col {
    fn head(self) -> &'static str {
        match self {
            Col::Num => "#",
            Col::Art => "",
            Col::Preview => "Preview",
            Col::Title => "Track Title",
            Col::Artist => "Artist",
            Col::Album => "Album",
            Col::Genre => "Genre",
            Col::Bpm => "BPM",
            Col::Key => "Key",
            Col::Time => "Time",
            Col::Rating => "Rating",
            Col::Added => "Date Added",
            Col::Fits => "Fits",
        }
    }

    fn sort(self) -> Option<Sort> {
        match self {
            Col::Title => Some(Sort::Title),
            Col::Artist => Some(Sort::Artist),
            Col::Album => Some(Sort::Album),
            Col::Genre => Some(Sort::Genre),
            Col::Bpm => Some(Sort::Bpm),
            Col::Key => Some(Sort::Key),
            Col::Time => Some(Sort::Time),
            Col::Rating => Some(Sort::Rating),
            Col::Added => Some(Sort::Added),
            Col::Fits => Some(Sort::Fits),
            _ => None,
        }
    }

    /// Numbers sit right in their column.
    fn right(self) -> bool {
        matches!(self, Col::Bpm | Col::Time)
    }
}

/// Where each column is across a browser `w` wide (x from its left, its width).
pub(crate) struct ClubCols(pub Vec<(Col, f32, f32)>);

impl ClubCols {
    pub(crate) fn for_width(w: f32) -> ClubCols {
        // fixed widths, the least needed dropped first as it narrows; the rest shared by the
        // title, the artist and the album
        let mut fixed = vec![(Col::Num, 30.0), (Col::Art, 22.0), (Col::Preview, 104.0), (Col::Genre, 86.0), (Col::Bpm, 54.0), (Col::Key, 38.0), (Col::Time, 48.0), (Col::Rating, 70.0), (Col::Added, 80.0), (Col::Fits, 52.0)];
        let mut album = true;
        let need = |fixed: &[(Col, f32)], album: bool| fixed.iter().map(|c| c.1 + 8.0).sum::<f32>() + if album { 3.0 * 150.0 } else { 2.0 * 160.0 } + 16.0;
        for drop in [Col::Added, Col::Rating, Col::Genre, Col::Fits, Col::Preview] {
            if need(&fixed, album) <= w {
                break;
            }
            if drop == Col::Fits && album {
                album = false;
                if need(&fixed, album) <= w {
                    break;
                }
            }
            fixed.retain(|c| c.0 != drop);
        }
        let flex = (w - fixed.iter().map(|c| c.1 + 8.0).sum::<f32>() - 16.0 - if album { 24.0 } else { 16.0 }).max(200.0);
        let shares: Vec<(Col, f32)> = if album { vec![(Col::Title, 0.42), (Col::Artist, 0.31), (Col::Album, 0.27)] } else { vec![(Col::Title, 0.57), (Col::Artist, 0.43)] };
        let order = [Col::Num, Col::Art, Col::Preview, Col::Title, Col::Artist, Col::Album, Col::Genre, Col::Bpm, Col::Key, Col::Time, Col::Rating, Col::Added, Col::Fits];
        let mut x = 8.0;
        let mut out = vec![];
        for c in order {
            let wid = fixed.iter().find(|f| f.0 == c).map(|f| f.1).or_else(|| shares.iter().find(|s| s.0 == c).map(|s| s.1 * flex));
            if let Some(wid) = wid {
                out.push((c, x, wid));
                x += wid + 8.0;
            }
        }
        ClubCols(out)
    }

    #[cfg(test)]
    pub(crate) fn has(&self, c: Col) -> bool {
        self.0.iter().any(|x| x.0 == c)
    }
}

/// A five-pointed star, filled or its outline only.
fn star(p: &Painter, c: Pos2, r: f32, filled: bool, ink: Color32) {
    let pts: Vec<Pos2> = (0..10)
        .map(|i| {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / 5.0;
            let rr = if i % 2 == 0 { r } else { r * 0.45 };
            pos2(c.x + rr * a.cos(), c.y + rr * a.sin())
        })
        .collect();
    if filled {
        for i in 0..10 {
            p.add(Shape::convex_polygon(vec![c, pts[i], pts[(i + 1) % 10]], ink, Stroke::NONE));
        }
    } else {
        let mut ring = pts.clone();
        ring.push(pts[0]);
        p.add(Shape::line(ring, Stroke::new(0.8, ink)));
    }
}

impl App {
    /// The browser's column heads at `y` across `main`: a click sorts by it, again the
    /// other way round.
    pub(crate) fn club_heads(&mut self, ui: &mut Ui, p: &Painter, main: Rect, y: f32, cols: &ClubCols) {
        let band = Rect::from_min_max(pos2(main.left() + 1.0, y - 9.0), pos2(main.right() - 1.0, y + 9.0));
        p.rect_filled(band, CornerRadius::ZERO, rgb(0x232326));
        p.line_segment([pos2(band.left(), band.bottom()), pos2(band.right(), band.bottom())], Stroke::new(1.0, LINE));
        for (i, &(c, x, w)) in cols.0.iter().enumerate() {
            let cell = Rect::from_min_size(pos2(main.left() + x, band.top()), vec2(w, band.height()));
            if i > 0 {
                p.line_segment([pos2(cell.left() - 4.0, band.top() + 3.0), pos2(cell.left() - 4.0, band.bottom() - 3.0)], Stroke::new(1.0, LINE));
            }
            let on = c.sort().is_some_and(|s| s == self.sort.0);
            let at = if c.right() { pos2(cell.right(), y) } else { pos2(cell.left(), y) };
            let a = if c.right() { Align2::RIGHT_CENTER } else { Align2::LEFT_CENTER };
            let r = kit::clipped_at(p, at, a, c.head(), 11.0, "", if on { TEXT } else { MUTED }, w);
            if on {
                let ax = if c.right() { r.left() - 7.0 } else { r.right() + 6.0 };
                let (top, bot) = if self.sort.1 { (y + 2.5, y - 2.5) } else { (y - 2.5, y + 2.5) };
                p.add(Shape::convex_polygon(vec![pos2(ax - 3.0, top), pos2(ax + 3.0, top), pos2(ax, bot)], TEXT, Stroke::NONE));
            }
            if let Some(sort) = c.sort() {
                let resp = ui.interact(cell, ui.scope_id().with(("club-head", i)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
                if resp.clicked() {
                    self.sort = if self.sort.0 == sort { (sort, !self.sort.1) } else { (sort, false) };
                }
            }
        }
    }

    /// One row; the artwork's rect (a loaded record flies from it to its deck).
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn club_row(&mut self, desk: &mut Desk, ui: &Ui, p: &Painter, rr: Rect, row: &Row, i: usize, cursor: bool, hovered: bool, cols: &ClubCols, s: &Snapshot) -> Rect {
        let ctx = ui.ctx().clone();
        let bg = if cursor { SELECTED } else if i % 2 == 1 { SHADE } else { Color32::TRANSPARENT };
        if bg != Color32::TRANSPARENT {
            p.rect_filled(rr, CornerRadius::ZERO, bg);
        }
        if hovered && !cursor {
            p.rect_filled(rr, CornerRadius::ZERO, Color32::from_white_alpha(10));
        }
        let r = &row.record;
        // a record on today's history in another colour (rekordbox's Coloring of played tracks)
        let ink = if row.on_deck.is_some() { LOADED } else if !r.playable() { MUTED } else if row.played { PLAYED } else { TEXT };
        let y = rr.center().y;
        let mut art = Rect::from_min_size(pos2(rr.left(), y - 8.0), vec2(16.0, 16.0));
        for &(c, x, w) in &cols.0 {
            let left = rr.left() + x;
            let cell = Rect::from_min_size(pos2(left, rr.top()), vec2(w, rr.height()));
            let text = |s: &str, ink: Color32| {
                if c.right() {
                    kit::clipped_at(p, pos2(cell.right(), y), Align2::RIGHT_CENTER, s, 11.5, "", ink, w);
                } else {
                    kit::clipped(p, pos2(cell.left(), y), s, 11.5, "", ink, w);
                }
            };
            match c {
                Col::Num => match row.on_deck {
                    Some(d) => {
                        words(p, pos2(left, y), Align2::LEFT_CENTER, &(d + 1).to_string(), 11.0, "semi", LOADED);
                    }
                    None => {
                        words(p, pos2(left, y), Align2::LEFT_CENTER, &(i + 1).to_string(), 10.5, "mono", MUTED);
                    }
                },
                Col::Art => {
                    art = Rect::from_min_size(pos2(left, y - 8.0), vec2(16.0, 16.0));
                    let tex = self.sleeves.of(&ctx, desk, r);
                    kit::sleeve(ui, p, art, tex, &r.initials(), col(theme::sleeve(r.id)), 1, ("club-row-art", r.id));
                }
                Col::Preview => {
                    let pr = Rect::from_min_size(pos2(left, y - 7.0), vec2(w, 14.0));
                    // a click previews it from there (in the headphones); again, stops it
                    let resp = ui.interact(pr, ui.scope_id().with(("club-preview", r.id)), Sense::click()).on_hover_cursor(egui::CursorIcon::PointingHand);
                    if resp.clicked()
                        && let Some(pos) = resp.interact_pointer_pos()
                    {
                        let at = ((pos.x - pr.left()) / pr.width()) as f64;
                        if !desk.play_preview(r, at) {
                            let why = match desk.preview_way() {
                                wo_deskcore::preview::PreviewWay::NotNow => "A preview needs headphones while a deck plays (Settings → Sound)",
                                _ => "This record cannot be previewed",
                            };
                            self.toasts.say(why, crate::ui::tokens::Tone::Warm);
                        }
                    }
                    if let Some((id, at)) = desk.previewing()
                        && id == r.id
                    {
                        let x = pr.left() + pr.width() * at as f32;
                        p.rect_filled(Rect::from_min_max(pr.min, pos2(x, pr.bottom())), CornerRadius::ZERO, Color32::from_rgba_unmultiplied(43, 196, 107, 40));
                        p.line_segment([pos2(x, pr.top()), pos2(x, pr.bottom())], Stroke::new(1.5, LOADED));
                        ui.ctx().request_repaint();
                    }
                    if let Some(pv) = desk.preview(r) {
                        let style = self.wave_style();
                        wave::columns(p, pr, &pv, pr.left(), pr.width() / pv.len().max(1) as f32, Columns { style, anchor: Anchor::Up(1.0), gain: 1.45, reflect: 0.0, heard: None });
                        // where it plays, on a deck
                        if let Some(d) = row.on_deck {
                            let v = &s.decks[d];
                            if v.length > 0.0 {
                                let x = pr.left() + pr.width() * (v.heard / v.length).clamp(0.0, 1.0) as f32;
                                p.line_segment([pos2(x, pr.top()), pos2(x, pr.bottom())], Stroke::new(1.0, Color32::WHITE));
                            }
                        }
                    }
                }
                Col::Title => text(&r.title, ink),
                Col::Artist => text(&r.artist, ink),
                Col::Album => text(&r.tags.album, ink),
                Col::Genre => text(&r.tags.genre, ink),
                Col::Bpm => text(&if r.bpm > 0.0 { format!("{:.2}", r.bpm) } else { String::new() }, ink),
                Col::Key => text(&r.key, ink),
                Col::Time => text(&if r.seconds > 0 { format!("{:02}:{:02}", r.seconds / 60, r.seconds % 60) } else { String::new() }, ink),
                Col::Rating => {
                    for k in 0..5 {
                        let filled = (k as u8) < r.tags.rating;
                        star(p, pos2(left + 6.0 + k as f32 * 13.0, y), 5.0, filled, if filled { TEXT } else { rgb(0x5A5A60) });
                    }
                }
                Col::Added => text(&r.tags.added, ink),
                Col::Fits => {
                    if row.on_deck.is_none() {
                        let bar = Rect::from_min_size(pos2(left, y - 2.0), vec2(w - 20.0, 4.0));
                        p.rect_filled(bar, CornerRadius::same(2), LINE);
                        let fit = row.fits as f32 / 100.0;
                        p.rect_filled(Rect::from_min_size(bar.min, vec2(bar.width() * fit, 4.0)), CornerRadius::same(2), if fit > 0.7 { LOADED } else { MUTED });
                        words(p, pos2(cell.right(), y), Align2::RIGHT_CENTER, &row.fits.to_string(), 10.0, "mono", MUTED);
                    }
                }
            }
        }
        art
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn columns_drop_as_the_browser_narrows() {
        let wide = ClubCols::for_width(1700.0);
        for c in [Col::Title, Col::Artist, Col::Album, Col::Genre, Col::Rating, Col::Added, Col::Preview, Col::Fits] {
            assert!(wide.has(c), "{c:?} at 1700");
        }
        let narrow = ClubCols::for_width(900.0);
        assert!(narrow.has(Col::Title) && narrow.has(Col::Bpm) && narrow.has(Col::Key));
        assert!(!narrow.has(Col::Added) && !narrow.has(Col::Rating));
        for cols in [&wide, &narrow] {
            let last = cols.0.last().unwrap();
            for w in cols.0.windows(2) {
                assert!(w[1].1 >= w[0].1 + w[0].2, "{:?} overlaps {:?}", w[0], w[1]);
            }
            assert!(last.1 + last.2 <= if std::ptr::eq(cols, &wide) { 1700.0 } else { 900.0 }, "the last column leaves: {last:?}");
        }
    }
}
