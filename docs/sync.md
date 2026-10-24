# Sync design

## Purpose and principles

- This note designs row 35 of `docs/features.md`, sidebar and settings sync between the user's Macs. Queue task V.9 in `docs/plan.md` implements it behind a toggle.
- Sync uses the CloudKit private database of the user's Apple Account. Apple's iCloud servers store the records. Arch runs no server, calls no web service of its own, and uses neither the public nor the shared database. The records count against the user's iCloud storage.
- Sync is off by default. While it is off, the `Sync` module creates no CloudKit object and makes no network request.
- `session.json` stays the local source of truth. Every change applies on the Mac first, and sync copies it to the other Macs. A Mac without a network or an iCloud account works as it does without sync.
- Sync uses `CKSyncEngine`, which schedules sends and fetches, keeps the pending changes, retries, and follows account changes. Core Data and SwiftData mirroring are not used, because they would replace `session.json` with their own store.

## What syncs

| Item | Synced values | Stays on each Mac |
|---|---|---|
| Personas | Name, order | Cookies, site data, installed plugins |
| Spaces | Name, symbol, tint, order, Persona | Which space is current |
| Favorites | Address, title, order, Persona | The favorite's live tab (III.13) |
| Pinned tabs | Address, title, the user's tab name, engine, order, space | Restorable page state, the live page |
| Settings | The keys in the settings list below | Every other key |

Open (unpinned) tabs stay on each Mac. They archive after the archive delay and change with every page, so syncing them would open and close tabs on one Mac while the user browses on another.

## What never syncs

- Cookies, site storage, caches, and HTTP authentication credentials. They stay per engine and per Mac. A Persona that arrives from another Mac starts signed out of every site.
- Passwords, passkeys, cards, and addresses. Arch keeps no store for them; Apple Passwords and 1Password sync their own data.
- Keychain items.
- The engines' restorable page state (`TabRecord.state`). It is engine-specific, can be large, and holds the address of every page in the tab's back-forward list.
- Open tabs, the closed-tab list, the selected tab, the current space, window frames, and the sidebar width.
- Browsing history (`history.sqlite`), downloads, captures, and favicons.
- Private API flags (`ARCHPrivateAPIs`, `ARCHPrivateAPI.*`, `ARCHPrivateAPIFeature.*`), whose availability depends on each Mac's macOS version, and per-Mac prompts such as `ARCHAskedDefaultBrowser`.
- Installed plugins and extensions and their storage (rows 44 and 50).

## Container, database, and zone

- One iCloud container, reached through `CKContainer.default()`, which is the first container in the app's entitlements. No container name appears in the code.
- The private database holds one custom zone, `ArchSync1`. A custom zone gives change tokens for fetching only what changed and atomic saves across records. The number in the name is the major schema version (see Schema versions).

## Record types

Record names are unique within the zone, whatever their type.

| Record type | Record name | Fields | Local source |
|---|---|---|---|
| `Persona` | The Persona's UUID; `default` for the default Persona | `name`, `order` | The Persona list (III.12) |
| `Space` | `Space.id` | `persona`, `name`, `symbol`, `tint`, `order` | `SessionSnapshot.spaces` |
| `Favorite` | `Favorite.id` | `persona`, `url`, `title`, `order` | `SessionSnapshot.favorites` |
| `Tab` | The tab record's ID (added below) | `space`, `url`, `title`, `customTitle`, `engine`, `order` | `SessionSnapshot.tabs` with `isPinned` |
| `Setting` | The `UserDefaults` key, such as `ARCHAppearance` | `value` | `UserDefaults.standard` |

Every record also has `modifiedAt` and `schemaVersion`.

