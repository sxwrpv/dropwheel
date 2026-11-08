# Dropwheel

A menu-bar app for macOS. Drag a file, tap a modifier key, and drop the file on a slice of the wheel that opens: convert it to another format, run a tool on it such as Compress, Trim or Edit Metadata, or move and share it.

## Install

On a Mac with macOS 13 or later, Apple silicon or Intel. The repository is private, so the Mac needs the GitHub CLI signed in to an account that can see it. Once per Mac: `brew install gh` (or the installer from cli.github.com), then `gh auth login`. Then:

```bash
gh release download -R sxwrpv/dropwheel -p install.sh -O - | bash
```

The same command updates Dropwheel. The installer:

- checks that the download is complete and that the app's signature is intact
- puts Dropwheel where it already is, otherwise in `/Applications`, or in `~/Applications` without admin rights
- installs ffmpeg, webp and pandoc with Homebrew if they're missing (without Homebrew it says how to get them)
- opens Dropwheel, which lives in the menu bar

If the install fails, the copy you had is left in place.

Options go after `bash -s --`:

```bash
gh release download -R sxwrpv/dropwheel -p install.sh -O - | bash -s -- --with-libreoffice
```

| Option | Effect |
| --- | --- |
| `--with-libreoffice` | Also installs LibreOffice, used for slides, spreadsheets and some documents |
| `--skip-tools` | Leaves ffmpeg, webp and pandoc alone |
| `--no-launch` | Doesn't open Dropwheel afterwards |

## Uninstall

Quit Dropwheel from its menu bar icon, then:

```bash
rm -rf /Applications/Dropwheel.app ~/Applications/Dropwheel.app
defaults delete dev.dropwheel.Dropwheel
```

The installer may also have added ffmpeg, webp and pandoc with Homebrew. Other apps can use them too, so remove only the ones nothing else needs, for example:

```bash
brew uninstall pandoc
```

## Develop

Needs Swift 6 from Xcode or the Command Line Tools.

```bash
scripts/test.sh            # unit and integration tests
scripts/bundle.sh debug    # build/Dropwheel.app, with the DROPWHEEL_PREVIEW_* hooks
scripts/package.sh         # universal release in dist/: Dropwheel.zip, its SHA-256, install.sh
```

To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, run `scripts/package.sh`, then:

```bash
gh release create v0.5.0 dist/Dropwheel.zip dist/Dropwheel.zip.sha256 dist/install.sh --title "Dropwheel 0.5.0"
```

The app is ad-hoc signed. Neither curl nor the GitHub CLI marks what it downloads as quarantined, so Gatekeeper doesn't stop the installed app. A zip downloaded in a browser would be stopped. macOS also treats each update as a new app, so if you let Dropwheel control Pages, it asks again after an update.
