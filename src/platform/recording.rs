//! Short, token-owned passthrough lease for the shortcut recorder.
use std::sync::Mutex;
use std::time::{Duration, Instant};

const LEASE: Duration = Duration::from_secs(30);
static RECORDING: Mutex<Option<(String, Instant)>> = Mutex::new(None);

pub(crate) fn update(token: &str, begin: bool) -> Result<(), String> {
    if token.is_empty()
        || token.len() > 128
        || !token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err("recording token must contain 1..128 ASCII letters, digits, or hyphens".into());
    }
    let mut lease = RECORDING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    update_at(&mut lease, token, begin, Instant::now())
}

fn update_at(
    lease: &mut Option<(String, Instant)>,
    token: &str,
    begin: bool,
    now: Instant,
) -> Result<(), String> {
    if lease.as_ref().is_some_and(|(_, deadline)| *deadline <= now) {
        *lease = None;
    }
    if lease.as_ref().is_some_and(|(owner, _)| owner != token) {
        return Err("another recorder owns the active lease".into());
    }
    *lease = begin.then(|| (token.to_owned(), now + LEASE));
    Ok(())
}

pub(crate) fn active() -> bool {
    RECORDING
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|(_, deadline)| *deadline > Instant::now())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lease_is_owned_renewable_and_expires() {
        let now = Instant::now();
        let mut lease = None;
        update_at(&mut lease, "one", true, now).unwrap();
        assert!(update_at(&mut lease, "two", false, now).is_err());
        assert!(update_at(&mut lease, "two", true, now).is_err());
        update_at(&mut lease, "one", true, now + Duration::from_secs(20)).unwrap();
        assert_eq!(lease.as_ref().unwrap().1, now + Duration::from_secs(50));
        update_at(&mut lease, "two", true, now + Duration::from_secs(51)).unwrap();
        update_at(&mut lease, "two", false, now + Duration::from_secs(52)).unwrap();
        assert!(lease.is_none());
        update_at(&mut lease, "two", false, now + Duration::from_secs(53)).unwrap();
    }
}