- `persona` and `space` are `CKRecord.Reference` values with no delete action. The Mac that deletes a parent also deletes or moves its children in the same batch.
- `order` is a `Double` sort key among the record's siblings: spaces and favorites within their Persona, pinned tabs within their space. A move writes only the moved record, whose key becomes the midpoint of its new neighbors' keys. When no `Double` fits between two neighbors, the Mac renumbers that parent's children in one batch. Equal keys sort by record name.
- `modifiedAt` is the time of the latest local edit of the record on the Mac that wrote it. Conflicts compare it.
- `schemaVersion` is the record format version that wrote the record, starting at 1.
- `url` is the absolute address string; `engine` is the raw value of `EngineKind`; `tint` is the raw value of `SpaceTint`; `value` is the setting's value as a string.
- Every field except the references, `order`, `modifiedAt`, and `schemaVersion` is stored in `encryptedValues`. CloudKit encrypts those fields end to end with keys in the user's iCloud Keychain, so addresses, titles, and names are unreadable on the server. Encrypted fields cannot be queried, and sync never queries: it reads zone changes. CloudKit cannot encrypt references.
- Until III.12 adds Personas, Sync writes one `Persona` record named `default`, and every space and favorite refers to it. III.12 gives the default Persona the record name `default` on every Mac, so two Macs whose older `session.json` files become a default Persona share one record instead of creating two.

### Settings list

| Key | Applied on the receiving Mac |
|---|---|
| `ARCHAppearance` | `Preferences` sets `NSApp.appearance` at once |
| `ARCHDefaultEngine` | `EngineRegistry` reads it for the next new tab |
| `ARCHArchiveAfterHours` | The session reads it at its next archive pass |

A new setting syncs only after it joins this list. V.8 decides each of its settings: a search engine choice can sync, while a downloads folder cannot, because paths differ between Macs.

## Mapping the session store to records

- `session.json` holds no sync fields. `sync.json`, beside it in Application Support, holds the sync engine's state serialization and the last known server record for each synced item (the mirror), archived with secure coding. Deleting `sync.json` makes the next sync a first sync.
- Tabs need stable IDs. `Tab.id` is created at each launch, and `SessionSnapshot.TabRecord` has no ID. The next snapshot version adds `id` to `TabRecord` and restores tabs with it. A file without IDs gives its tabs new ones at load.
- Outgoing changes: after each session save, which already combines changes within 0.5 seconds, Sync builds the syncable view of the snapshot (record name to field values) and compares it with the mirror. Each difference adds a `.saveRecord` or `.deleteRecord` pending change to `CKSyncEngine.State`; a record that changes again before it is sent stays one pending change. Settings changes are found the same way on `UserDefaults.didChangeNotification`. Because changes come from this comparison, edits made while sync was off upload when it is turned on again.
- The record provider builds each outgoing record from the mirror's copy and sets the known fields on it, so fields written by a newer build survive.
- Pinning a tab creates its `Tab` record; unpinning or closing it deletes the record. The record's address and title change when the tab's page finishes loading, as `session.json` does.
- Incoming changes: Sync applies fetched records to `BrowserSession` on the main actor through a few methods (insert or update a Persona, space, favorite, or pinned tab; delete one; apply a setting), then updates the mirror, so an applied change is not sent back. Within one fetch, parents apply before children; a child whose parent has not arrived waits until the fetch ends.
- Applying a change:
  - A new or changed Persona, space, or favorite updates the sidebar at once.
  - A new pinned tab opens in its space without becoming selected. A changed address or engine loads the tab again at once, unless it is the selected tab, which keeps its page and takes the change when the user leaves it. A changed tab name or order applies at once.
  - A deleted pinned tab closes into this Mac's closed list, so ⌘Z and Reopen Closed Tab can bring it back.
  - A deleted space moves this Mac's open tabs to its neighbor, as `deleteSpace` does.
  - A deleted Persona closes its tabs into the closed list and removes its local site data, as a local deletion does (III.12).
- Orphans: after a fetch, a tab whose space is missing moves to the first space of the first Persona, and a space or favorite whose Persona is missing moves to the first Persona. Every Mac picks the same destination, and the Mac that finds the orphan writes the move. A Persona left without spaces gets a new space named Personal, as at first launch.
- Order keys: the local arrays keep the order. The `order` keys live only in the mirror. When the comparison finds siblings out of order, the items that moved get new keys and the others keep theirs.

## First sync on a Mac

- Turning sync on fetches the zone before sending anything.
- An empty zone receives every syncable item from this Mac.
- Otherwise the server's records apply as incoming changes, and local items without a match upload. A local item matches a server record with the same record name. Also, a local space matches a server space with the same name in the same Persona: the local space's tabs move into the server space and the local space is removed. A local favorite matches a server favorite with the same address in the same Persona, and the local one is removed. For settings, the server's value wins for the keys it has.
- The merge goes out in one batch.

