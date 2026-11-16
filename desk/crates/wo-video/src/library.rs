//! Where the footage is, on this machine: the sources in a folder the hands fill
//! (`~/Videos/WetOwl`, WETOWL_VIDEOS), the proxies made of them in the Desk's data
//! (`<data>/wetowl-desk/videos/<id>/`, WETOWL_VIDEO_PROXIES).
use std::path::{Path, PathBuf};

use wo_show::video::ClipMeta;

use crate::import::Stored;

/// The files taken for footage, by extension.
pub const VIDEO_EXTS: &[&str] = &["mp4", "m4v", "mov", "mkv", "webm", "avi", "mpg", "mpeg", "ogv", "wmv", "flv", "ts", "mts", "m2ts", "dv", "3gp", "gif"];

#[derive(Clone, Debug, PartialEq)]
pub struct Library {
    pub sources: PathBuf,
    pub proxies: PathBuf,
}

/// A source not made into a proxy yet.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub path: PathBuf,
    /// Its path within the sources' folder.
    pub rel: String,
    pub size: u64,
}

impl Library {
    /// This machine's.
    pub fn here() -> Option<Library> {
        let sources = std::env::var_os("WETOWL_VIDEOS").map(PathBuf::from).or_else(|| dirs::video_dir().map(|d| d.join("WetOwl"))).or_else(|| dirs::home_dir().map(|h| h.join("Videos").join("WetOwl")))?;
        let proxies = std::env::var_os("WETOWL_VIDEO_PROXIES").map(PathBuf::from).or_else(|| dirs::data_dir().map(|d| d.join("wetowl-desk").join("videos")))?;
        Some(Library { sources, proxies })
    }

    pub fn at(sources: &Path, proxies: &Path) -> Library {
        Library { sources: sources.into(), proxies: proxies.into() }
    }

    pub fn proxy(&self, id: &str) -> PathBuf {
        self.proxies.join(id).join("proxy.wov")
    }

    pub fn poster(&self, id: &str) -> PathBuf {
        self.proxies.join(id).join("poster.jpg")
    }

    /// The clips made, by name.
    pub fn stored(&self) -> Vec<Stored> {
        let mut out: Vec<Stored> = std::fs::read_dir(&self.proxies)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| !e.file_name().to_string_lossy().ends_with(".part"))
            .filter_map(|e| std::fs::read(e.path().join("clip.json")).ok())
            .filter_map(|b| serde_json::from_slice::<Stored>(&b).ok())
            .filter(|s| !s.meta.id.is_empty() && s.meta.frames > 0 && self.proxy(&s.meta.id).is_file())
            .collect();
        out.sort_by(|a, b| a.meta.name.to_lowercase().cmp(&b.meta.name.to_lowercase()).then(a.meta.id.cmp(&b.meta.id)));
        out
    }

    pub fn clips(&self) -> Vec<ClipMeta> {
        self.stored().into_iter().map(|s| s.meta).collect()
    }

    /// One clip's facts.
    pub fn meta(&self, id: &str) -> Option<ClipMeta> {
        let b = std::fs::read(self.proxies.join(id).join("clip.json")).ok()?;
        serde_json::from_slice::<Stored>(&b).ok().map(|s| s.meta)
    }

    /// The sources in the folder (and its folders), by path.
    pub fn sources(&self) -> Vec<Pending> {
        fn walk(root: &Path, d: &Path, depth: usize, out: &mut Vec<Pending>) {
            for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
                let p = e.path();
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with('.') {
                    continue;
                }
                if p.is_dir() {
                    if depth < 4 {
                        walk(root, &p, depth + 1, out);
                    }
                    continue;
                }
                let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                if !VIDEO_EXTS.contains(&ext.as_str()) {
                    continue;
                }
                let size = e.metadata().map(|m| m.len()).unwrap_or(0);
                let rel = p.strip_prefix(root).unwrap_or(&p).to_string_lossy().replace('\\', "/");
                out.push(Pending { path: p, rel, size });
            }
        }
        let mut out = vec![];
        walk(&self.sources, &self.sources, 0, &mut out);
        out.sort_by(|a, b| a.rel.cmp(&b.rel));
        out
    }

    /// The sources with no proxy yet (nor one that failed: `failed`, by id).
    pub fn pending(&self, failed: &[String]) -> Vec<Pending> {
        let made: std::collections::BTreeSet<String> = self.stored().into_iter().map(|s| s.meta.id).collect();
        self.sources()
            .into_iter()
            .filter(|p| p.size > 0)
            .filter(|p| {
                let id = crate::import::clip_id(&p.rel, p.size);
                !made.contains(&id) && !failed.contains(&id)
            })
            .collect()
    }

    /// The proxies whose source is gone (or changed), and the half-made: removed. Not while
    /// the sources' folder is missing altogether (a drive not there is not footage deleted).
    pub fn prune(&self) -> usize {
        if !self.sources.is_dir() {
            return 0;
        }
        let ids: std::collections::BTreeSet<String> = self.sources().iter().map(|p| crate::import::clip_id(&p.rel, p.size)).collect();
        let mut gone = 0;
        for e in std::fs::read_dir(&self.proxies).into_iter().flatten().flatten() {
            if !e.path().is_dir() {
                continue;
            }
            let name = e.file_name().to_string_lossy().to_string();
            let drop = if name.ends_with(".part") {
                // half made an hour ago: an import that died
                e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|d| d.as_secs() > 3600)
            } else {
                !ids.contains(&name)
            };
            if drop && std::fs::remove_dir_all(e.path()).is_ok() {
                gone += 1;
            }
        }
        gone
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sources_pending_and_pruned() {
        let root = std::env::temp_dir().join(format!("wo-video-lib-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (src, prox) = (root.join("src"), root.join("prox"));
        std::fs::create_dir_all(src.join("old")).unwrap();
        std::fs::write(src.join("old/Reel.MP4"), b"x").unwrap();
        std::fs::write(src.join("notes.txt"), b"x").unwrap();
        std::fs::write(src.join(".hidden.mp4"), b"x").unwrap();
        let lib = Library::at(&src, &prox);
        let p = lib.pending(&[]);
        assert_eq!(p.len(), 1);
        assert_eq!(p[0].rel, "old/Reel.MP4");
        // a proxy for it, and one for a source gone
        let id = crate::import::clip_id("old/Reel.MP4", 1);
        for i in [id.as_str(), "gone-00000000"] {
            std::fs::create_dir_all(prox.join(i)).unwrap();
            std::fs::write(prox.join(i).join("proxy.wov"), b"").unwrap();
            let s = Stored { meta: ClipMeta { id: i.into(), name: i.into(), frames: 3, ..Default::default() }, ..Default::default() };
            std::fs::write(prox.join(i).join("clip.json"), serde_json::to_vec(&s).unwrap()).unwrap();
        }
        assert!(lib.pending(&[]).is_empty());
        assert_eq!(lib.clips().len(), 2);
        assert_eq!(lib.prune(), 1);
        assert_eq!(lib.clips().iter().map(|c| c.id.clone()).collect::<Vec<_>>(), vec![id]);
        std::fs::remove_dir_all(&root).ok();
    }
}
