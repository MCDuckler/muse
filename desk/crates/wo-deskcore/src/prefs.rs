//! The Desk's own settings (the settings window): kept between runs in the config folder.
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Prefs {
    /// Fades for motion, springs instant.
    pub reduced_motion: bool,
    /// The still stage frame behind the glass, not the live stage.
    pub still_backdrop: bool,
    /// How much of the stage's light comes through the glass (0.5 dim .. 1.5 bright).
    pub backdrop_light: f32,
    /// How much of a record's radius its label covers (v1's; 0.18 .. 0.92).
    pub disc_label: f32,
    /// The booth's side panels (the stage and the Auto DJ) folded away: the crate wide.
    pub wide_crate: bool,
    /// How the waveforms are coloured (rekordbox's three, or the WetOwl's own).
    pub wave_style: WaveStyle,
    /// The booth's layout: the WetOwl's own, or rekordbox's (Club).
    pub layout: DeskLayout,
    /// The four-bar groups marked and numbered on the waveforms (the WetOwl's own
    /// marks, over rekordbox's grid).
    pub bar_groups: bool,
}

/// rekordbox's waveform colours (Preferences → View → Waveform color), and the Desk's own.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum WaveStyle {
    #[default]
    ThreeBand,
    Rgb,
    Blue,
    /// The deck's own colour, mirrored and soft (the Desk's look before rekordbox's).
    WetOwl,
}

impl WaveStyle {
    pub const ALL: [WaveStyle; 4] = [WaveStyle::ThreeBand, WaveStyle::Rgb, WaveStyle::Blue, WaveStyle::WetOwl];

    pub fn name(self) -> &'static str {
        match self {
            WaveStyle::ThreeBand => "3Band",
            WaveStyle::Rgb => "RGB",
            WaveStyle::Blue => "Blue",
            WaveStyle::WetOwl => "WetOwl",
        }
    }
}

/// The booth's layout.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum DeskLayout {
    #[default]
    WetOwl,
    /// rekordbox's PERFORMANCE layout (2 Deck Horizontal).
    Club,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs { reduced_motion: false, still_backdrop: false, backdrop_light: 1.0, disc_label: 0.31, wide_crate: false, wave_style: WaveStyle::ThreeBand, layout: DeskLayout::WetOwl, bar_groups: true }
    }
}

impl Prefs {
    fn file() -> Option<PathBuf> {
        wo_house::folders::config().map(|d| d.join("wetowl-desk").join("desk.json"))
    }

    pub fn read() -> Prefs {
        Self::file().and_then(|f| std::fs::read_to_string(f).ok()).and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(f) = Self::file() else { return };
        let _ = std::fs::create_dir_all(f.parent().unwrap());
        if let Err(e) = std::fs::write(&f, serde_json::to_string_pretty(self).unwrap()) {
            eprintln!("desk: the settings into {}: {e}", f.display());
        }
    }
}
