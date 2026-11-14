# Sync design

## Purpose and principles

- This note designs sidebar and settings sync between the user's Macs, row 35 of `docs/features.md`. Queue task V.9 in `docs/plan.md` implements it behind a toggle.
- Sync uses the CloudKit private database of the user's Apple Account. Apple's iCloud servers store the records. Arch runs no server, calls no web service of its own, and uses neither the public nor the shared database. The records count against the user's iCloud storage.
- Sync is off by default. While off, the `Sync` module creates no CloudKit object and makes no network request.
- `session.json` stays the local source of truth. Changes apply on the Mac first. Sync copies them to the other Macs. A Mac without a network or an iCloud account works as it does without sync.
- Sync uses `CKSyncEngine` to schedule sends and fetches, keep pending changes, retry, and follow account changes. It does not use Core Data or SwiftData mirroring because they would replace `session.json` with their own store.

## What syncs

| Item | Synced values | Stays on each Mac |
|---|---|---|
| Personas | Name, order | Cookies, site data, installed plugins |
| Spaces | Name, symbol, tint, order, Persona | Which space is current |
| Favorites | Address, title, order, Persona | The favorite's live tab (III.13) |
| Pinned tabs | Address, title, the user's tab name, engine, order, space | Restorable page state, the live page |
| Settings | The keys in the settings list below | Every other key |

Open (unpinned) tabs stay on each Mac. They archive after the archive delay and change with every page. Syncing them would open and close tabs on one Mac while the user browses on another.

## What never syncs

- Cookies, site storage, caches, and HTTP authentication credentials. They stay separate for each engine and Mac. A Persona that arrives from another Mac starts signed out of every site.
- Passwords, passkeys, cards, and addresses. Arch does not store them. Apple Passwords and 1Password sync their own data.
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

Record names are unique within the zone, regardless of type.

| Record type | Record name | Fields | Local source |
|---|---|---|---|
| `Persona` | The Persona's UUID; `default` for the default Persona | `name`, `order` | The Persona list (III.12) |
| `Space` | `Space.id` | `persona`, `name`, `symbol`, `tint`, `order` | `SessionSnapshot.spaces` |
| `Favorite` | `Favorite.id` | `persona`, `url`, `title`, `order` | `SessionSnapshot.favorites` |
| `Tab` | The tab record's ID (added below) | `space`, `url`, `title`, `customTitle`, `engine`, `order` | `SessionSnapshot.tabs` with `isPinned` |
| `Setting` | The `UserDefaults` key, such as `ARCHAppearance` | `value` | `UserDefaults.standard` |

Every record also has `modifiedAt` and `schemaVersion`.

- `persona` and `space` are `CKRecord.Reference` values with no delete action. The Mac that deletes a parent also deletes or moves its children in the same batch.
- `order` is a `Double` sort key among the record's siblings: spaces and favorites within their Persona, pinned tabs within their space. A move writes only the moved record. Its key becomes the midpoint of its new neighbors' keys. When no `Double` fits between two neighbors, the Mac renumbers that parent's children in one batch. Equal keys sort by record name.
- `modifiedAt` is the record's latest local edit time on the Mac that wrote it. Conflicts compare this time.
- `schemaVersion` is the record format version that wrote the record, starting at 1.
- `url` is the absolute address string; `engine` is the raw value of `EngineKind`; `tint` is the raw value of `SpaceTint`; `value` is the setting's value as a string.
- Sync stores every field except the references, `order`, `modifiedAt`, and `schemaVersion` in `encryptedValues`. CloudKit encrypts those fields end to end with keys in the user's iCloud Keychain. The server cannot read addresses, titles, or names. Encrypted fields cannot be queried, and sync never queries: it reads zone changes. CloudKit cannot encrypt references.
- The default Persona, `Persona.defaultID` (`D59DAF4B-E372-4AF9-890E-455B8B3860F3`), has the record name `default` on every Mac, and every other Persona its UUID string. Two Macs that converted older `session.json` files to the default Persona therefore share one record instead of creating two.

