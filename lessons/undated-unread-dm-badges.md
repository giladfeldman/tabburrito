## Unread DM Badges

- Title-total badges cannot separate 1:1 vs groups. Inject a DOM scraper and report via a title marker (`\u{2063}TB{n}\u{2063}`), then `on_document_title_changed` → sidebar event.
- Keep notify-tracked Messenger hot so cold-unload to `about:blank` does not zero badges.
