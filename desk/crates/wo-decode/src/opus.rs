//! Ogg Opus, which symphonia does not decode: the house's stems are one six-channel
//! Opus file (drums, bass and the rest, voice — each a stereo pair), written by ffmpeg
//! with channel mapping family 255 (six uncoupled mono streams). libopus's multistream
//! decoder takes every mapping family, so the record files a house might also keep as
//! Opus decode here too.
//!
//! Time as ffmpeg gives it (RFC 7845): the pre-skip cut off the front, and the end cut
//! to the last page's granule position, so a stem lines up sample for sample with the
//! record it came from.
use std::borrow::Cow;
use std::ffi::c_int;

use audiopus_sys as ffi;

use crate::Error;

/// Opus always decodes at 48 kHz.
pub const RATE: u32 = 48_000;

/// What the file's OpusHead says.
#[derive(Clone, Debug, PartialEq)]
pub struct Head {
    pub channels: usize,
    pub pre_skip: u64,
    /// Output gain, Q7.8 dB.
    pub gain: i16,
    pub family: u8,
    pub streams: u8,
    pub coupled: u8,
    pub mapping: Vec<u8>,
}

/// Whether `bytes` start an Ogg Opus stream.
pub fn sniff(bytes: &[u8]) -> bool {
    bytes.starts_with(b"OggS") && bytes.windows(8).take(200).any(|w| w == b"OpusHead")
}

/// The file's packets in order (one logical stream: the first serial seen), and the
/// last page's granule position. A packet within one page is borrowed; one spanning
/// pages is joined.
fn packets(bytes: &[u8]) -> Result<(Vec<Cow<'_, [u8]>>, i64), Error> {
    let bad = |w: &str| Error::Format(format!("Ogg: {w}"));
    let mut out: Vec<Cow<[u8]>> = vec![];
    let mut carry: Option<Vec<u8>> = None;
    let mut serial: Option<u32> = None;
    let mut granule = -1i64;
    let mut at = 0;
    while at + 27 <= bytes.len() {
        if &bytes[at..at + 4] != b"OggS" {
            return Err(bad("lost the page sync"));
        }
        let page_granule = i64::from_le_bytes(bytes[at + 6..at + 14].try_into().unwrap());
        let page_serial = u32::from_le_bytes(bytes[at + 14..at + 18].try_into().unwrap());
        let segs = bytes[at + 26] as usize;
        let table = bytes.get(at + 27..at + 27 + segs).ok_or_else(|| bad("a cut page"))?;
        let mut p = at + 27 + segs;
        let end = p + table.iter().map(|&s| s as usize).sum::<usize>();
        if end > bytes.len() {
            return Err(bad("a cut page"));
        }
        if *serial.get_or_insert(page_serial) == page_serial {
            if page_granule >= 0 {
                granule = page_granule;
            }
            let mut start = p;
            for &s in table {
                p += s as usize;
                if s < 255 {
                    out.push(match carry.take() {
                        Some(mut c) => {
                            c.extend_from_slice(&bytes[start..p]);
                            Cow::Owned(c)
                        }
                        None => Cow::Borrowed(&bytes[start..p]),
                    });
                    start = p;
                }
            }
            if start < p {
                carry.get_or_insert_with(Vec::new).extend_from_slice(&bytes[start..p]);
            }
        }
        at = end;
    }
    Ok((out, granule))
}

fn head(p: &[u8]) -> Result<Head, Error> {
    let bad = |w: &str| Error::Format(format!("OpusHead: {w}"));
    if p.len() < 19 || &p[..8] != b"OpusHead" {
        return Err(bad("missing"));
    }
    let channels = p[9] as usize;
    let pre_skip = u16::from_le_bytes([p[10], p[11]]) as u64;
    let gain = i16::from_le_bytes([p[16], p[17]]);
    let family = p[18];
    let (streams, coupled, mapping) = if family == 0 {
        if !(1..=2).contains(&channels) {
            return Err(bad("family 0 with more than two channels"));
        }
        (1, (channels - 1) as u8, (0..channels as u8).collect())
    } else {
        let m = p.get(21..21 + channels).ok_or_else(|| bad("no channel mapping"))?;
        (p[19], p[20], m.to_vec())
    };
    if channels == 0 || streams == 0 {
        return Err(bad("no channels"));
    }
    Ok(Head { channels, pre_skip, gain, family, streams, coupled, mapping })
}

struct Decoder(*mut ffi::OpusMSDecoder);

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { ffi::opus_multistream_decoder_destroy(self.0) }
    }
}

