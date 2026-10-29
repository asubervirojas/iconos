# <img src="docs/readme-assets/icon.png" alt="Iconos" width="64" height="64" style="vertical-align: middle;">&nbsp;&nbsp;Iconos

*One clean, consistent icon style for every app on your Mac, in Light and Dark Mode*

![Platform](https://img.shields.io/badge/Platform-macOS_26+-black) ![Architecture](https://img.shields.io/badge/Architecture-Apple_Silicon-black) ![License](https://img.shields.io/badge/License-MIT-blue) ![Privacy](https://img.shields.io/badge/Network-None-success) [![Release](https://img.shields.io/github/v/release/asubervirojas/iconos?label=Release&color=blueviolet)](https://github.com/asubervirojas/iconos/releases/latest)

**Iconos** extracts just the logo from each app's icon, drops the vendor's background plate, and places it on a native macOS-style tile: white in Light Mode, dark in Dark Mode. A small background agent switches every icon when you change appearance and puts it back after an app updates itself.

[Leer en español](README.es.md)

---

<p align="center">
  <img src="docs/readme-assets/portada.gif" alt="Iconos switching app icons between Light and Dark Mode" width="980">
</p>

---

## 📥 How to Download Iconos

1. **GitHub Releases:** [Download the latest release](https://github.com/asubervirojas/iconos/releases/latest) (`Iconos-x.y.z.zip`).
2. **Build from source:** see [Build from Source](#-build-from-source).

> [!NOTE]
> Iconos is free and not notarized by Apple (no paid Apple Developer account). The first time you open it, macOS blocks it: go to **System Settings → Privacy & Security**, click **Open Anyway** next to the Iconos message, then confirm **Open**. You only do this once.

---

## 🔍 Why Iconos Exists

macOS 26 gave the Dock a unified look, but every app still ships its own plate: green squares, blue squares, white squares, gradients. Some apps adapt to Dark Mode, most don't. Iconos makes them all follow one style and one appearance, without touching what's inside the apps.

---

## ✅ Key Features

- **Logo-only extraction:** removes the vendor's background plate and keeps the logo, with its own colors adapted to each tile.
- **Exact logos for Icon Composer icons:** for apps built with Apple's Icon Composer (most new apps), Iconos reads the original layers, so the logo is pixel-perfect and uses the vendor's own dark variant.
- **Automatic Light/Dark switching:** a lightweight agent swaps every icon when your Mac changes appearance, including the automatic sunset/sunrise schedule.
- **Survives updates:** when an app updates and loses its custom icon, the agent puts it back. If the vendor changes its logo, Iconos regenerates it, or asks you to review it if the new result looks unreliable.
- **Confidence score:** every extraction is rated *reliable*, *check it* or *didn't work*, with the reason. Prefer the full icon? One click. Have your own artwork? Use your own light and dark images.
- **Batch actions:** apply, restore or change several apps at once. Filter by status (customized, needs permission, can't be changed…).
- **Safe by design:** keeps a backup of any custom icon the app already had, never writes inside the app's `Contents`, and **Uninstall** restores everything.
- **Private:** no network access, no analytics. Everything stays in `~/Library/Application Support/Iconos`.

---

## 🖼 Before and After

<p align="center">
  <a href="docs/readme-assets/comparacion.png">
    <img src="docs/readme-assets/comparacion.png" alt="Original icons, then the same apps with Iconos in Light Mode and in Dark Mode" width="980">
  </a>
</p>

<p align="center"><sub>Real output of Iconos 1.0.0. App names, icons and logos belong to their respective owners.</sub></p>

---

## ⚡ Quick Start

1. Download and unzip the latest release, move **Iconos.app** to **Applications** and open it (see the note above about **Open Anyway**).
2. Follow the built-in **setup guide**: it checks each permission and gives you a button for every step.
3. Pick an app in the sidebar, check the light and dark previews, and press **Apply** (**⌘S**).
4. Turn on the **automatic switch** so the agent follows Light and Dark Mode.

> [!IMPORTANT]
> Enable **App Management** for both **Iconos** and **Iconos Agente** in **System Settings → Privacy & Security → App Management**. macOS protects apps from being modified, and Iconos writes the standard custom-icon file (`Icon\r`, the same one Finder uses) into each app.

| Permission | Why it's needed |
|---|---|
| **App Management** (Iconos and Iconos Agente) | Write the custom icon into each app and switch it with your appearance. |
| **Notifications** (optional) | Tell you when an update removed a permission or a vendor changed its logo. |
| **Your password, in Terminal** (only some apps) | See below. |

### Apps installed with a `.pkg` or from the App Store

These apps are owned by the system (root), so even App Management isn't enough. For them, Iconos first **shows you the exact command**, then opens **Terminal** so **you** type your password there. Iconos never sees it.

The command adds one access rule to that app's top folder only, so your user can add the icon file:

```bash
sudo chmod +a "<you> allow add_file,writeattr,writeextattr" /Applications/App.app
```

> [!NOTE]
> Nothing inside the app (`Contents`) is touched, and it's fully reversible: **Restore** in Iconos offers to remove it, or run `sudo chmod -a "<you> allow add_file,writeattr,writeextattr" /Applications/App.app`. Check it any time with `ls -led /Applications/App.app`. Terminal itself needs App Management for this step.

Apps on the read-only system volume (like Safari) or locked by their vendor can't be changed. Iconos marks them with a gray lock.

---

## 🧩 How It Works

- **Icon Composer layers:** Iconos reads the app's layered icon through Apple's CoreUI framework and renders the logo layers without the background, for both the light and the dark appearance.
- **Pixel extractor:** for classic icons, it detects the background plate (square, rounded, circular, framed…) and separates the logo from it, then rates how confident the result is.
- **Highest-resolution source:** it always uses the largest icon the app ships (up to 1024 px).
- **Custom icon file:** the result is written as the app's custom icon (`Icon\r` plus the Finder flag), exactly like pasting an icon in **Get Info**.

> [!WARNING]
> Reading Icon Composer layers uses Apple's **private** CoreUI framework. If a future macOS changes it, Iconos falls back to the pixel extractor automatically. Tested on macOS 26 and 27.

---

## ⚙️ Requirements

- **System:** macOS 26 (Tahoe) or later.
- **Architecture:** Apple Silicon (M1 or newer).
- **Permissions:** App Management for Iconos and Iconos Agente.

---

## 🌍 Available Languages

- 🇺🇸 English (en)
- 🇪🇸 Spanish (es)

The app follows your Mac's language. Translations are welcome via pull request (`Recursos/Localizable.xcstrings`).

---

## 🗑 Uninstall

Open **Iconos → Settings → Uninstall Iconos…**. It restores every app's original icon, turns off the agent, removes the Terminal access rules it added (asking for your password once if there are any), deletes its data and moves itself to the Trash. If any app can't be restored, nothing is deleted so you can retry.

---

## 🛠 Build from Source

Requires **Xcode 26** or later (the full Xcode, not only the Command Line Tools, because the app icon is compiled with `actool`).

```bash
git clone https://github.com/asubervirojas/iconos.git
cd iconos
./compilar.sh --crear-firma   # once: creates a local self-signed code-signing identity in your keychain
./compilar.sh --instalar      # builds, signs and installs to ~/Applications
```

> [!TIP]
> macOS remembers App Management by the app's signature. Always sign with the same identity (`ICONOS_FIRMA` sets its name) or macOS will ask for the permission again after each build. `./compilar.sh --release` builds the zip and its SHA-256.

---

## ❓ FAQ

**Does it modify the apps?** Only their custom icon, the same file Finder writes when you paste an icon in Get Info. App code, signatures and `Contents` are not touched.

**What happens when an app updates?** Most updates keep the custom icon. If one removes it, the agent puts it back within a minute. If an update replaced a root-owned app, Iconos notifies you to allow it again.

**Why isn't it on the App Store or notarized?** The App Store doesn't allow apps that modify other apps, and notarization needs a paid Apple Developer account. Iconos is free and open source; you can read every line and build it yourself.

**Does it need internet?** No. It makes no network connections.

---

## 🙏 Credits

Built by **Armando Subervi** with AI assistance from Claude (Anthropic) and Codex (OpenAI).

App names, icons and logos shown belong to their respective owners. Iconos is not affiliated with or endorsed by any of them, or by Apple.

---

## 📄 License

[MIT](LICENSE)
