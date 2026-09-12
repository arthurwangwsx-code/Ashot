# Ashot

Ashot is a lightweight macOS menu-bar screenshot app. The basic workflow is:

1. Start a capture from the menu-bar icon or a global shortcut.
2. Select an area, the current screen, or a window. While area selection is active, press Space to capture the frontmost window.
3. Use the floating preview to edit, copy, save, recognize text, pin, or dismiss the screenshot.

Current product behavior, interaction rules, architecture, and maintenance checks are documented in [doc/README.md](doc/README.md).

## Requirements

- macOS 26.2 or newer
- Xcode 26.2 or newer
- An Apple Development identity configured in Xcode for stable Screen Recording permission

## Build an app you can click

From the project directory, run:

```sh
./dev.sh build
```

The signed app is created at:

```text
build/Ashot.app
```

Double-click `Ashot.app` in Finder, or build and launch it in one step:

```sh
./dev.sh run
```

You can also open `Ashot.xcodeproj` in Xcode, select the `Ashot` scheme and **My Mac**, then press Run.

## First launch

Ashot runs in the menu bar by default, so it may not appear in the Dock. On first launch:

1. Allow **Screen Recording** when macOS asks.
2. If access was denied, open **Ashot → Settings → General** and use **Grant Access** or **System Settings**.
3. Return to Ashot and try the capture again. If macOS requests it, quit and reopen Ashot once after granting access.

Ashot captures the screen only after you choose a capture command or press an Ashot shortcut.

## Default shortcuts

| Action | Shortcut |
| --- | --- |
| Capture area | ⇧⌘2 |
| Capture fullscreen | ⇧⌘1 |
| Capture window | ⇧⌘7 |
| Capture with 3-second delay | ⇧⌘8 |
| Repeat last capture | ⇧⌘R |

Shortcuts can be changed under **Settings → Shortcuts**. Ashot rejects duplicate shortcuts and combinations reserved by macOS.

The same page also contains local editor tool shortcuts. These use a single letter without modifiers—for example `V` for Select, `A` for Arrow, `R` for Rectangle, and `T` for Text—and only work while an editor window is active.

## Development checks

```sh
./dev.sh check
./dev.sh test
```

`check` performs an unsigned Debug compile. `test` runs the headless unit tests. Screen capture, permission prompts, global shortcuts, and the floating preview still require an interactive macOS check.

## Publish from your Mac to GitHub Releases

After reviewing and committing the source, configure a public GitHub repository as `origin` and authenticate with `gh auth login`. Then:

```sh
./release.sh 1.0.0-preview.1 --allow-unnotarized --publish
```

This runs the tests, builds a Universal (Apple silicon + Intel) Release app locally, creates ZIP/DMG archives and SHA-256 checksums, pushes the exact source commit and tag, and publishes the assets to GitHub Releases. Without `--publish`, it only creates local packages. It never automatically commits a dirty workspace.

**Preview downloads are ad-hoc signed and not Apple notarized. Gatekeeper may block first launch.** Development signing is not a substitute for Developer ID distribution. See [the release guide](doc/05-github-release.md) for Developer ID signing, notarization, failure recovery, and installation details, and [the release review](doc/06-release-review.md) for known limitations.

GitHub integration is developer-side only: the app does not log into GitHub, upload screenshots, or automatically update itself. No open-source license grant has been added.