/// Decodes a whole Ogg Opus file: `each` gets interleaved f32 at 48 kHz and the width
/// (`head.channels`), pre-skip and end padding already cut. Returns the head and the
/// frames handed.
pub fn decode(bytes: &[u8], mut each: impl FnMut(&[f32], usize) -> Result<(), Error>) -> Result<(Head, u64), Error> {
    let (list, granule) = packets(bytes)?;
    let mut it = list.iter().map(|p| &p[..]);
    let head = head(it.next().ok_or_else(|| Error::Format("an empty Ogg file".into()))?)?;
    let tags = it.next();
    if !tags.is_some_and(|t| t.starts_with(b"OpusTags")) {
        return Err(Error::Format("OpusTags missing".into()));
    }
    let ch = head.channels;
    let mut err: c_int = 0;
    let dec = unsafe {
        ffi::opus_multistream_decoder_create(
            RATE as i32,
            ch as c_int,
            head.streams as c_int,
            head.coupled as c_int,
            head.mapping.as_ptr(),
            &mut err,
        )
    };
    if dec.is_null() || err != 0 {
        return Err(Error::Format(format!("libopus would not open it ({err})")));
    }
    let dec = Decoder(dec);
    let gain = if head.gain == 0 { 1.0 } else { 10f32.powf(head.gain as f32 / (20.0 * 256.0)) };
    // Frames there are: the last granule less the pre-skip (unknown → all decoded).
    let total = if granule >= 0 { (granule as u64).saturating_sub(head.pre_skip) } else { u64::MAX };
    let mut skip = head.pre_skip;
    let mut handed = 0u64;
    const MAX_FRAME: usize = 5760; // 120 ms at 48 kHz
    let mut pcm = vec![0f32; MAX_FRAME * ch];
    for packet in it {
        if packet.is_empty() {
            continue;
        }
        let n = unsafe {
            ffi::opus_multistream_decode_float(dec.0, packet.as_ptr(), packet.len() as i32, pcm.as_mut_ptr(), MAX_FRAME as c_int, 0)
        };
        if n < 0 {
            continue; // a damaged packet: skipped, as players do
        }
        let frames = n as usize;
        let from = (skip as usize).min(frames);
        skip -= from as u64;
        let take = ((frames - from) as u64).min(total - handed) as usize;
        if take == 0 {
            continue;
        }
        let slice = &mut pcm[from * ch..(from + take) * ch];
        if gain != 1.0 {
            slice.iter_mut().for_each(|s| *s *= gain);
        }
        each(slice, ch)?;
        handed += take as u64;
        if handed >= total {
            break;
        }
    }
    Ok((head, handed))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One page holding the given packets (lacing; a packet of 255·k bytes gets its 0).
    fn page(serial: u32, granule: i64, packets: &[&[u8]]) -> Vec<u8> {
        let mut table = vec![];
        let mut body = vec![];
        for p in packets {
            let mut n = p.len();
            while n >= 255 {
                table.push(255u8);
                n -= 255;
            }
            table.push(n as u8);
            body.extend_from_slice(p);
        }
        let mut v = b"OggS".to_vec();
        v.push(0);
        v.push(0);
        v.extend_from_slice(&granule.to_le_bytes());
        v.extend_from_slice(&serial.to_le_bytes());
        v.extend_from_slice(&0u32.to_le_bytes());
        v.extend_from_slice(&0u32.to_le_bytes());
        v.push(table.len() as u8);
        v.extend_from_slice(&table);
        v.extend_from_slice(&body);
        v
    }

    #[test]
    fn packets_come_out_whole_and_in_order() {
        let long = vec![7u8; 300];
        let mut f = page(1, 0, &[b"one", &long]);
        f.extend(page(2, 5, &[b"other stream"]));
        f.extend(page(1, 960, &[b"three"]));
        let (b, g) = packets(&f).unwrap();
        assert!(b.iter().all(|p| matches!(p, Cow::Borrowed(_))));
        assert_eq!(b, vec![&b"one"[..], &long[..], &b"three"[..]]);
        assert_eq!(g, 960);
    }

    #[test]
    fn a_packet_across_pages_is_joined() {
        // 255 bytes then a page break: the packet goes on in the next page.
        let first = vec![1u8; 255];
        let mut a = b"OggS".to_vec();
        a.extend_from_slice(&[0, 0]);
        a.extend_from_slice(&(-1i64).to_le_bytes());
        a.extend_from_slice(&1u32.to_le_bytes());
        a.extend_from_slice(&[0; 8]);
        a.push(1);
        a.push(255);
        a.extend_from_slice(&first);
        a.extend(page(1, 10, &[b"tail", b"next"]));
        let (b, g) = packets(&a).unwrap();
        let mut want = first.clone();
        want.extend_from_slice(b"tail");
        assert_eq!(b, vec![&want[..], &b"next"[..]]);
        assert_eq!(g, 10);
    }

    #[test]
    fn heads_of_both_families() {
        let mut h = b"OpusHead".to_vec();
        h.extend_from_slice(&[1, 2]);
        h.extend_from_slice(&312u16.to_le_bytes());
        h.extend_from_slice(&48000u32.to_le_bytes());
        h.extend_from_slice(&0i16.to_le_bytes());
        h.push(0);
        let s = head(&h).unwrap();
        assert_eq!((s.channels, s.pre_skip, s.streams, s.coupled, s.mapping), (2, 312, 1, 1, vec![0, 1]));

        let mut h = b"OpusHead".to_vec();
        h.extend_from_slice(&[1, 6]);
        h.extend_from_slice(&312u16.to_le_bytes());
        h.extend_from_slice(&48000u32.to_le_bytes());
        h.extend_from_slice(&0i16.to_le_bytes());
        h.extend_from_slice(&[255, 6, 0, 0, 1, 2, 3, 4, 5]);
        let s = head(&h).unwrap();
        assert_eq!((s.channels, s.family, s.streams, s.coupled), (6, 255, 6, 0));
    }
}
