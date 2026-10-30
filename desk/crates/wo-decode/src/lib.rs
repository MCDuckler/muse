//! Records decoded in-process for the engine: symphonia (AAC/M4A, MP3, FLAC, WAV,
//! Ogg Vorbis) to stereo, resampled to the engine's rate by rubato's synchronous FFT
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

/// Where decoded frames go: interleaved stereo, 16-bit, at the rate asked.
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
    /// The MP4 edit honoured: priming cut off the front, padding off the end.
    pub edit: Edit,
}

impl Info {
    pub fn seconds(&self) -> f64 {
        self.frames_in as f64 / self.rate_in as f64
    }
}

/// Decodes `path` into `sink` at `rate` frames a second.
pub fn decode(path: &Path, rate: u32, sink: &mut impl Sink) -> Result<Info, Error> {
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
        .make_audio_decoder(&params, &AudioDecoderOptions::default())
        .map_err(|e| Error::Format(e.to_string()))?;

    let mut stream = Stream::new(sink, rate_in, rate)?;
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
    Ok(Info { rate_in, channels_in, frames_in, frames_out, edit })
}

/// Decodes `path` into a new engine source, finished at the end.
pub fn decode_into_source(path: &Path, source: &mut wo_engine::Source, rate: u32) -> Result<Info, Error> {
    let info = decode(path, rate, source)?;
    source.finish();
    Ok(info)
}

const CHUNK: usize = 1024;

/// Stereo f32 in at one rate, 16-bit out at another, exact in time.
struct Stream<'s, S: Sink> {
    sink: &'s mut S,
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
    fn new(sink: &'s mut S, rate_in: u32, rate_out: u32) -> Result<Self, Error> {
        let rs = if rate_in == rate_out {
            None
        } else {
            Some(
                Fft::<f32>::new(rate_in as usize, rate_out as usize, CHUNK, 2, FixedSync::Input)
                    .map_err(|e| Error::Resample(e.to_string()))?,
            )
        };
        let (to_trim, out_max) = rs.as_ref().map_or((0, 0), |r| (r.output_delay(), r.output_frames_max()));
        Ok(Stream {
            sink,
            rs,
            ratio: rate_out as f64 / rate_in as f64,
            pending: vec![],
            out: vec![0.0; out_max * 2],
            pcm: vec![],
            to_trim,
            frames_in: 0,
            frames_out: 0,
            cap: None,
        })
    }

    fn push(&mut self, stereo: &[f32]) -> Result<(), Error> {
        self.frames_in += (stereo.len() / 2) as u64;
        if self.rs.is_none() {
            return self.emit_slice(stereo);
        }
        self.pending.extend_from_slice(stereo);
        loop {
            let need = self.rs.as_ref().unwrap().input_frames_next();
            if self.pending.len() / 2 < need {
                return Ok(());
            }
            self.chunk(need, None)?;
            self.pending.drain(..need * 2);
        }
    }

    /// Resamples the first `frames` of pending (zero-padded to a whole chunk when
    /// `valid` says fewer are real).
    fn chunk(&mut self, frames: usize, valid: Option<usize>) -> Result<(), Error> {
        let rs = self.rs.as_mut().unwrap();
        if self.pending.len() < frames * 2 {
            self.pending.resize(frames * 2, 0.0);
        }
        let input = InterleavedSlice::new(&self.pending[..frames * 2], 2, frames).map_err(|e| Error::Resample(e.to_string()))?;
        let cap = self.out.len() / 2;
        let mut output = InterleavedSlice::new_mut(&mut self.out[..], 2, cap).map_err(|e| Error::Resample(e.to_string()))?;
        let indexing = valid.map(|v| Indexing::new().partial_len(v));
        let (_, written) =
            rs.process_into_buffer(&input, &mut output, indexing.as_ref()).map_err(|e| Error::Resample(e.to_string()))?;
        let out = std::mem::take(&mut self.out);
        let r = self.emit_slice(&out[..written * 2]);
        self.out = out;
        r
    }

    fn emit_slice(&mut self, stereo: &[f32]) -> Result<(), Error> {
        let mut s = stereo;
        if self.to_trim > 0 {
            let cut = self.to_trim.min(s.len() / 2);
            self.to_trim -= cut;
            s = &s[cut * 2..];
        }
        if let Some(cap) = self.cap {
            let room = cap.saturating_sub(self.frames_out) as usize;
            s = &s[..(room * 2).min(s.len())];
        }
        if s.is_empty() {
            return Ok(());
        }
        self.pcm.clear();
        self.pcm.extend(s.iter().map(|&x| (x * 32767.0).round().clamp(-32767.0, 32767.0) as i16));
        self.frames_out += (s.len() / 2) as u64;
        self.sink.take(&self.pcm)
    }

    /// Flushes the resampler: exactly ⌈frames in × ratio⌉ frames out in all.
    fn finish(mut self) -> Result<(u64, u64), Error> {
        if self.rs.is_some() {
            let want = (self.frames_in as f64 * self.ratio).ceil() as u64;
            self.cap = Some(want);
            let left = self.pending.len() / 2;
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