### Settings list

| Key | Applied on the receiving Mac |
|---|---|
| `ARCHAppearance` | `Preferences` sets `NSApp.appearance` at once |
| `ARCHDefaultEngine` | `EngineRegistry` reads it for the next new tab |
| `ARCHArchiveAfterHours` | The session reads it at its next archive pass |

A new setting syncs only after it joins this list. V.8 decides which of its settings sync. A search engine choice can sync; a downloads folder cannot because paths differ between Macs.

## Mapping the session store to records

- `session.json` holds no sync fields. `sync.json`, beside it in Application Support, holds the sync engine's state serialization and the last known server record for each synced item (the mirror), archived with secure coding. Deleting `sync.json` makes the next sync a first sync.
- Tabs need stable IDs. `Tab.id` is created at each launch, and `SessionSnapshot.TabRecord` has no ID. The next snapshot version adds `id` to `TabRecord` and uses it to restore tabs. Tabs from a file without IDs get new ones at load.
- Outgoing changes: session saves already combine changes within 0.5 seconds. After each save, Sync maps syncable snapshot items from record names to field values and compares them with the mirror. Each difference adds a `.saveRecord` or `.deleteRecord` pending change to `CKSyncEngine.State`. A record that changes again before sending remains one pending change. Sync finds settings changes the same way on `UserDefaults.didChangeNotification`. This comparison includes edits made while sync was off, so they upload when it turns on again.
- The record provider builds outgoing records from the mirror's copy and sets the known fields. Fields written by newer builds survive.
- Pinning a tab creates its `Tab` record. Unpinning or closing it deletes the record. The record's address and title change when the tab's page finishes loading, as `session.json` does.
- Incoming changes: Sync applies fetched records to `BrowserSession` on the main actor through a few methods to insert, update, or delete a Persona, space, favorite, or pinned tab, or apply a setting. It then updates the mirror so applied changes are not sent back. Within a fetch, parents apply before children. A child whose parent has not arrived waits until the fetch ends.
- Applying a change:
  - A new or changed Persona, space, or favorite updates the sidebar at once.
  - A new pinned tab opens in its space without becoming selected. A changed address or engine reloads an unselected tab at once. The selected tab keeps its page and applies the change when the user leaves it. A changed tab name or order applies at once.
  - A deleted pinned tab closes into this Mac's closed list, so ⌘Z and Reopen Closed Tab can bring it back.
  - A deleted space moves this Mac's open tabs to its neighbor, as `deleteSpace` does.
  - A deleted Persona closes its tabs into the closed list and removes its local site data, as a local deletion does (III.12).
- Orphans: after a fetch, a tab whose space is missing moves to the first space of the first Persona. A space or favorite whose Persona is missing moves to the first Persona. Every Mac picks the same destination. The Mac that finds the orphan writes the move. A Persona left without spaces gets a new space named Personal, as at first launch.
- Order keys: the local arrays keep the order. The `order` keys live only in the mirror. When the comparison finds siblings out of order, moved items get new keys. The others keep theirs.

## First sync on a Mac

- Turning sync on fetches the zone before sending anything.
- An empty zone receives every syncable item from this Mac.
- Otherwise the server's records apply as incoming changes. Local items without a match upload. A local item matches a server record with the same record name. A local space also matches a server space with the same name in the same Persona. The local space's tabs move to the server space, and the local space is removed. A local favorite matches a server favorite with the same address in the same Persona, and the local one is removed. For settings, the server's value wins for the keys it has.
- The merge goes out in one batch.

## Conflicts

