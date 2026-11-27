## LinkedIn Feed Focus (2026-11-27)

- LinkedIn now fills the home feed with unlabelled posts from strangers (no "Promoted",
  no "Suggested") and with "Followed by X" posts. The ad blocker's label matching cannot
  see them; `LINKEDIN_FEED_FOCUS_JS` handles them with its own switch (Settings → LinkedIn).
- Stable anchors, read from the live feed: every post has a button labelled
  `Open control menu for post by <author>`; a post from someone you do not follow has a
  `Follow <author>` button; anything shown because of a contact puts a context line
  ("X likes this", "X reposted this", "Followed by X") ABOVE the author's name, below the
  post's own "Feed post" heading.
- Rule: hide when the context says "Followed by" / "follows"; hide when there is no context
  AND a `Follow <author>` button exists. Everything else stays (contacts, people you follow
  — "Following" — and anything a contact touched).
- Home feed (`/feed/`) only: on a stranger's profile page every post would match.
- `innerText` of a `display:none` post has no line breaks, so skip posts that are not
  rendered (`getClientRects().length === 0`) rather than misread them.
- Matching is English-UI text (aria-labels, "Followed by"); a LinkedIn UI language change
  would make the filter do nothing, not hide wrongly.
