## LinkedIn Feed Sort

- LinkedIn home feed has no reliable public URL param for Top vs Recent (unlike jobs `sortBy=DD`).
- Enforce sort by injecting a semantic UI clicker (Sort by → Recent/Top) and re-applying if LinkedIn resets.
- Persist preference in shell urlbar localStorage + Rust `LinkedInSortState`; default Recent.