- Sync sends each record with the change tag of its mirror copy. If another Mac saved the record first, CloudKit refuses the save with `serverRecordChanged` and returns the server's record.
- Sync merges that record field by field, with the mirror's copy as the common base. A field changed only on this Mac takes the local value. A field changed only on the server keeps the server's value. A field changed on both sides takes the value from the side with the later `modifiedAt`. On a tie, the server's value stays. Sync applies the merged record locally and sends it with the server's change tag. For fields changed on both sides, the last writer wins, as V.9 asks. Fields changed on only one side survive.
- A `Setting` record has a fixed name. Two Macs that first write the same setting therefore conflict without a base. Both sides count as changed, and the later `modifiedAt` wins.
- Deletion wins. If a save fails with `unknownItem`, meaning the server record was deleted, Sync applies the deletion locally instead of recreating the record. An incoming deletion drops this Mac's pending save for that record.
- Changes to several records go in one batch that CloudKit saves atomically within the zone (`atomicByZone` on `CKSyncEngine.RecordZoneChangeBatch`, needs verification). Examples include deleting a space and moving its tabs, renumbering order keys, and first-sync merges. Other Macs never fetch half of a change.
- `modifiedAt` comes from each Mac's clock. A Mac whose clock is far ahead can win conflicts it should lose. Network time keeps this rare.

## Offline behavior

- Edits go into `session.json` at once. Pending changes live in the sync engine's state, which Sync writes to `sync.json` at every `stateUpdate` event. They survive quitting. Sync sends them after a later launch.
- `CKSyncEngine` retries network failures, rate limits, and service unavailability using CloudKit's requested delays. Sync handles the failures it can fix: `zoneNotFound` creates the zone and sends again, `serverRecordChanged` merges, and `unknownItem` applies the deletion.
- `CKSyncEngine` fetches when CloudKit sends a change notification and at launch. Sync also calls `fetchChanges()` when the app becomes active to cover missed notifications.
- A Mac that was offline for weeks sends its pending changes when it reconnects. Conflicts compare `modifiedAt`, so its old edits do not overwrite newer ones from other Macs.

## Accounts and removed data

- Before it creates the sync engine, Sync calls `CKContainer.accountStatus()`. Without an available account, sync stays off and the toggle explains why.
- Signing out of iCloud (`accountChange`, `.signOut`) stops sync, keeps the local sidebar, and deletes `sync.json`. Switching accounts does the same. Turning sync on again runs a first sync with the new account and merges this Mac's sidebar into it. Signing in starts a first sync if the toggle is on.
- When the zone disappears (`fetchedDatabaseChanges` deletions), Sync acts on the reason:
  - `.deleted`: another Mac chose Delete iCloud Data. Sync turns off here and keeps local data.
  - `.purged`: the user removed Arch's data in the system's iCloud settings. Same as `.deleted`.
  - `.encryptedDataReset`: the user reset the end-to-end encryption keys, so the encrypted fields are gone. Sync creates the zone again and uploads this Mac's items, as in a first sync with an empty zone.

## Schema versions

- In the CloudKit Development environment, CloudKit creates record types and fields when a record first uses them. The Production environment needs the schema deployed from CloudKit Console. Deployed record types and fields can never be removed or change type. Schema changes are therefore additive in both environments.
- Within one zone, a new version adds optional fields or record types and raises `schemaVersion`. A missing field means its default: for example, a tab without `engine` uses the default engine. A reader keeps unknown fields because it builds outgoing records from the mirror's full copy. Records of unknown types stay in the mirror untouched. A later build applies them without fetching the zone again.
- A breaking change, such as a field that changes meaning, moves to a new zone (`ArchSync2`). The first Mac with the new build copies the old zone's records into the new zone in the new format. It then stops reading the old zone. Older builds keep syncing among themselves in the old zone until they are updated.
- `session.json` versions and `schemaVersion` are independent. The snapshot version describes the local file; `schemaVersion` describes the records. Only the record mapping translates between them.
- Planned additions: folders (III.3) add a `Folder` record type and an optional `folder` reference on `Tab`; per-space home pages (III.10) and themes (III.9) add optional fields on `Space`. Multiple windows (III.6) and split view layouts (III.5) add nothing, because windows and layouts stay on each Mac.

## Requirements

