## WebView2 Memory Work

- Keeping every service hot all the time is convenient but expensive.
- A service temperature model is the practical compromise.
- WhatsApp and Google Calendar are currently hot services.
- Messenger, LinkedIn, and Bluesky are cold services.
- Cold services should not unload immediately on tab switch because that breaks normal use and causes blank restores.
- A grace-period unload is better: short switches remain instant, longer inactive periods can release memory.
