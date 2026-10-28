//! Read-only IPC latency probe for a running engine: connect time and request/reply
//! round trips for the two requests the navigator bridge makes (`WindowSet`) and the
//! cheapest query (`Query(Active)`). Sends nothing that changes state.
//!
//! usage: ipc_probe [count] [gap_ms]
use paneru::types::state::StateQueryKind;
use paneru::types::wire::{self, Request, Response, SendPort};
use std::time::{Duration, Instant};

fn stats(label: &str, mut xs: Vec<f64>) {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = xs.len();
    println!(
        "{label:<28} n={n} min={:.2} p50={:.2} p90={:.2} max={:.2} ms",
        xs[0],
        xs[n / 2],
        xs[n * 9 / 10],
        xs[n - 1]
    );
}

fn main() {
    let count: usize = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(30);
    let gap = Duration::from_millis(
        std::env::args().nth(2).and_then(|a| a.parse().ok()).unwrap_or(100),
    );
    let mut connect = Vec::new();
    let mut active = Vec::new();
    let mut window_set = Vec::new();
    futures_lite::future::block_on(async {
        for _ in 0..count {
            let t = Instant::now();
            let sender = wire::connect::<Request>(&wire::service_name()).expect("engine running");
            connect.push(t.elapsed().as_secs_f64() * 1000.0);

            let t = Instant::now();
            let _: Response = sender
                .call(&Request::Query(StateQueryKind::Active))
                .await
                .expect("active");
            active.push(t.elapsed().as_secs_f64() * 1000.0);

            std::thread::sleep(gap);
            let t = Instant::now();
            let _: Response = sender.call(&Request::WindowSet).await.expect("window set");
            window_set.push(t.elapsed().as_secs_f64() * 1000.0);
            std::thread::sleep(gap);
        }
    });
    stats("connect (bootstrap lookup)", connect);
    stats("Query(Active) round trip", active);
    stats("WindowSet round trip", window_set);
}
