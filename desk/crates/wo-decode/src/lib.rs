//! Records decoded in-process for the engine: symphonia (AAC/M4A, MP3, FLAC, WAV,
//! Ogg Vorbis) and libopus (Ogg Opus: the house's six-channel stems, see [`opus`]) to
//! stereo — or to the stems' six channels — resampled to the engine's rate by rubato's synchronous FFT
//! resampler, 16-bit, streamed into a sink as it goes — so a deck can start before
//! the record is all in. (v1 piped every record through an ffmpeg process.)
//!
//! Time must come out exact: a beat grid made on the house counts seconds from the
//! record's first sample as ffmpeg decodes it. So the resampler's own delay is cut off
//! the front, the end is flushed to exactly in × ratio frames, and an AAC record's
//! encoder priming and padding are cut the way ffmpeg cuts them (see [`edits`]).
use std::fs::File;
use std::path::Path;

use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Indexing, Resampler};
use symphonia::core::codecs::CodecParameters;
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

mod edits;
pub mod opus;
pub use edits::Edit;

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    /// Not a record symphonia can read: what it said.
    Format(String),
    /// The sink would not take more (the engine out of memory).
    Sink(String),
    Resample(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "{e}"),
            Error::Format(e) => write!(f, "can't read the record: {e}"),
            Error::Sink(e) => write!(f, "{e}"),
            Error::Resample(e) => write!(f, "resampling: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Io(e)
    }
}

/// Where decoded frames go: interleaved (stereo, or the stems' six), 16-bit, at the
/// rate asked.
pub trait Sink {
    fn take(&mut self, pcm: &[i16]) -> Result<(), Error>;
}

impl Sink for Vec<i16> {
    fn take(&mut self, pcm: &[i16]) -> Result<(), Error> {
        self.extend_from_slice(pcm);
        Ok(())
    }
}

impl Sink for wo_engine::Source {
    fn take(&mut self, pcm: &[i16]) -> Result<(), Error> {
        self.append(pcm).map_err(|e| Error::Sink(e.to_string()))
    }
}

/// What was decoded.
#[derive(Clone, Debug, PartialEq)]
pub struct Info {
    /// The record's own rate and channels.
    pub rate_in: u32,
    pub channels_in: usize,
    /// Frames decoded at the record's rate, after the priming was cut.
    pub frames_in: u64,
    /// Frames handed to the sink at the rate asked.
    pub frames_out: u64,
    /// Channels handed to the sink: 2, or 6 for stems.
    pub channels_out: usize,
    /// The MP4 edit honoured: priming cut off the front, padding off the end.
    pub edit: Edit,
}

impl Info {
    pub fn seconds(&self) -> f64 {
        self.frames_in as f64 / self.rate_in as f64
    }
}

/// Decodes `path` into `sink` at `rate` frames a second, as stereo (stems summed back
/// into the record).
pub fn decode(path: &Path, rate: u32, sink: &mut impl Sink) -> Result<Info, Error> {
    decode_as(path, rate, sink, 2, true)
}

/// Decodes `path` as rekordbox and the CDJs do: an MP3's start-up (the encoder's delay
/// and the decoder's, 1105 frames for LAME) kept rather than cut, so rekordbox's beat
/// grid and cues — times from that start — land on the beats. (Measured on a stick's 69
/// MP3s: cut, the kicks came ~25 ms before rekordbox's beats; its WAVs were on them.)
pub fn decode_as_rekordbox(path: &Path, rate: u32, sink: &mut impl Sink) -> Result<Info, Error> {
    decode_as(path, rate, sink, 2, false)
}

/// Decodes a stems file (six channels: drums, bass and the rest, voice) into `sink` as
/// six channels. Anything else is an error: a deck must not take a record for stems.
pub fn decode_stems(path: &Path, rate: u32, sink: &mut impl Sink) -> Result<Info, Error> {
    decode_as(path, rate, sink, 6, true)
}

