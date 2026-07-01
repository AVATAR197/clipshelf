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
