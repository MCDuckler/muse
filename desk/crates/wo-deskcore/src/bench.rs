//! `--bench SECONDS [--out DIR]`: a UI measures itself while the Auto DJ mixes. Every
//! frame's interval and the time our own code took in it, the process's CPU share and
//! its memory, after a warm-up; at the end a JSON report and a screenshot in DIR.
use std::path::PathBuf;
use std::time::Instant;

use cpu_time::ProcessTime;

const WARM_UP: f64 = 3.0;

pub struct Bench {
    toolkit: &'static str,
    seconds: f64,
    out: PathBuf,
    started: Instant,
    measuring: Option<(Instant, ProcessTime)>,
    last: Option<Instant>,
    intervals: Vec<f32>,
    work: Vec<f32>,
    peak_rss: u64,
    pub size: (u32, u32),
}

impl Bench {
    /// From the command line: None unless --bench was given.
    pub fn from_args(toolkit: &'static str) -> Option<Bench> {
        let args: Vec<String> = std::env::args().collect();
        let i = args.iter().position(|a| a == "--bench")?;
        let seconds = args.get(i + 1).and_then(|v| v.parse().ok()).unwrap_or(30.0);
        let out = args.iter().position(|a| a == "--out").and_then(|j| args.get(j + 1)).map(PathBuf::from).unwrap_or_else(|| ".".into());
        Some(Bench {
            toolkit,
            seconds,
            out,
            started: Instant::now(),
            measuring: None,
            last: None,
            intervals: vec![],
            work: vec![],
            peak_rss: 0,
            size: (0, 0),
        })
    }

    /// One frame drawn; `work_ms` is what our own code took in it. True once the time is up.
    pub fn frame(&mut self, work_ms: f32) -> bool {
        let now = Instant::now();
        let since = now.duration_since(self.started).as_secs_f64();
        if since < WARM_UP {
            self.last = Some(now);
            return false;
        }
        if self.measuring.is_none() {
            self.measuring = Some((now, ProcessTime::now()));
        }
        if let Some(last) = self.last {
            self.intervals.push(now.duration_since(last).as_secs_f32() * 1000.0);
            self.work.push(work_ms);
        }
        self.last = Some(now);
        if self.intervals.len() % 60 == 0 {
            if let Some(m) = memory_stats::memory_stats() {
                self.peak_rss = self.peak_rss.max(m.physical_mem as u64);
            }
        }
        since >= WARM_UP + self.seconds
    }

    /// Writes bench-<toolkit>.json (and the screenshot, RGBA8, when given) into the out dir.
    pub fn finish(&mut self, shot: Option<(u32, u32, &[u8])>) -> String {
        let (t0, cpu0) = self.measuring.unwrap_or((Instant::now(), ProcessTime::now()));
        let wall = t0.elapsed().as_secs_f64();
        let cpu = cpu0.elapsed().as_secs_f64();
        let pct = |v: &mut Vec<f32>, p: f64| -> f32 {
            if v.is_empty() {
                return 0.0;
            }
            v.sort_by(|a, b| a.total_cmp(b));
            v[((v.len() - 1) as f64 * p).round() as usize]
        };
        let mut iv = self.intervals.clone();
        let mut wk = self.work.clone();
        let missed = self.intervals.iter().filter(|&&x| x > 25.0).count();
        let report = format!(
            "{{\"toolkit\":\"{}\",\"os\":\"{}\",\"window\":[{},{}],\"seconds\":{:.1},\"frames\":{},\"fps\":{:.1},\
\"interval_ms\":{{\"p50\":{:.2},\"p95\":{:.2},\"p99\":{:.2},\"max\":{:.2}}},\"missed_over_25ms\":{},\
\"our_code_ms\":{{\"p50\":{:.2},\"p99\":{:.2},\"max\":{:.2}}},\"cpu_percent_of_one_core\":{:.1},\"peak_rss_mb\":{:.0}}}",
            self.toolkit,
            std::env::consts::OS,
            self.size.0,
            self.size.1,
            wall,
            self.intervals.len(),
            self.intervals.len() as f64 / wall.max(0.001),
            pct(&mut iv, 0.5),
            pct(&mut iv, 0.95),
            pct(&mut iv, 0.99),
            pct(&mut iv, 1.0),
            missed,
            pct(&mut wk, 0.5),
            pct(&mut wk, 0.99),
            pct(&mut wk, 1.0),
            100.0 * cpu / wall.max(0.001),
            self.peak_rss as f64 / 1_048_576.0,
        );
        let _ = std::fs::create_dir_all(&self.out);
        let _ = std::fs::write(self.out.join(format!("bench-{}.json", self.toolkit)), &report);
        if let Some((w, h, rgba)) = shot {
            let _ = image::save_buffer(self.out.join(format!("shot-{}.png", self.toolkit)), rgba, w, h, image::ExtendedColorType::Rgba8);
        }
        report
    }
}