- `CKSyncEngine` needs macOS 14, the package's deployment target.
- The iCloud capability needs an Apple Developer Program membership (Arch's team is an individual one), an explicit App ID for `xyz.taeyoon.arch` with iCloud (CloudKit) and Push Notifications, the iCloud container `iCloud.xyz.taeyoon.arch`, and a provisioning profile of the signing identity's kind: a Developer ID profile, or a development profile that lists the build Mac.
- `scripts/provision_app.sh` gets both profiles through Xcode's automatic signing of a stand-in project with the bundle identifier and the entitlements, which it writes to a temporary folder: the development profile through a build that registers the Mac, and the Developer ID profile through an archive exported with the `developer-id` method. Xcode signs in with its account or an App Store Connect API key. In its runs on the current Mac, automatic signing from the command line turned on iCloud and push for the App ID but did not assign the container to it: Xcode's first profiles listed no container, and its builds failed because the profile did not match the entitlements file's `com.apple.developer.icloud-container-identifiers`. The container is created once in Certificates, Identifiers & Profiles ▸ Identifiers ▸ iCloud Containers and assigned in the App ID's iCloud capability; the script explains these steps when a build or a profile lacks the container. Once the container was assigned, Xcode's next profiles listed it, and the current Mac has both profiles; a bundle signed with one is checked under V.14 in `docs/plan.md`. The export writes distribution logs that name the team and the certificate's holder into the Darwin user temporary folder, whatever `TMPDIR` says, and the script removes the ones each run adds.
- `scripts/bundle_app.sh` embeds the newest profile that suits the signing identity as `Contents/embedded.provisionprofile` and signs the app with entitlements written to `build/Arch.entitlements` from those the profile grants: the application and team identifiers; `com.apple.developer.icloud-services` (`CloudKit`), `com.apple.developer.icloud-container-identifiers`, and `com.apple.developer.icloud-container-environment` (when the profile lists environments) when the profile grants the container and CloudKit; and `com.apple.developer.aps-environment` when it grants push. The script names the container, the CloudKit environment, and the push environment that the app got, and warns when the profile grants no container, so a bundle without iCloud does not pass for one with it. Working Rule 8 keeps the team identifier out of the repository, so the script reads these values from the profile at bundle time (`security cms -D`). It signs the helper apps and the framework first without these entitlements, which `codesign --deep` would give to every helper. Without a suitable profile it signs the app without entitlements. IV.14 adds its passkey entitlement to the ones the script copies.
- Without the container entitlement, as with ad hoc signing, `CKContainer.default()` raises an exception. Sync therefore reads its own entitlements through `SecTaskCopyValueForEntitlement` first. If the entitlement is missing, the toggle is disabled and says the build is not signed for iCloud.
- While sync is on, the app calls `NSApplication.registerForRemoteNotifications()` so CloudKit's change notifications reach the sync engine (needs verification of what `CKSyncEngine` needs on macOS beyond this).

## User interface

- A Sync section in Settings (V.8) has a Sync with iCloud toggle, the account state, the time of the last completed sync, and the last error in plain words. Sync reports nothing anywhere else and sends no usage data.
- Turning sync off stops the engine and keeps local data, iCloud data, and `sync.json`. Turning it on again resumes from the saved change token.
- After a confirmation sheet, Delete iCloud Data deletes the zone and turns sync off. This removes iCloud data for every Mac. Local data stays. Other Macs turn sync off at their next fetch.

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
6. CloudKit environment: Production with the schema deployed from CloudKit Console, or Development, which an Apple Development signed build uses by default (needs verification for selecting Production with `com.apple.developer.icloud-container-environment`). Until this is decided, `scripts/bundle_app.sh` writes Production for a Developer ID identity, as Xcode's export does, and Development for an Apple Development identity; `ARCH_SIGN_IDENTITY` chooses the identity.
7. macOS 13: not supported, because the package targets macOS 14 (decided with open decision 1 of `docs/windows-personas.md`).
8. A Persona deleted on another Mac removes this Mac's site data for it (this note), or keeps that data until the user removes it.
9. Browsing history: never syncs (this note), or a later `Visit` record type.
