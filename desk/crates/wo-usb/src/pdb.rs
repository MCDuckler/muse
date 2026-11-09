//! rekordbox's device database (`PIONEER/rekordbox/export.pdb`, "DeviceSQL"), read.
//!
//! The file is fixed-size pages. Page 0 lists the tables, each a chain of pages; a page
//! has a 40-byte header, rows growing from the front and, from the back, groups of up to
//! sixteen row offsets with a bit each saying whether the row is still there. All little
//! endian. Layout as reverse-engineered by Deep Symmetry (djl-analysis.deepsymmetry.org)
//! and the rekordcrate project; only what the Desk uses is read.
use std::collections::HashMap;

/// A table's kind, as page 0 numbers them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Table {
    Tracks = 0,
    Genres = 1,
    Artists = 2,
    Albums = 3,
    Labels = 4,
    Keys = 5,
    Colors = 6,
    PlaylistTree = 7,
    PlaylistEntries = 8,
    Artwork = 13,
}

const PAGE_HEADER: usize = 0x28;

/// What is wrong with a database file.
#[derive(Debug)]
pub struct Bad(pub String);

impl std::fmt::Display for Bad {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

fn bad<T>(why: impl Into<String>) -> Result<T, Bad> {
    Err(Bad(why.into()))
}

/// Little-endian reads that fail rather than panic on a short or damaged file.
pub(crate) trait Le {
    fn u8_at(&self, at: usize) -> Option<u8>;
    fn u16_at(&self, at: usize) -> Option<u16>;
    fn u32_at(&self, at: usize) -> Option<u32>;
}

impl Le for [u8] {
    fn u8_at(&self, at: usize) -> Option<u8> {
        self.get(at).copied()
    }
    fn u16_at(&self, at: usize) -> Option<u16> {
        Some(u16::from_le_bytes(self.get(at..at + 2)?.try_into().ok()?))
    }
    fn u32_at(&self, at: usize) -> Option<u32> {
        Some(u32::from_le_bytes(self.get(at..at + 4)?.try_into().ok()?))
    }
}

/// The whole file, and where each table's pages start and end.
pub struct Pdb<'a> {
    bytes: &'a [u8],
    page_size: usize,
    tables: HashMap<u32, (u32, u32)>,
}

impl<'a> Pdb<'a> {
    pub fn new(bytes: &'a [u8]) -> Result<Pdb<'a>, Bad> {
        let (Some(0), Some(page_size), Some(n)) = (bytes.u32_at(0), bytes.u32_at(4), bytes.u32_at(8)) else {
            return bad("not a rekordbox database (header)");
        };
        if !(512..=65536).contains(&page_size) || n > 64 {
            return bad(format!("not a rekordbox database (page size {page_size}, {n} tables)"));
        }
        let mut tables = HashMap::new();
        for i in 0..n as usize {
            let at = 0x1c + i * 16;
            let (Some(kind), Some(first), Some(last)) = (bytes.u32_at(at), bytes.u32_at(at + 8), bytes.u32_at(at + 12)) else {
                return bad("the table list runs past the end of the file");
            };
            tables.insert(kind, (first, last));
        }
        Ok(Pdb { bytes, page_size: page_size as usize, tables })
    }

    /// Every live row of a table: the bytes from the row's start to its page's end
    /// (strings sit at offsets from the row's start).
    pub fn rows(&self, table: Table) -> Vec<&'a [u8]> {
        let mut out = vec![];
        let Some(&(first, last)) = self.tables.get(&(table as u32)) else { return out };
        let mut index = first;
        // a chain is never longer than the file: a guard against a damaged one that loops
        for _ in 0..=self.bytes.len() / self.page_size {
            let start = index as usize * self.page_size;
            let Some(page) = self.bytes.get(start..start + self.page_size) else { break };
            if page.u32_at(4) == Some(index) && page.u32_at(8) == Some(table as u32) {
                out.extend(self.page_rows(page));
            }
            let Some(next) = page.u32_at(12) else { break };
            if index == last {
                break;
            }
            index = next;
        }
        out
    }

