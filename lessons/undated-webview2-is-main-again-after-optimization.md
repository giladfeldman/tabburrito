## WebView2 Is Main Again After Optimization

- The WebView2 model gives Tabburrito direct ownership of the visible window, which enables shell UX that Firefox Lite cannot cleanly provide.
- The original WebView2 memory problem was made worse by separate user-data folders per service.
- A shared WebView2 user-data folder is a better default for this app because it avoids multiplying browser/runtime process overhead.
- The current main product should be treated as WebView2 Portable, with Firefox Lite kept as an alternate experiment.