fn decode_as(path: &Path, rate: u32, sink: &mut impl Sink, out_ch: usize, gapless: bool) -> Result<Info, Error> {
    let mut first = [0u8; 512];
    let n = {
        use std::io::Read;
        File::open(path)?.read(&mut first)?
    };
    if opus::sniff(&first[..n]) {
        return decode_opus(path, rate, sink, out_ch);
    }
    if out_ch != 2 {
        return Err(Error::Format("not a stems file (Ogg Opus, six channels)".into()));
    }
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let mut format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .map_err(|e| Error::Format(e.to_string()))?;
    let track = format.default_track(TrackType::Audio).ok_or_else(|| Error::Format("no audio in it".into()))?;
    let track_id = track.id;
    let params = match track.codec_params.as_ref() {
        Some(CodecParameters::Audio(a)) => a.clone(),
        _ => return Err(Error::Format("no audio codec parameters".into())),
    };
    let rate_in = params.sample_rate.ok_or_else(|| Error::Format("no sample rate".into()))?;
    let edit = edits::read(path, rate_in);
    let mut skip = edit.skip;
    let mut keep = edit.keep.unwrap_or(u64::MAX);
    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(&params, &AudioDecoderOptions::default().gapless(gapless))
        .map_err(|e| Error::Format(e.to_string()))?;

    let mut stream = Stream::new(sink, rate_in, rate, 2)?;
    let mut channels_in = 0;
    let mut buf: Vec<f32> = vec![];
    let mut stereo: Vec<f32> = vec![];
    loop {
        let packet = match format.next_packet() {
            Ok(Some(p)) => p,
            Ok(None) => break,
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(Error::Format(e.to_string())),
        };
        if packet.track_id != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue, // a damaged packet: skip it, as players do
            Err(e) => return Err(Error::Format(e.to_string())),
        };
        let ch = decoded.spec().channels().count().max(1);
        channels_in = ch;
        buf.resize(decoded.samples_interleaved(), 0.0);
        decoded.copy_to_slice_interleaved(&mut buf);
        let frames = buf.len() / ch;
        stereo.clear();
        stereo.reserve(frames * 2);
        for f in 0..frames {
            let l = buf[f * ch];
            let r = if ch > 1 { buf[f * ch + 1] } else { l };
            stereo.push(l);
            stereo.push(r);
        }
        let from = (skip as usize).min(frames);
        skip -= from as u64;
        let take = ((frames - from) as u64).min(keep) as usize;
        keep -= take as u64;
        stream.push(&stereo[from * 2..(from + take) * 2])?;
    }
    let (frames_in, frames_out) = stream.finish()?;
    Ok(Info { rate_in, channels_in, frames_in, frames_out, channels_out: 2, edit })
}

fn decode_opus(path: &Path, rate: u32, sink: &mut impl Sink, out_ch: usize) -> Result<Info, Error> {
    let bytes = std::fs::read(path)?;
    let mut stream = Stream::new(sink, opus::RATE, rate, out_ch)?;
    let mut stereo: Vec<f32> = vec![];
    let (head, _) = opus::decode(&bytes, |pcm, ch| {
        if ch == out_ch {
            return stream.push(pcm);
        }
        if out_ch != 2 {
            return Err(Error::Format(format!("not a stems file: {ch} channels")));
        }
        // To stereo: mono doubled, stems' three pairs summed back into the record.
        stereo.clear();
        for f in pcm.chunks_exact(ch) {
            let (l, r) = match ch {
                1 => (f[0], f[0]),
                6 => (f[0] + f[2] + f[4], f[1] + f[3] + f[5]),
                _ => (f[0], f[1]),
            };
            stereo.push(l);
            stereo.push(r);
        }
        stream.push(&stereo)
    })?;
    let (frames_in, frames_out) = stream.finish()?;
    Ok(Info { rate_in: opus::RATE, channels_in: head.channels, frames_in, frames_out, channels_out: out_ch, edit: Edit::default() })
}

/// Decodes `path` into a new engine source, finished at the end.
pub fn decode_into_source(path: &Path, source: &mut wo_engine::Source, rate: u32) -> Result<Info, Error> {
    let info = decode(path, rate, source)?;
    source.finish();
    Ok(info)
}

const CHUNK: usize = 1024;

/// Interleaved f32 in at one rate (`ch` channels), 16-bit out at another, exact in time.
struct Stream<'s, S: Sink> {
    sink: &'s mut S,
    ch: usize,
    rs: Option<Fft<f32>>,
    ratio: f64,
    pending: Vec<f32>,
    out: Vec<f32>,
    pcm: Vec<i16>,
    /// The resampler's delay still to cut off the front, frames out.
    to_trim: usize,
    frames_in: u64,
    frames_out: u64,
    /// At the end: frames out there may be at most.
    cap: Option<u64>,
}

