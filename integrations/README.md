# integrations

Every adapter lives in its own directory and is optional. The app itself knows nothing
about any of them: an integration is just a script that either (a) writes a config
section and/or (b) posts JSON to the unix socket.

```
integrations/
  pi/              pi coding agent (https://pi.dev)
    install.sh     copy the extension into ~/.pi/agent/extensions, merge the pi config
    toast-notify.ts
```

## Adding one

Two ways to feed the toast server, both fine:

- **Write to the socket** — `{"title": ..., "body": ..., "duration": ...}\n` over
  `~/.pi-toast/toast.sock`. Works from any language, no dependency on this repo.
- **Shell out** — `build/toast send --title T --body B`.

A good integration script does three things: install its hook, merge only its own
config section (never overwrite the user's other keys), and support `--remove`.
