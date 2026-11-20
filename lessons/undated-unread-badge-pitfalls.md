## Unread Badge Pitfalls

- WhatsApp rewrites `document.title`, erasing the unread marker; the reporter
  re-stamps whenever the marker is missing, not only when the count changes.
- The "Archived" entry at the top of the WhatsApp chat list has its own unread
  badge; it must not be counted.
- The count must not depend on notification mode — notify mode only gates
  popups. Gating it hid the badge for users with notifications off.


- **A count shown in every mode needs its tab alive in every mode.** Making the
  WhatsApp/Messenger count independent of the notify mode left Messenger (not
  `keep_loaded`) eligible for the idle unload whenever notifications were off; a
  blanked tab stops reporting, so the badge would freeze at a stale number.
  Messaging tabs now always stay loaded unless the user switches the tab off
  (which closes it). Caught in review, 2026-11-04.
