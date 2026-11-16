//! A clip's proxy (`proxy.wov`): every frame a JPEG of its own, so any frame is as quick to
//! get as the next one — the stage jumps, stutters and runs backwards through it.
//!
//!   "WOV1"  u32 width  u32 height  f64 fps  u32 frames  u64 the index's offset
//!   the frames' JPEGs, one after another
//!   the index: per frame u64 offset, u32 length
//!
//! (little-endian; the header is written again once the index is known.)
use std::fs::File;
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;

const MAGIC: &[u8; 4] = b"WOV1";
const HEADER: u64 = 4 + 4 + 4 + 8 + 4 + 8;

/// A proxy being written.
pub struct ProxyWriter {
    out: BufWriter<File>,
    at: u64,
    index: Vec<(u64, u32)>,
    w: u32,
    h: u32,
    fps: f64,
}

impl ProxyWriter {
    pub fn create(path: &Path, fps: f64) -> std::io::Result<ProxyWriter> {
        let mut out = BufWriter::new(File::create(path)?);
        out.write_all(&[0u8; HEADER as usize])?;
        Ok(ProxyWriter { out, at: HEADER, index: vec![], w: 0, h: 0, fps })
    }

    /// One frame's JPEG (its size read off it).
    pub fn push(&mut self, jpeg: &[u8]) -> std::io::Result<()> {
        if self.index.is_empty()
            && let Some((w, h)) = jpeg_size(jpeg)
        {
            (self.w, self.h) = (w, h);
        }
        self.out.write_all(jpeg)?;
        self.index.push((self.at, jpeg.len() as u32));
        self.at += jpeg.len() as u64;
        Ok(())
    }

    pub fn frames(&self) -> usize {
        self.index.len()
    }

    pub fn size(&self) -> (u32, u32) {
        (self.w, self.h)
    }

    /// The index after the frames, the header told where it is.
    pub fn finish(mut self) -> std::io::Result<()> {
        let index_at = self.at;
        for (o, l) in &self.index {
            self.out.write_all(&o.to_le_bytes())?;
            self.out.write_all(&l.to_le_bytes())?;
        }
        self.out.seek(SeekFrom::Start(0))?;
        self.out.write_all(MAGIC)?;
        self.out.write_all(&self.w.to_le_bytes())?;
        self.out.write_all(&self.h.to_le_bytes())?;
        self.out.write_all(&self.fps.to_le_bytes())?;
        self.out.write_all(&(self.index.len() as u32).to_le_bytes())?;
        self.out.write_all(&index_at.to_le_bytes())?;
        self.out.flush()?;
        self.out.get_ref().sync_all()
    }
}

/// A proxy to read frames from.
pub struct Proxy {
    file: File,
    pub w: u32,
    pub h: u32,
    pub fps: f64,
    index: Vec<(u64, u32)>,
}

impl Proxy {
    pub fn open(path: &Path) -> std::io::Result<Proxy> {
        let bad = |what: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{}: {what}", path.display()));
        let mut file = File::open(path)?;
        let mut h = [0u8; HEADER as usize];
        file.read_exact(&mut h)?;
        if &h[0..4] != MAGIC {
            return Err(bad("not a proxy"));
        }
        let u32_at = |i: usize| u32::from_le_bytes(h[i..i + 4].try_into().unwrap());
        let (w, hh) = (u32_at(4), u32_at(8));
        let fps = f64::from_le_bytes(h[12..20].try_into().unwrap());
        let n = u32_at(20) as usize;
        let index_at = u64::from_le_bytes(h[24..32].try_into().unwrap());
        let len = file.metadata()?.len();
        if index_at < HEADER || index_at + n as u64 * 12 > len {
            return Err(bad("its index is not all there"));
        }
        file.seek(SeekFrom::Start(index_at))?;
        let mut raw = vec![0u8; n * 12];
        file.read_exact(&mut raw)?;
        let index = raw.as_chunks::<12>().0.iter().map(|c| (u64::from_le_bytes(c[0..8].try_into().unwrap()), u32::from_le_bytes(c[8..12].try_into().unwrap()))).collect();
        Ok(Proxy { file, w, h: hh, fps, index })
    }

    pub fn frames(&self) -> usize {
        self.index.len()
    }

    /// Frame `i`'s JPEG (the last for one past the end).
    pub fn jpeg(&mut self, i: usize) -> std::io::Result<Vec<u8>> {
        let Some(&(o, l)) = self.index.get(i.min(self.index.len().saturating_sub(1))) else {
            return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no frames"));
        };
        self.file.seek(SeekFrom::Start(o))?;
        let mut b = vec![0u8; l as usize];
        self.file.read_exact(&mut b)?;
        Ok(b)
    }

    /// Frame `i` as RGBA.
    pub fn rgba(&mut self, i: usize) -> std::io::Result<Picture> {
        let j = self.jpeg(i)?;
        decode(&j).ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("frame {i} would not decode")))
    }
}

/// A decoded frame.
#[derive(Clone, Debug)]
pub struct Picture {
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
}

