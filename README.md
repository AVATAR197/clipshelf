# ClipShelf

ClipShelf is a local-only macOS clipboard manager MVP inspired by the workflow of apps like Paste, without copying their branding or assets.

## Features

- Captures copied text and images.
- Opens a bottom launcher with `Shift + Command + V`.
- Searches clipboard history.
- Stores clips in categories.
- Pins and deletes clips.
- Pastes the selected item back into the frontmost app when Accessibility permission is granted.
- Persists data locally in `~/Library/Application Support/ClipShelf`.

## Download

Grab the latest build from the [Releases page](https://github.com/AVATAR197/clipshelf/releases/latest):

1. Download `ClipShelf.zip` and unzip it.
2. Drag `ClipShelf.app` into `/Applications`.
3. First launch: right-click the app and choose **Open** (the build is not notarized, so macOS shows a warning once). On newer macOS versions you may instead need to approve it under `System Settings -> Privacy & Security -> Open Anyway`.
4. Grant Accessibility permission (see below) so paste-back works.

New releases are published automatically when a `v*` tag is pushed (see `.github/workflows/release.yml`).

## Build

```sh
swift build
```

## Create a Mac app bundle

```sh
sh Scripts/package-app.sh
```

The app bundle is created at:

```text
.build/ClipShelf.app
```

Open the app from Finder or run:

```sh
open .build/ClipShelf.app
```

## Permission

For automatic paste-back, macOS must allow ClipShelf in:

```text
System Settings -> Privacy & Security -> Accessibility
```

Without that permission, selecting a clip still places it on the clipboard, but macOS will block the simulated `Command + V`.