    fn page_rows(&self, page: &'a [u8]) -> Vec<&'a [u8]> {
        let flags = page.u8_at(0x1b).unwrap_or(0);
        let small = page.u8_at(0x18).unwrap_or(0) as u16;
        let large = page.u16_at(0x22).unwrap_or(0);
        let n = if large > small && large != 0x1fff { large } else { small } as usize;
        if n == 0 || flags & 0x40 != 0 {
            return vec![];
        }
        let heap = &page[PAGE_HEADER..];
        let mut out = vec![];
        for g in 0..n.div_ceil(16) {
            // group g ends 36 bytes before group g-1: [16 offsets, backwards][present bits][?]
            let Some(end) = page.len().checked_sub(36 * g) else { break };
            let Some(present) = page.u16_at(end - 4) else { break };
            for i in 0..16 {
                if present & (1 << i) == 0 {
                    continue;
                }
                let Some(ofs) = page.u16_at(end - 4 - 2 * (i + 1)) else { continue };
                if let Some(row) = heap.get(ofs as usize..) {
                    out.push(row);
                }
            }
        }
        out
    }
}

/// A DeviceSQL string at `at` in `row`: short ASCII (odd first byte: its length), long
/// ASCII (0x40) or long UTF-16LE (0x90). An ISRC (0x90 then 0x03) reads as its ASCII.
pub(crate) fn string(row: &[u8], at: usize) -> String {
    let Some(kind) = row.u8_at(at) else { return String::new() };
    if kind & 1 == 1 {
        let len = (kind >> 1) as usize;
        return row.get(at + 1..at + len.max(1)).map(latin).unwrap_or_default();
    }
    let Some(len) = row.u16_at(at + 1).map(|l| l as usize) else { return String::new() };
    let Some(body) = row.get(at + 4..at + len.max(4)) else { return String::new() };
    match kind {
        0x40 => latin(body),
        0x90 if body.first() == Some(&3) => latin(body[1..].split(|&b| b == 0).next().unwrap_or(&[])),
        0x90 => {
            let units: Vec<u16> = body.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect();
            String::from_utf16_lossy(&units).trim_end_matches('\0').to_owned()
        }
        _ => String::new(),
    }
}

/// ASCII rows are bytes; anything past 0x7F read as Latin-1 rather than refused.
fn latin(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.trim_end_matches('\0').to_owned(),
        Err(_) => b.iter().map(|&c| c as char).collect::<String>().trim_end_matches('\0').to_owned(),
    }
}

/// A string whose offset (from the row's start) is a u16 at `ofs_at`.
pub(crate) fn string_at_u16(row: &[u8], ofs_at: usize) -> String {
    row.u16_at(ofs_at).map(|o| string(row, o as usize)).unwrap_or_default()
}

/// A named row whose name sits at a near (u8) or, for the far subtype, a u16 offset.
pub(crate) fn near_far_name(row: &[u8], far: bool, near_at: usize, far_at: usize) -> String {
    let ofs = if far { row.u16_at(far_at).map(|o| o as usize) } else { row.u8_at(near_at).map(|o| o as usize) };
    ofs.map(|o| string(row, o)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strings_read_in_each_of_their_forms() {
        // short ASCII: header (len + 1) << 1 | 1
        assert_eq!(string(&[0x9, b'f', b'o', b'o'], 0), "foo");
        assert_eq!(string(&[0x3], 0), "");
        // long ASCII
        let mut long = vec![0x40, 9, 0, 0];
        long.extend_from_slice(b"hello");
        assert_eq!(string(&long, 0), "hello");
        // long UTF-16LE: "I ❤ Rust"
        let utf16 = [0x90, 0x14, 0x00, 0x00, 0x49, 0x00, 0x20, 0x00, 0x64, 0x27, 0x20, 0x00, 0x52, 0x00, 0x75, 0x00, 0x73, 0x00, 0x74, 0x00];
        assert_eq!(string(&utf16, 0), "I ❤ Rust");
        // an ISRC: 0x90, 0x03, ASCII, NUL
        let mut isrc = vec![0x90, 18, 0, 0, 3];
        isrc.extend_from_slice(b"GBAYE0601498\0");
        assert_eq!(string(&isrc, 0), "GBAYE0601498");
        // past the end: nothing, no panic
        assert_eq!(string(&[0x40, 200, 0, 0, b'x'], 0), "");
        assert_eq!(string(&[], 3), "");
    }

    #[test]
    fn a_page_with_a_deleted_row_gives_only_the_live_ones() {
        // one 4096-byte table page holding three rows, the middle one deleted
        let ps = 4096usize;
        let mut f = vec![0u8; ps * 2];
        f[4..8].copy_from_slice(&(ps as u32).to_le_bytes());
        f[8..12].copy_from_slice(&1u32.to_le_bytes());
        // table 0 (tracks): first page 1, last page 1
        f[0x1c + 8..0x1c + 12].copy_from_slice(&1u32.to_le_bytes());
        f[0x1c + 12..0x1c + 16].copy_from_slice(&1u32.to_le_bytes());
        let p = ps;
        f[p + 4..p + 8].copy_from_slice(&1u32.to_le_bytes());
        f[p + 8..p + 12].copy_from_slice(&0u32.to_le_bytes());
        f[p + 12..p + 16].copy_from_slice(&9u32.to_le_bytes());
        f[p + 0x18] = 3; // rows
        f[p + 0x1b] = 0x24; // a data page
        for (i, b) in b"abc".iter().enumerate() {
            f[p + PAGE_HEADER + i * 4] = *b;
            let at = p + ps - 4 - 2 * (i + 1);
            f[at..at + 2].copy_from_slice(&((i * 4) as u16).to_le_bytes());
        }
        f[p + ps - 4..p + ps - 2].copy_from_slice(&0b101u16.to_le_bytes());
        let db = Pdb::new(&f).unwrap();
        let rows: Vec<u8> = db.rows(Table::Tracks).iter().map(|r| r[0]).collect();
        assert_eq!(rows, vec![b'a', b'c']);
        assert!(db.rows(Table::Keys).is_empty());
    }

    #[test]
    fn a_file_that_is_not_a_database_is_refused() {
        assert!(Pdb::new(b"hello world, not a pdb at all").is_err());
        assert!(Pdb::new(&[]).is_err());
    }
}
