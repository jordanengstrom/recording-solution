# Screen Recorder

A minimal, local-only macOS screen recorder. It mirrors the entire built-in
MacBook display into a synthesized, click-through full-screen window, records
that window as a silent H.264 MP4, and saves it to the Desktop.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode command-line tools
- A local self-signed code-signing identity (created by the setup command below)

## First-time setup

```bash
cd /Users/jordan/dev/recording-solution/screen-recorder
./setup-local-signing.sh
./install.sh
./reset-screen-permission.sh
./run.sh
```

`setup-local-signing.sh` creates a ten-year, self-signed Code Signing identity
named `Screen Recorder Local Signing` in the login keychain. The certificate and
private key stay on this Mac; nothing is requested from or uploaded to Apple.
macOS may ask you to approve Keychain access during signing.

`install.sh` always installs the signed runnable copy at
`~/Applications/ScreenRecorder.app`. Use `run.sh` rather than launching the copy
under `build/`, so System Settings consistently refers to the installed app.

`reset-screen-permission.sh` is a one-time migration from the old ad-hoc signed
build. It asks for confirmation and resets permission only for the
`com.jordan.screenrecorder` bundle identifier.

On first use, click **Grant Screen Recording Access**. If access is denied or
macOS opens System Settings, enable **Screen Recorder** under **System Settings →
Privacy & Security → Screen & System Audio Recording**, then use **Quit & Reopen**
in the app. The app rechecks permission whenever it becomes active.

## Rebuild after source changes

```bash
cd /Users/jordan/dev/recording-solution/screen-recorder
./install.sh
./run.sh
```

Because every build is signed with the same local identity and bundle identifier,
normal rebuilds retain the previously granted Screen Recording permission.

Use the single button (or `Command-Space` while the app is active) to start and
stop recording. Wait for **Recording Saved** before quitting or opening the MP4.

While recording, a live proxy window covers the display but passes all mouse
input through to the real applications underneath. The small recorder control
stays above the proxy so it can be stopped, but it is not included in the MP4.

Recordings are named `Screen Recording YYYY-MM-DD at HH.mm.ss.mp4` and appear on
the Desktop. The app has no microphone, audio, network, or server dependency.
