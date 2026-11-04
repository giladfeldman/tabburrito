// Unit tests for main.rs (declared there as `#[cfg(test)] mod tests;`).
use super::*;

// Regression (2026-11-04): the unread count is shown in every notify mode,
// so a messaging tab must never be idle-unloaded (a blank tab freezes it).
#[test]
fn messaging_tabs_always_stay_loaded() {
    for id in ["whatsapp", "messenger"] {
        let svc = service_by_id(id).expect("service exists");
        assert!(tab_stays_loaded(svc), "{id} must stay loaded");
    }
}

#[test]
fn ordinary_tabs_may_unload() {
    let svc = service_by_id("x").expect("service exists");
    assert!(!svc.keep_loaded);
    assert!(!tab_stays_loaded(svc));
}