impl<'s, S: Sink> Stream<'s, S> {
    fn new(sink: &'s mut S, rate_in: u32, rate_out: u32, ch: usize) -> Result<Self, Error> {
        let rs = if rate_in == rate_out {
            None
        } else {
            Some(
                Fft::<f32>::new(rate_in as usize, rate_out as usize, CHUNK, ch, FixedSync::Input)
                    .map_err(|e| Error::Resample(e.to_string()))?,
            )
        };
        let (to_trim, out_max) = rs.as_ref().map_or((0, 0), |r| (r.output_delay(), r.output_frames_max()));
        Ok(Stream {
            sink,
            ch,
            rs,
            ratio: rate_out as f64 / rate_in as f64,
            pending: vec![],
            out: vec![0.0; out_max * ch],
            pcm: vec![],
            to_trim,
            frames_in: 0,
            frames_out: 0,
            cap: None,
        })
    }

    fn push(&mut self, pcm: &[f32]) -> Result<(), Error> {
        let ch = self.ch;
        self.frames_in += (pcm.len() / ch) as u64;
        if self.rs.is_none() {
            return self.emit_slice(pcm);
        }
        self.pending.extend_from_slice(pcm);
        loop {
            let need = self.rs.as_ref().unwrap().input_frames_next();
            if self.pending.len() / ch < need {
                return Ok(());
            }
            self.chunk(need, None)?;
            self.pending.drain(..need * ch);
        }
    }

    /// Resamples the first `frames` of pending (zero-padded to a whole chunk when
    /// `valid` says fewer are real).
    fn chunk(&mut self, frames: usize, valid: Option<usize>) -> Result<(), Error> {
        let ch = self.ch;
        let rs = self.rs.as_mut().unwrap();
        if self.pending.len() < frames * ch {
            self.pending.resize(frames * ch, 0.0);
        }
        let input = InterleavedSlice::new(&self.pending[..frames * ch], ch, frames).map_err(|e| Error::Resample(e.to_string()))?;
        let cap = self.out.len() / ch;
        let mut output = InterleavedSlice::new_mut(&mut self.out[..], ch, cap).map_err(|e| Error::Resample(e.to_string()))?;
        let indexing = valid.map(|v| Indexing::new().partial_len(v));
        let (_, written) =
            rs.process_into_buffer(&input, &mut output, indexing.as_ref()).map_err(|e| Error::Resample(e.to_string()))?;
        let out = std::mem::take(&mut self.out);
        let r = self.emit_slice(&out[..written * ch]);
        self.out = out;
        r
    }

    fn emit_slice(&mut self, pcm: &[f32]) -> Result<(), Error> {
        let ch = self.ch;
        let mut s = pcm;
        if self.to_trim > 0 {
            let cut = self.to_trim.min(s.len() / ch);
            self.to_trim -= cut;
            s = &s[cut * ch..];
        }
        if let Some(cap) = self.cap {
            let room = cap.saturating_sub(self.frames_out) as usize;
            s = &s[..(room * ch).min(s.len())];
        }
        if s.is_empty() {
            return Ok(());
        }
        self.pcm.clear();
        self.pcm.extend(s.iter().map(|&x| (x * 32767.0).round().clamp(-32767.0, 32767.0) as i16));
        self.frames_out += (s.len() / ch) as u64;
        self.sink.take(&self.pcm)
    }

    /// Flushes the resampler: exactly ⌈frames in × ratio⌉ frames out in all.
    fn finish(mut self) -> Result<(u64, u64), Error> {
        if self.rs.is_some() {
            let want = (self.frames_in as f64 * self.ratio).ceil() as u64;
            self.cap = Some(want);
            let left = self.pending.len() / self.ch;
            let need = self.rs.as_ref().unwrap().input_frames_next();
            self.chunk(need, Some(left))?;
            let mut guard = 0;
            while self.frames_out < want && guard < 64 {
                self.pending.clear();
                let need = self.rs.as_ref().unwrap().input_frames_next();
                self.chunk(need, Some(0))?;
                guard += 1;
            }
        }
        Ok((self.frames_in, self.frames_out))
    }
}
