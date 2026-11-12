# Local Demo

A macOS app that serves one or more folders of static websites and shares them with any device on your network (phone, tablet, another computer). Drop the folders in, click **Start** and scan the QR code with your phone, no Terminal needed.

![Local Demo in action: drop a folder, click Start and scan the QR code to open the site on your phone, run several sites at once and protect one with a password](docs/demo.gif)

## Features

- Add folders by dropping them on the window or choosing them from the “Add folder” card, one or several at a time.
- Shows each folder as a card in a horizontal carousel, with its own port (8000, 8001, 8002… by default, editable from the “…” menu).
- Start and stop each folder separately.
- While a folder is running, its card shows a QR code, its network address (for example `http://192.168.1.15:8000`) to copy, and buttons to open it in the browser or share it.
- If the chosen port is already taken (by another folder, another app or another user of this Mac), it switches to the next free one and says so on the card.
- Give each folder its own name (double-click the title, or “…” > “Rename…”) without renaming it on disk.
- Protect each folder with a password (“…” > “Set Password…”). Visitors see a page where they enter it.
- Never serves hidden files (`.git`, `.env`, `.DS_Store`…) or files outside the folder through symbolic links.
- Remembers the folders and their ports, and stops every server when you close the window.
- Shows a short tour of these features the first time it opens. Skip it or go through it, and see it again any time from **Help > Local Demo Tour**.
- Supports light and dark mode.
- Available in English, Spanish and Catalan. The app follows your Mac’s language: Catalan if it’s Catalan, Spanish if it’s Spanish or another language of Spain (Galician, Basque…), English otherwise. The password page uses the same language as the app.

## Requirements

- macOS 14 (Sonoma) or later.
- Xcode Command Line Tools, which include `swiftc` and `python3`. If you don’t have them:

  ```bash
  xcode-select --install
  ```

## Build and install

1. Clone the repository and open its folder.
2. Run the build script. It builds the app and installs it in `~/Applications`, replacing any previous version:

   ```bash
   ./build.sh
   ```

### First launch

- If macOS asks whether to allow incoming connections for Python, click **Allow**. Otherwise other devices can’t connect.
- Devices must be on the same Wi‑Fi. Some guest and corporate networks block traffic between devices.

## How it works

The app is a SwiftUI interface on top of Python’s built-in web server (`http.server`). Each folder runs its own `/usr/bin/python3` process with a small server included in `LocalDemoApp.swift`, which adds the password and blocks hidden files. If the app quits unexpectedly, the servers stop by themselves.

Each Mac has its own ports: if several people use Local Demo on their Macs, all of them can use port 8000 at the same time without conflict, because each Mac has its own address.

| File | Contents |
|---|---|
| `LocalDemoApp.swift` | The whole app: window, server management, local IP, QR code and texts in each language |
| `logo.png` | App logo |
| `make_icon.swift` | Turns the logo into the macOS icon (rounded shape and margin) |
| `Info.plist` | App name, identifier, version and languages |
| `build.sh` | Builds the app, generates the icon, signs it locally and installs it in `~/Applications` |
| `docs/` | Demo animation and screenshots for this README |

To test without using the interface, set `LOCALDEMO_AUTOSTART=1` and the app starts serving every saved folder when it opens. To force a language, set `LOCALDEMO_LANG` to `en`, `es` or `ca`.

## Security

Local Demo is meant for showing work in progress on a trusted network, for a short while. Keep the following in mind, especially in an office:

- **Anyone on the same network can open the site** if they know or guess the address. Without a password, everything in the folder is visible to that network. Serve only the project folder, never your home folder or your whole desktop.
- **The connection isn’t encrypted (HTTP, not HTTPS).** The password and the pages travel unencrypted over the Wi‑Fi, so someone with the right tools on the same network could see them. The password stops casual visitors, not attacks. Don’t share confidential content this way (customer data, credentials, unannounced products on guest networks).
- **The password is stored unencrypted** in the app’s preferences. Use a password just for this (the “Generate” button creates one) and don’t reuse a personal one.
- **Stop the servers when you’re done.** While they’re running, the folder is open on the network.
- **Check your company’s rules.** Some corporate networks don’t allow servers on laptops, or block traffic between devices.

## License

[MIT](LICENSE). You can use, copy, modify and share this project for any purpose, as long as you keep the copyright and license notice.