## Conflicts

- Sync sends each record with the change tag of its mirror copy. If another Mac saved the record first, CloudKit refuses the save with `serverRecordChanged` and returns the server's record.
- Sync merges that record field by field, with the mirror's copy as the common base. A field changed only on this Mac takes the local value. A field changed only on the server keeps the server's value. A field changed on both sides takes the value from the side with the later `modifiedAt`; on a tie, the server's value stays. Sync applies the merged record locally and sends it with the server's change tag. For a field changed on both sides this is last writer wins, as V.9 asks; a field changed on only one side survives instead of being overwritten.
- A `Setting` record has a fixed name, so two Macs that write the same setting for the first time conflict without a base. Both sides count as changed, and the later `modifiedAt` wins.
- Deletion wins. A save that fails with `unknownItem`, because the record was deleted on the server, applies the deletion locally instead of creating the record again. An incoming deletion drops this Mac's pending save for that record.
- Changes that touch several records, such as deleting a space and moving its tabs, renumbering order keys, or a first-sync merge, go in one batch that CloudKit saves atomically within the zone (`atomicByZone` on `CKSyncEngine.RecordZoneChangeBatch`, needs verification). Other Macs never fetch half of such a change.
- `modifiedAt` comes from each Mac's clock. A Mac whose clock is far ahead can win conflicts it should lose; network time keeps this rare.

## Offline behavior

- Edits land in `session.json` at once. The pending changes live in the sync engine's state, which Sync writes to `sync.json` at every `stateUpdate` event, so they survive quitting and go out after a later launch.
- `CKSyncEngine` retries network failures, rate limits, and service unavailability itself, with the delays CloudKit asks for. Sync handles the failures it can fix: `zoneNotFound` creates the zone and sends again, `serverRecordChanged` merges, and `unknownItem` applies the deletion.
- `CKSyncEngine` fetches when CloudKit sends a change notification and at launch. Sync also calls `fetchChanges()` when the app becomes active, which covers missed notifications.
- A Mac that was offline for weeks sends its pending changes when it reconnects. Conflicts compare `modifiedAt`, so its old edits do not overwrite newer ones from other Macs.

## Accounts and removed data

- Before it creates the sync engine, Sync calls `CKContainer.accountStatus()`. Without an available account, sync stays off and the toggle explains why.
- Signing out of iCloud (`accountChange`, `.signOut`) stops sync, keeps the local sidebar, and deletes `sync.json`. Switching accounts does the same; turning sync on again runs a first sync with the new account, which merges this Mac's sidebar into it. Signing in starts a first sync if the toggle is on.
- When the zone disappears (`fetchedDatabaseChanges` deletions), Sync acts on the reason:
  - `.deleted`: another Mac chose Delete iCloud Data. Sync turns off here and keeps local data.
  - `.purged`: the user removed Arch's data in the system's iCloud settings. Same as `.deleted`.
  - `.encryptedDataReset`: the user reset the end-to-end encryption keys, so the encrypted fields are gone. Sync creates the zone again and uploads this Mac's items, as in a first sync with an empty zone.

## Schema versions

- In the CloudKit Development environment, CloudKit creates record types and fields when a record first uses them. The Production environment needs the schema deployed from CloudKit Console, and deployed record types and fields can never be removed or change type. Schema changes are therefore additive in both environments.
- Within one zone, a new version adds optional fields or record types and raises `schemaVersion`. A missing field means its default: for example, a tab without `engine` uses the default engine. A reader keeps fields it does not know, because outgoing records are built from the mirror's full copy. A record of a type it does not know stays in the mirror untouched, so a later build applies it without fetching the zone again.
- A breaking change, such as a field that changes meaning, moves to a new zone (`ArchSync2`). The first Mac with the new build copies the old zone's records into the new zone in the new format and stops reading the old one. Older builds keep syncing among themselves in the old zone until they are updated.
- `session.json` versions and `schemaVersion` are independent. The snapshot version describes the local file, `schemaVersion` describes the records, and the record mapping is the one place that translates between them.
- Planned additions: folders (III.3) add a `Folder` record type and an optional `folder` reference on `Tab`; per-space home pages (III.10) and themes (III.9) add optional fields on `Space`. Multiple windows (III.6) and split view layouts (III.5) add nothing, because windows and layouts stay on each Mac.

