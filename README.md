# Tyme

A focused, local-first time tracker for the centered Omarchy bar.

## Workflow

1. Click **Start timer** in the top bar.
2. Add a client with a name and a color, then select it.
3. Optionally add a work note and start the timer.
4. The bar shows the client and elapsed time in that client's color.
5. Click the widget to pause, resume, stop, review recent entries, or export a CSV.

All data is local at `~/.local/state/omarchy/client-timer/state.json`. Active
timers are persisted immediately and therefore survive an Omarchy-shell restart.
