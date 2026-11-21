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
    /// rekordbox's layout shows its effect panel under the decks.
    pub club_fx: bool,
    /// The side panels one by one (C still folds them all away): the stage's picture, and
    /// the Auto DJ in the WetOwl's layout and in rekordbox's (which has none of its own).
    pub stage_panel: bool,
    pub auto_dj_panel: bool,
    pub club_auto_dj: bool,
    /// The crossfader off, as rekordbox's (Preferences → Controller → Mixer): both channels
    /// straight through, the channel faders mix. (Kept for older settings: the assign says it.)
    pub crossfader_off: bool,
    /// Each deck's side of the crossfader (rekordbox's crossfader assign).
    pub crossfader_assign: [XfSide; 2],
    /// Follow a set played in rekordbox: the Desk silent, the show with rekordbox's decks.
    pub follow_rekordbox: bool,
    /// Where rekordbox's audio is looked for (none: Music, Downloads and the Desktop).
    pub music_folders: Vec<PathBuf>,
    /// rkbx_link chosen by hand (the program or its folder).
    pub rkbx_link: Option<PathBuf>,
}

/// A deck's side of the crossfader: rekordbox's crossfader assign (neither side: THRU).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum XfSide {
    Left,
    Right,
    #[default]
    Thru,
}

impl XfSide {
    /// Deck 1 on the left, deck 2 on the right.
    pub const USUAL: [XfSide; 2] = [XfSide::Left, XfSide::Right];
}

impl Prefs {
    /// The crossfader assign kept (an older setting's crossfader off: both THRU).
    pub fn xf_assign(&self) -> [XfSide; 2] {
        if self.crossfader_off { [XfSide::Thru; 2] } else { self.crossfader_assign }
    }
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
        Prefs {
            reduced_motion: false,
            still_backdrop: false,
            backdrop_light: 1.0,
            disc_label: 0.31,
            wide_crate: false,
            wave_style: WaveStyle::ThreeBand,
            layout: DeskLayout::WetOwl,
            bar_groups: true,
            club_fx: true,
            stage_panel: true,
            auto_dj_panel: true,
            club_auto_dj: false,
            crossfader_off: false,
            crossfader_assign: XfSide::USUAL,
            follow_rekordbox: false,
            music_folders: vec![],
            rkbx_link: None,
        }
    }
}

impl Prefs {
    /// Where rekordbox's audio is looked for: the folders chosen, else the usual ones.
    pub fn music(&self) -> Vec<PathBuf> {
        if self.music_folders.is_empty() { wo_rekordbox::default_music_folders() } else { self.music_folders.clone() }
    }

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
