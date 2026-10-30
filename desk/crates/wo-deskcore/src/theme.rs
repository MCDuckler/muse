//! design/tokens.json as Rust constants (sRGB, alpha last). The test keeps them equal.
pub type Rgba = [u8; 4];

const fn hex(v: u32) -> Rgba {
    [(v >> 16) as u8, (v >> 8) as u8, v as u8, 255]
}

pub const GROUND: Rgba = hex(0x0A0B0D);
pub const PANEL: Rgba = hex(0x121317);
pub const RAISED: Rgba = hex(0x1B1D23);
pub const LINE: Rgba = hex(0x23262D);
pub const EDGE: Rgba = hex(0x2B2E36);
pub const TEXT: Rgba = hex(0xECEDEF);
pub const SOFT: Rgba = hex(0xC9CCD3);
pub const MUTED: Rgba = hex(0xA1A5AE);
pub const FAINT: Rgba = hex(0x80848E);
pub const FAINT_ON_GLASS: Rgba = hex(0x8E929C);
pub const CAP: Rgba = hex(0xD9DBE0);
pub const DECK_A: Rgba = hex(0x46B4FF);
pub const DECK_A_TINT: Rgba = hex(0xA9D9FF);
pub const DECK_B: Rgba = hex(0xFF9F3D);
pub const DECK_B_TINT: Rgba = hex(0xFFD3A6);
pub const RED: Rgba = hex(0xE83328);
pub const OK: Rgba = hex(0x5BD08F);
pub const WARM: Rgba = hex(0xF6C445);
pub const HOT: Rgba = hex(0xFF5A4E);
pub const HIGH: Rgba = hex(0xF4F5F7);
pub const PAD_INTRO: Rgba = hex(0x4FD1C5);
pub const PAD_BREAK: Rgba = hex(0xA78BFA);

/// Glass: panels 66 % and dense ones 86 % dark, edges 10 % white.
pub const GLASS_PANEL: Rgba = [16, 17, 22, 168];
pub const GLASS_DENSE: Rgba = [11, 12, 16, 219];
pub const GLASS_EDGE: Rgba = [255, 255, 255, 26];
pub const GLASS_HIGHLIGHT: Rgba = [255, 255, 255, 18];

pub const DECKS: [Rgba; 2] = [DECK_A, DECK_B];
pub const TINTS: [Rgba; 2] = [DECK_A_TINT, DECK_B_TINT];

/// A pad's colour by kind.
pub fn pad(kind: crate::PadKind) -> Rgba {
    match kind {
        crate::PadKind::Intro => PAD_INTRO,
        crate::PadKind::Drop => RED,
        crate::PadKind::Break => PAD_BREAK,
        crate::PadKind::Out => WARM,
    }
}

/// A crate sleeve's colour by record id.
pub fn sleeve(id: i64) -> Rgba {
    [hex(0x2E3B4C), hex(0x4B2E3B), hex(0x2E4B3F), hex(0x4B442E), hex(0x3B2E4B), hex(0x2E4548)][id.rem_euclid(6) as usize]
}

/// The fonts, cut from the variable ones at the tokens' settings (design/fonts, OFL).
pub mod fonts {
    pub const INTER: &[u8] = include_bytes!("../../../design/fonts/Inter-Regular.ttf");
    pub const INTER_SEMI: &[u8] = include_bytes!("../../../design/fonts/Inter-SemiBold.ttf");
    pub const MONO: &[u8] = include_bytes!("../../../design/fonts/JetBrainsMono-Regular.ttf");
    pub const MONO_SEMI: &[u8] = include_bytes!("../../../design/fonts/JetBrainsMono-SemiBold.ttf");
    pub const LABEL: &[u8] = include_bytes!("../../../design/fonts/Archivo-CondensedSemiBold.ttf");
    pub const MARK: &[u8] = include_bytes!("../../../design/fonts/Archivo-MarkBlack.ttf");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_constants_are_the_tokens() {
        let tokens = include_str!("../../../design/tokens.json");
        let get = |name: &str| -> Rgba {
            let i = tokens.find(&format!("\"{name}\": \"#")).unwrap_or_else(|| panic!("no {name}"));
            let h = &tokens[i + name.len() + 6..i + name.len() + 12];
            hex(u32::from_str_radix(h, 16).unwrap())
        };
        for (name, v) in [
            ("ground", GROUND), ("panel", PANEL), ("raised", RAISED), ("line", LINE), ("edge", EDGE), ("text", TEXT),
            ("soft", SOFT), ("muted", MUTED), ("faint", FAINT), ("faintOnGlass", FAINT_ON_GLASS), ("cap", CAP),
            ("deckA", DECK_A), ("deckATint", DECK_A_TINT), ("deckB", DECK_B), ("deckBTint", DECK_B_TINT), ("red", RED),
            ("ok", OK), ("warm", WARM), ("hot", HOT), ("high", HIGH), ("padIntro", PAD_INTRO), ("padBreak", PAD_BREAK),
        ] {
            assert_eq!(get(name), v, "{name}");
        }
        assert!(tokens.contains("\"panel\": \"rgba(16,17,22,0.66)\"") && (0.66f32 * 255.0).round() as u8 == GLASS_PANEL[3]);
        assert!(tokens.contains("\"dense\": \"rgba(11,12,16,0.86)\"") && (0.86f32 * 255.0).round() as u8 == GLASS_DENSE[3]);
    }
}
