# BetterSonos

BetterSonos is a native SwiftUI app for iOS that provides a clean, fast, and highly configurable interface for controlling your Sonos speakers through the `node-sonos-http-api`. It is highly optimized for playing Sonos Favorites, internet radio streams, and Line In sources - and not for finding and playing content from Spotify or other music subscription services.

## Motivation

I created BetterSonos for two reasons:

* **I listen to a lot of Internet Radio** Sonos supports connecting to all kinds of streams out there on the internet, but adding custom ones is *painful*. This app makes it a breeze, and cuts TuneIn out of the loop.
* **Sonos' App Is Getting Worse** Much has been made about the changes to the Sonos app, and it even cost the CEO his job! I wanted a client that was clean and fast, focused on my use cases. This is it.

## Key Features

* **Multi-Network Support:** Seamlessly switch between different Sonos systems (e.g., home, office) that have their own `node-sonos-http-api` server.
* **Standard Playback Controls:** Play, pause, adjust volume, and manage speaker groups.
* **Advanced Preset Management:** Consolidate presets from multiple sources:
    * Sonos Favorites
    * Manually entered radio streams
    * Custom remote CSV files
    * A default list of popular streams.
* **Line-In Support:** Enable and assign custom names to Line-In sources on your network.
* **Configurable UI:** Choose which preset sources to display for each network and disable volume controls for specific speakers (like a Sonos Port/Connect).
* **Dark Mode Support:** Fully supports light and dark mode for a great user experience.

## Screenshots
![Light Mode](.github/assets/light.png) | ![Dark Mode](.github/assets/dark.png)

## Requirement: The Backend API

**This app is a client and does NOT work on its own.** It requires you to be running an instance of the excellent **[node-sonos-http-api by jishi](https://github.com/jishi/node-sonos-http-api)** on your local network. This can be hosted on a Raspberry Pi, a home server, or any always-on computer.

## How to Use

1.  Clone this repository.
2.  Open `BetterSonos.xcodeproj` in Xcode.
3.  Build and run the app on your iPhone or iPad.
4.  When the app launches, add a new network and point the "Base URL" to the address of your `node-sonos-http-api` server (e.g., `http://192.168.1.10:5005`).

## Miscellany

This app was built with Xcode 16 and targets iOS 17 and up.

## Contributing

Contributions and enhancements are welcome! If you have a bug to report or a feature to suggest, please open an issue. If you'd like to contribute code, please open a pull request.

## License

This project is distributed under the terms of the GNU General Public License, v3. See the [LICENSE](LICENSE) file for details.
