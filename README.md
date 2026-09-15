# Statable desktop card — an Omarchy widget

A macOS-style widget on the [Omarchy](https://omarchy.org) desktop: visitors on
your site right now, big, with a seven-day sparkline, pinned over the wallpaper.
It polls the [`statable`](https://github.com/key-arg/statable-cli) CLI, which
prints and exits, so the card holds no state and runs no daemon.

![the card over the wallpaper: site, a large live count, a 7-day sparkline, and the weekly total](docs/card.png)

It sits on the layer above the wallpaper and below windows, so a window covers
it — as every desktop widget is covered. Glance at it on an empty desktop.

## Requires

- Omarchy with the Quickshell shell (the one with `~/.config/omarchy/shell.json`).
- The [`statable`](https://github.com/key-arg/statable-cli) CLI on `PATH`, signed
  in (`statable auth login`) with a default site (`statable sites use example.com`).

## Install

```bash
omarchy plugin add https://github.com/key-arg/omarchy-statable-desktop.git
```

It lands disabled. Read `Desktop.qml` (it is short), then enable it by adding its
id to the `plugins` array of `~/.config/omarchy/shell.json`:

```jsonc
{ "plugins": [ { "id": "com.statable.desktop" } ] }
```

The shell mounts it at startup (`keepLoaded`), pinned to the top-left corner.

## Behaviour

The card fills in only from clean `statable` runs. No key, no default site, the
API unreachable, or the binary missing from `PATH` — each leaves that part blank
rather than showing a wrong or stale figure. Every call runs off the UI thread,
and the card refreshes once a minute.

The bar widget [`omarchy-statable`](https://github.com/key-arg/omarchy-statable)
is a separate plugin — a live pill with a click-through panel. Run either, or both.

## Licence

MIT. Unsandboxed QML that runs inside `omarchy-shell`, like every Omarchy
plugin: read it before you enable it.
