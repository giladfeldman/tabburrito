# Lessons

## Active rules

<!-- rules:start -->
- Sessions live in `%LOCALAPPDATA%\Tabburrito`; no build, install or update step may write or delete there.
- Updates install only signed GitHub releases; the version is bound from the signed trusted comment, never from `latest.json` alone.
- Test installers with a separate product name, identifier and throwaway key, never against the real install.
- A tab "works" only when it is seen rendering (CDP or eyes), never from process or network activity.
- The repo is public: no internal paths, project names or recovery manifests.
<!-- rules:end -->

Every past incident, one card each (22 so far): [lessons/INDEX.md](lessons/INDEX.md) - grep it, never read it whole.
New lesson: add a card + one INDEX line (`lessons-split.py add LESSONS.md --title T --body-file B`), and a rule above only if it changes what to do.
