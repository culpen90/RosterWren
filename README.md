# RosterWren

RosterWren is an experimental native macOS utility designed to watch meetings running in the Zoom Workplace desktop app and save a local participant roster. As a menu-bar companion, it is intended to detect a Zoom meeting after explicit user consent and macOS Accessibility access, open the Participants panel automatically when needed, accumulate names as people join or leave, and continually checkpoint the roster.

RosterWren captures no audio, video, chat messages, screenshots, or meeting credentials, and it makes no network requests. Roster files use an app-owned folder under Application Support by default. If the user chooses another location, RosterWren uses a dedicated `RosterWren Meetings` child there; a synced location may upload the files through that service.

## Current integration

Zoom's official Plugin SDK is the preferred long-term integration because it exposes meeting status, participant IDs, display names, and join/leave callbacks over IPC with the installed Zoom client. Zoom distributes that SDK only through a Zoom Marketplace General app, and initialization requires an OAuth access token with Plugin SDK access. Those private SDK files and app credentials are not available in this repository.

The runnable build therefore uses a deliberately narrow, experimental Accessibility fallback. Its parser, coordinator, and storage behavior are covered by deterministic tests, and the relevant Accessibility identifiers were structurally inspected against Zoom 7.1.0. End-to-end capture of real participant names in a live meeting has not yet been validated.

- It inspects only the Zoom process with bundle identifier `us.zoom.xos`, traversing structural Accessibility attributes to locate the meeting, participant panel, and reveal controls.
- It recognizes the active meeting by Zoom's `zm.meeting.window.main` accessibility identifier.
- It requests `AXValue` text only inside participant rows identified by `ZMHCTableItemType_PANELIST`; group headings, invited-but-absent rows, and text elsewhere in Zoom are not read as participant names.
- It may press Zoom's Participants control automatically once per detected meeting, after explicit user consent. It can also press it whenever the user explicitly chooses **Open Participants Now**; automatic capture never repeatedly reopens a panel the user closes.
- It never logs participant names.

The Zoom-specific source is isolated from roster reconciliation and storage so an official Plugin SDK source can replace it without changing the app or export format.

## Requirements

- macOS 14 or newer
- Xcode 26 or another toolchain capable of Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Zoom Workplace for macOS (the experimental fallback was structurally checked against Zoom 7.1.0 but remains live-meeting unverified)

## Build

```sh
make test
make app
```

`make app` writes a versioned universal DMG, app ZIP, dSYM archive, and SHA-256 checksum file under `dist/`. For example, the default build produces `dist/RosterWren-0.1.0-macOS-universal.dmg`. Open the image and move RosterWren to a stable location such as `/Applications` before granting Accessibility access.

For a local build, the package script automatically uses an installed Apple Development identity when one is available. This gives macOS a stable designated requirement so Accessibility access continues to match rebuilt versions of the app. Set `MACOS_DEVELOPMENT_SIGNING_IDENTITY` to select a specific local identity. If no stable identity is available, packaging falls back to an ad-hoc signature and warns that Accessibility access may need to be removed and granted again after each rebuild. A public release still requires a Developer ID identity, timestamping, and notarization.

## Automatic releases

Pushes to `main` are verified and evaluated by Semantic Release. The first successful run bootstraps the existing `0.1.0` version; after that, Conventional Commits choose the next version automatically:

- `fix:`, `perf:`, and `revert:` publish a patch release.
- `feat:` publishes a minor release.
- `!` or a `BREAKING CHANGE:` footer publishes a major release.
- `build:`, `chore:`, `ci:`, `docs:`, `refactor:`, `style:`, and `test:` do not publish a release by themselves.

Each immutable GitHub Release includes generated notes, a universal macOS DMG, a direct app ZIP, dSYMs, and SHA-256 checksums. Public automation fails closed until Developer ID signing and Apple notarization secrets are configured. A maintainer can explicitly opt into visibly warned development-only releases with the `ALLOW_ADHOC_RELEASES` repository variable. See [docs/RELEASING.md](docs/RELEASING.md) for the release contract and signing setup.

## Use

1. Launch RosterWren and review the local-data notice.
2. Select **Enable Roster Capture**. macOS will ask for Accessibility access.
3. If necessary, enable RosterWren in **System Settings → Privacy & Security → Accessibility**, then relaunch it.
4. Leave RosterWren running in the menu bar and join a meeting in the regular Zoom Workplace app.
5. Use **Open Roster Folder** to view the live checkpoint and completed CSV/JSON files.

macOS grants Accessibility access to a specific signed copy of an app. If RosterWren remains blocked even though an entry is enabled, quit it with **Quit RosterWren** from its menu-bar menu, remove stale RosterWren entries in Accessibility settings, add the final `/Applications/RosterWren.app` copy, and reopen it. Closing the main window does not quit the menu-bar app. Do not grant access to the copy still inside the mounted disk image.

By default, RosterWren stores rosters in its Application Support directory. If you choose another location, it creates a dedicated `RosterWren Meetings` child there and does not change the parent folder's permissions. It writes a unique directory there for each detected meeting. During a meeting it atomically replaces each of `meeting.json.inprogress` and `participants.csv`; after the meeting ends it publishes `meeting.json`, refreshes the CSV, and removes the checkpoint. Files and app-owned directories use owner-only permissions.

A normal Quit waits for in-flight capture work and finalizes an active roster before the app exits; if final saving fails, Quit is cancelled and capture resumes when it was enabled. A crash, force quit, or power loss can leave the most recent recoverable checkpoint instead.

## Accuracy limits

Accessibility is not a supported Zoom attendance API. The result is a locally observed roster, not an authoritative attendance report:

- Zoom may change its UI identifiers or virtualize a long participant list.
- Participants who leave before RosterWren starts cannot be recovered.
- First- and last-seen times are approximate polling times.
- Zoom Accessibility does not provide a dependable account ID. Simultaneous duplicate display names are preserved, but renames and re-joins cannot always be linked to the same person.
- The participant panel may need to become visible before Zoom exposes every row.

Use the tool only where you are authorized to retain participant names. Zoom does not notify participants that this separate app is saving a roster. A folder inside iCloud Drive or another sync service is no longer local-only.

## Official Zoom Plugin SDK path

To replace the fallback with Zoom's supported source:

1. Create a Zoom Marketplace **General app**.
2. Under **Features → Access**, enable **Plugin SDK**, select macOS, and download the SDK package.
3. Add `plugin_sdk:read:connection_meta`, configure native OAuth with PKCE, and obtain user authorization.
4. Embed and re-sign the downloaded `PSDKLibs` with the app's signing identity.
5. Implement the participant source with `getMeetingStatus()`, `getParticipantsList()` / `getAttendeeList()`, `onMeetingStatusChanged`, and `onUserStatusChanged`.

See Zoom's [Plugin SDK overview](https://developers.zoom.us/docs/plugin-sdk/), [macOS setup](https://developers.zoom.us/docs/plugin-sdk/macos/get-started/), and [in-meeting participant API](https://developers.zoom.us/docs/plugin-sdk/macos/add-features/in-meeting-user-info/).

## Independence

RosterWren is an independent project and is not affiliated with, endorsed by, or sponsored by Zoom Communications, Inc.

## License

No open-source license is currently granted. Public availability of this source code does not grant permission to copy, modify, or redistribute it. All rights are reserved by the copyright holder.