/// A JPEG as RGBA.
pub fn decode(jpeg: &[u8]) -> Option<Picture> {
    use zune_core::colorspace::ColorSpace;
    use zune_core::options::DecoderOptions;
    let opts = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut d = zune_jpeg::JpegDecoder::new_with_options(zune_core::bytestream::ZCursor::new(jpeg), opts);
    let rgba = d.decode().ok()?;
    let (w, h) = d.dimensions()?;
    (rgba.len() == w * h * 4).then_some(Picture { w: w as u32, h: h as u32, rgba })
}

/// A JPEG's width and height (its frame header).
pub fn jpeg_size(j: &[u8]) -> Option<(u32, u32)> {
    let mut i = 2;
    while i + 9 < j.len() {
        if j[i] != 0xFF {
            return None;
        }
        let m = j[i + 1];
        let len = u16::from_be_bytes([j[i + 2], j[i + 3]]) as usize;
        if matches!(m, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
            let h = u16::from_be_bytes([j[i + 5], j[i + 6]]) as u32;
            let w = u16::from_be_bytes([j[i + 7], j[i + 8]]) as u32;
            return Some((w, h));
        }
        i += 2 + len;
    }
    None
}

/// The JPEGs in a stream of them, one after another (ffmpeg's image2pipe): each cut where
/// its end-of-image marker is — found by walking its segments to the scan, then through the
/// scan's data (where 0xFF is always followed by 0x00 or a restart marker).
#[derive(Default)]
pub struct JpegSplitter {
    buf: Vec<u8>,
}

impl JpegSplitter {
    pub fn feed(&mut self, data: &[u8], mut each: impl FnMut(&[u8])) {
        self.buf.extend_from_slice(data);
        let mut start = 0;
        while let Some(end) = jpeg_end(&self.buf[start..]) {
            each(&self.buf[start..start + end]);
            start += end;
        }
        self.buf.drain(..start);
    }
}

/// Where the JPEG at the start of `b` ends (one past its EOI), if all of it is there.
fn jpeg_end(b: &[u8]) -> Option<usize> {
    if b.len() < 4 || b[0] != 0xFF || b[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    // the segments before the scan
    loop {
        if i + 4 > b.len() {
            return None;
        }
        if b[i] != 0xFF {
            return None;
        }
        let m = b[i + 1];
        if m == 0xFF {
            i += 1;
            continue;
        }
        let len = u16::from_be_bytes([b[i + 2], b[i + 3]]) as usize;
        i += 2 + len;
        if m == 0xDA {
            break;
        }
    }
    // the scan's data, to the marker after it
    while i + 1 < b.len() {
        if b[i] == 0xFF {
            let m = b[i + 1];
            if m == 0xD9 {
                return Some(i + 2);
            }
            if m != 0x00 && !(0xD0..=0xD7).contains(&m) && m != 0xFF {
                // another scan (progressive) or a table: walk on from it
                if i + 4 > b.len() {
                    return None;
                }
                let len = u16::from_be_bytes([b[i + 2], b[i + 3]]) as usize;
                i += 2 + len;
                continue;
            }
            i += 2;
            continue;
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A JPEG's shape (16×8): its headers and a scan with a stuffed 0xFF and a restart
    /// marker — what the splitter walks, not a picture (the import's test decodes real ones).
    fn tiny() -> Vec<u8> {
        let mut j = vec![0xFF, 0xD8];
        // a frame header: 8 high, 16 wide
        j.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00]);
        // a scan header, then data with a stuffed 0xFF and a restart marker
        j.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
        j.extend_from_slice(&[0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]);
        j.extend_from_slice(&[0xFF, 0xD9]);
        j
    }

    #[test]
    fn a_stream_splits_into_its_pictures_however_it_comes() {
        let one = tiny();
        let mut stream = vec![];
        for _ in 0..3 {
            stream.extend_from_slice(&one);
        }
        for chunk in [1usize, 3, 7, 1000] {
            let mut s = JpegSplitter::default();
            let mut got = vec![];
            for c in stream.chunks(chunk) {
                s.feed(c, |j| got.push(j.to_vec()));
            }
            assert_eq!(got.len(), 3, "chunks of {chunk}");
            assert!(got.iter().all(|g| *g == one));
        }
        assert_eq!(jpeg_size(&one), Some((16, 8)));
    }

    #[test]
    fn a_proxy_reads_back_what_was_written() {
        let dir = std::env::temp_dir().join(format!("wo-video-proxy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("p.wov");
        let mut w = ProxyWriter::create(&p, 25.0).unwrap();
        let a = tiny();
        let mut b = tiny();
        b.insert(b.len() - 2, 0x77);
        w.push(&a).unwrap();
        w.push(&b).unwrap();
        assert_eq!(w.size(), (16, 8));
        w.finish().unwrap();
        let mut r = Proxy::open(&p).unwrap();
        assert_eq!((r.w, r.h, r.fps, r.frames()), (16, 8, 25.0, 2));
        assert_eq!(r.jpeg(1).unwrap(), b);
        assert_eq!(r.jpeg(0).unwrap(), a);
        assert_eq!(r.jpeg(9).unwrap(), b, "past the end: the last");
        std::fs::remove_dir_all(&dir).ok();
    }
}
