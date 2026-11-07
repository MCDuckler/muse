//! The crate's house calls (recommend, dismiss, the cue check) against a house of the test's
//! own: the paths and bodies the server's routes take, the answers as they come (no account
//! is touched).
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use wo_house::{House, Session};

/// What the house was asked: the method, the path, the body.
type Asked = Arc<Mutex<Vec<(String, String, Value)>>>;

/// A house that answers each path from `answers` (by its start) and keeps what it was asked.
fn fake(answers: Vec<(&'static str, &'static str, Value)>) -> (String, Asked) {
    let asked = Arc::new(Mutex::new(vec![]));
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let kept = asked.clone();
    std::thread::spawn(move || {
        for conn in l.incoming().flatten() {
            let mut r = BufReader::new(conn.try_clone().unwrap());
            let mut line = String::new();
            let _ = r.read_line(&mut line);
            let (mut len, mut h) = (0usize, String::new());
            while r.read_line(&mut h).is_ok_and(|n| n > 0) && h.trim() != "" {
                if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap_or(0);
                }
                h.clear();
            }
            let mut body = vec![0; len];
            let _ = r.read_exact(&mut body);
            let mut p = line.split_whitespace();
            let (method, path) = (p.next().unwrap_or("").to_owned(), p.next().unwrap_or("").to_owned());
            kept.lock().unwrap().push((method.clone(), path.clone(), serde_json::from_slice(&body).unwrap_or_default()));
            let answer = answers.iter().find(|(m, pre, _)| *m == method && path.starts_with(pre)).map(|a| a.2.to_string()).unwrap_or_else(|| "{}".into());
            let mut c = conn;
            let _ = write!(c, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}", answer.len());
        }
    });
    (format!("http://127.0.0.1:{port}"), asked)
}

fn track(id: i64, title: &str) -> Value {
    json!({"id": id, "title": title, "artists": ["Someone"], "state": "ready", "bpm": 124.0, "duration_ms": 200000})
}

#[test]
fn the_crate_asks_the_house_as_its_routes_take_it() {
    let (server, asked) = fake(vec![
        ("GET", "/recommend", json!({"items": [
            {"where": "library", "why": "same mood", "track": track(7, "Seven")},
            {"where": "house", "why": "", "track": track(8, "Eight")},
            {"where": "new", "why": "elsewhere", "hit": {"videoId": "x"}},
        ], "seeds": []})),
        ("GET", "/booth/check", json!({"items": [
            {"track": track(1, "One"), "hand_pads": {}, "grid": "ok", "note": null, "checked_at": "2026-11-07T10:00:00"},
            {"track": track(2, "Two"), "hand_pads": {}, "grid": null, "note": null, "checked_at": null},
        ], "checked": 1})),
    ]);
    let h = House::new(Session { server, token: "t".into(), user: None });
    let picks = h.recommend(&[3, 4], &[9], 0.5, 20).unwrap();
    assert_eq!(picks.iter().map(|p| p.track.as_ref().unwrap().id).collect::<Vec<_>>(), vec![7, 8], "a record found elsewhere is not one to play");
    assert_eq!((picks[0].where_.as_str(), picks[0].why.as_str(), picks[1].where_.as_str()), ("library", "same mood", "house"));
    h.dismiss_pick(8).unwrap();
    let checks = h.cue_checks(40).unwrap();
    assert_eq!(checks.len(), 2);
    assert!(checks[0].checked_at.is_some() && checks[0].grid.as_deref() == Some("ok") && checks[1].checked_at.is_none());
    h.check_cues(2, "half", &[(1, 12_000, true), (4, 190_500, false)]).unwrap();
    h.uncheck_cues(2).unwrap();
    let a = asked.lock().unwrap();
    assert_eq!(a[0].1, "/recommend?seeds=3%2C4&fresh=0.5&limit=20&exclude=9");
    assert_eq!((a[1].0.as_str(), a[1].1.as_str(), a[1].2.clone()), ("POST", "/recommend/dismiss", json!({"track_id": 8})));
    assert_eq!(a[2].1, "/booth/check?n=40");
    assert_eq!((a[3].0.as_str(), a[3].1.as_str()), ("PUT", "/booth/check/2"));
    assert_eq!(a[3].2, json!({"grid": "half", "pads": {"1": {"ms": 12000, "auto": true}, "4": {"ms": 190500, "auto": false}}}), "as the route takes a pad");
    assert_eq!((a[4].0.as_str(), a[4].1.as_str()), ("DELETE", "/booth/check/2"));
}