## Requirements

- `CKSyncEngine` needs macOS 14. The package targets macOS 13, so the `Sync` module's types are marked `@available(macOS 14, *)` and the toggle is hidden on macOS 13.
- The iCloud capability needs an Apple Developer Program membership (needs verification for personal teams), an explicit App ID for `local.arch.browser` with iCloud (CloudKit) and Push Notifications, an iCloud container, and a provisioning profile for the build Mac.
- `scripts/bundle_app.sh` embeds the profile as `Contents/embedded.provisionprofile` and signs the app with an entitlements file holding `com.apple.developer.icloud-services` (`CloudKit`), `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.aps-environment`, and the application and team identifiers. Working Rule 8 keeps the team identifier out of the repository, so the script reads these values from the profile at bundle time (`security cms -D`). The helper apps are signed first without these entitlements, because `codesign --deep` would give them to every helper. IV.14 needs the same profile step for its passkey entitlement.
- Without the container entitlement, as with ad hoc signing, `CKContainer.default()` raises an exception. Sync therefore reads its own entitlements through `SecTaskCopyValueForEntitlement` first; if the entitlement is missing, the toggle is disabled and says that the build is not signed for iCloud.
- While sync is on, the app calls `NSApplication.registerForRemoteNotifications()` so CloudKit's change notifications reach the sync engine (needs verification of what `CKSyncEngine` needs on macOS beyond this).

## User interface

- A Sync section in Settings (V.8) has a Sync with iCloud toggle, the account state, the time of the last completed sync, and the last error in plain words. Sync reports nothing anywhere else and sends no usage data.
- Turning sync off stops the engine and keeps local data, iCloud data, and `sync.json`, so turning it on again resumes from the saved change token.
- Delete iCloud Data, after a confirmation sheet, deletes the zone, which removes the data for every Mac, and turns sync off. Local data stays. Other Macs turn sync off at their next fetch.

## Module layout

| File | Role |
|---|---|
| `Packages/ARCH/Sources/Sync/SyncController.swift` | Owns the toggle, the entitlement and account checks, and the `CKSyncEngine`; handles its events |
| `Packages/ARCH/Sources/Sync/SyncRecords.swift` | Maps Personas, spaces, favorites, pinned tabs, and settings to `CKRecord` values and back |
| `Packages/ARCH/Sources/Sync/SyncMirror.swift` | Reads and writes `sync.json`: the state serialization and the last known records |

- `Sync` depends on `Browsing`, `Preferences`, `ARCHEngine`, and CloudKit. `Package.swift` adds one target.
- `Browsing` does not import CloudKit. It provides stable tab IDs, a callback after each save, and the methods that apply incoming changes.
- `AppDelegate` creates the controller after the session and registers for remote notifications while sync is on.
- Verification needs two Macs signed in to the same Apple Account, or one Mac and the record browser in CloudKit Console.

## Open decisions

1. Tabs: only pinned tabs sync (this note), or open tabs too.
2. A pinned tab's address follows its page (this note), or stays at the address it had when pinned.
3. Conflicts merge field by field with last writer wins per field (this note), or strictly per record as V.9 states.
4. The first sync merges spaces by name and favorites by address (this note), or keeps every item from both Macs.
5. Switching iCloud accounts merges the local sidebar into the new account (this note), or starts the Mac from the new account's data only.
6. CloudKit environment: Production with the schema deployed from CloudKit Console, or Development, which an Apple Development signed build uses by default (needs verification for selecting Production with `com.apple.developer.icloud-container-environment`).
7. macOS 13: hide sync there (this note), or raise the package's deployment target to macOS 14.
8. A Persona deleted on another Mac removes this Mac's site data for it (this note), or keeps that data until the user removes it.
9. Browsing history: never syncs (this note), or a later `Visit` record type.
