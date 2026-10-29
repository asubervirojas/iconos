# Iconos

**Give every app on your Mac a clean, consistent icon: just its logo on a white tile in Light Mode and a dark tile in Dark Mode.**

Iconos reads each app's own icon, extracts only the logo (dropping the vendor's background plate), and places it on a native macOS-style tile. A small background agent switches every icon between the light and dark variant when you change appearance, and puts the icon back after an app updates itself.

Free and open source (MIT). [Leer en español](README.es.md).

## Requirements

- macOS 26 or later
- Apple Silicon (M1 or newer)

## Install

1. Download `Iconos-x.y.z.zip` from [Releases](https://github.com/asubervirojas/iconos/releases). You can check it with `shasum -a 256 -c Iconos-x.y.z.zip.sha256`.
2. Unzip it and move **Iconos.app** to your **Applications** folder.
3. Open it. Because Iconos is not notarized by Apple (it is a free project without a paid Apple Developer account), macOS blocks the first launch:
   - Open **System Settings > Privacy & Security**.
   - Scroll down and click **Open Anyway** next to the Iconos message, then confirm **Open**.
   - You only do this once.

Iconos then shows a short setup guide with every permission it needs and a button for each one.

## Permissions, and why

| Permission | Why |
|---|---|
| **App Management** for *Iconos* and *Iconos Agente* (System Settings > Privacy & Security > App Management) | macOS protects apps from being modified. Iconos writes the custom icon into each app (the standard `Icon\r` file Finder uses for custom icons), so both the app and its agent need this permission. |
| **Notifications** (optional) | The agent tells you when an update removed an icon's permission or when a vendor changed its logo. |
| **Your password, in Terminal** (only for some apps) | Apps installed with a `.pkg` or from the App Store belong to the system (root), so even with App Management Iconos cannot write into them. For those, Iconos shows you the exact command first, then opens Terminal so **you** type your password there (Iconos never sees it). The command adds one access rule to that app's top folder only, letting your user add the icon file. Nothing inside the app (`Contents`) is touched, and it is reversible: **Restore** in Iconos removes it, or run `sudo chmod -a "<you> allow add_file,writeattr,writeextattr" /Applications/App.app`. You can inspect it with `ls -led /Applications/App.app`. Terminal itself needs App Management for this step. |

Apps that live on the read-only system volume (Safari) or that their vendor locked against changes cannot be modified, and Iconos marks them with a gray lock.

## How it works

- **Logo extraction.** For icons made with Apple's Icon Composer (most new apps), Iconos reads the original layers, so the logo is exact and uses the vendor's own dark variant. Other icons go through a pixel extractor that separates the logo from its plate. Every result gets a confidence level; if it looks wrong, choose *Full icon* or use your own images.
- **Nothing is uploaded.** Iconos makes no network connections. Everything stays on your Mac in `~/Library/Application Support/Iconos`.
- **Private API notice.** Reading Icon Composer layers uses Apple's private CoreUI framework. If a future macOS changes it, Iconos falls back to the pixel extractor. Tested on macOS 26 and 27.

## Uninstall

Open Iconos > Settings > **Uninstall Iconos…**. It restores every app's original icon, turns off the agent, removes the Terminal access rules it added (asking for your password once if there are any), deletes its data and moves itself to the Trash.

## Build from source

Requires Xcode 26 or later (the full Xcode, not only the Command Line Tools, because the icon is compiled with `actool`).

```bash
git clone https://github.com/asubervirojas/iconos.git
cd iconos
./compilar.sh --crear-firma   # once: creates a local self-signed code-signing identity in your keychain
./compilar.sh --instalar      # builds, signs and installs to ~/Applications
```

macOS remembers the App Management permission by the app's signature. Always sign with the same identity (the `ICONOS_FIRMA` variable sets its name), or macOS will ask for the permission again after each build. `./compilar.sh --release` produces the zip and its SHA-256.

## Credits

Built by Armando Subervi with AI assistance from Claude (Anthropic) and Codex (OpenAI).

App names, icons and logos belong to their respective owners. Iconos is not affiliated with or endorsed by any of them, or by Apple.

## License

[MIT](LICENSE)
