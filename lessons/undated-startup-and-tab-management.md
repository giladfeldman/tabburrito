## Startup And Tab Management

- Relying on browser session restore produced unstable results.
- Tabburrito should deterministically create or restore its managed service workspace.
- One service should correspond to one managed service view.
- Duplicate tabs/views usually indicate that startup or service-switch logic is opening instead of focusing/restoring.
