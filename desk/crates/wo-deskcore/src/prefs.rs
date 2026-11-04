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
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs { reduced_motion: false, still_backdrop: false, backdrop_light: 1.0 }
    }
}

impl Prefs {
    fn file() -> Option<PathBuf> {
        dirs::config_dir().map(|d| d.join("wetowl-desk").join("desk.json"))
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
