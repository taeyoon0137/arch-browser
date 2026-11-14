# Sync design

## Purpose and principles

- Sync copies the sidebar and settings between the user's Macs (row 35 of `docs/features.md`). The `Sync` module holds its record model and merge. Queue tasks V.9.3 to V.9.14 in `docs/plan.md` build the rest behind a toggle in Module layout order.
- Sync uses the CloudKit private database of the user's Apple Account. Apple's iCloud servers store the records. Arch runs no server, calls no web service of its own, and uses neither the public nor the shared database. The records count against the user's iCloud storage.
- Sync is off by default. While off, the `Sync` module creates no CloudKit object and makes no network request.
- `session.json` stays the local source of truth. Changes apply on the Mac first. Sync copies them to the other Macs. Without a network or an iCloud account, the Mac works as it does without sync.
- Sync uses `CKSyncEngine` to schedule sends and fetches, keep pending changes, retry, and follow account changes. It does not use Core Data or SwiftData mirroring because they would replace `session.json` with their own store.
- Sync labels follow Persona rule 7 of `docs/windows-personas.md`: a space named with its Persona shows as "Persona / Space" (`BrowserSession.label(ofSpace:)`, III.15).

## Facts this design relies on

### Arch today

- `session.json` is at snapshot version 12 on `main`. The bookmarks lane uses version 13 for saved pages (III.16) and version 14 for folder parents (III.18). Every tab record has had an ID since version 8. Restoring a tab keeps it as `Tab.id`, so tab IDs serve as record names.
- Folders (`TabFolder`, version 6) group a space's pinned or open tabs. From III.18 they nest through `parentID`, up to four levels (bookmark rule 6 of `docs/bookmarks.md`). Each space has a home page (`Space.homeURL`, version 4).
- From III.16 a pinned tab keeps a saved page: an address and a title (bookmark rule 2). Pinning sets it. Use Current Page as Saved Page and Edit Saved Address… change it. For a tab pinned without an address, the first address its page reports also changes it. The tab's current address changes with every page. A favorite's `url` and `title` are its saved page. From III.17, closing a pinned tab unloads it and keeps it pinned; Delete Tab removes it.
- A tab keeps its Persona for life (`Tab.personaID`), and every move between spaces stays within the Persona (risk R11 of `docs/windows-personas.md`).
- `deleteSpace` moves a space's pinned and open tabs and its folders to the space's neighbor in the same Persona. It refuses a Persona's last space. `deletePersona` closes the Persona's tabs into the closed list and removes its site data at the next launch.
- Settings stores its choices in `UserDefaults`. Download settings apply to every engine context through `UserDefaults.didChangeNotification`. Appearance applies only at launch and in Settings' `onChange`.
- The Settings window lists General, Site Search, Sidebar, Appearance, Shortcuts, Websites, Plugins, and AI. `Preferences` depends on `Browsing`. The Delete Persona sheet's text is in `BrowserWindowModel.swift`.
- `scripts/bundle_app.sh` signs the app with `codesign --deep`, without entitlements or a provisioning profile.
- The `Sync` module holds `SyncRecord`, `SyncMerge`, `SyncOrderKeys`, and `SyncDiff`, without CloudKit code. No other target depends on it yet.

### CloudKit

Checked in the CloudKit Swift interface of the macOS 27.2 SDK:

- `CKSyncEngine` needs macOS 14. `CKSyncEngine.Configuration` takes a database, an optional `CKSyncEngine.State.Serialization`, which is `Codable`, and a delegate. It has `automaticallySync`.
- `CKSyncEngine.RecordZoneChangeBatch` has `atomicByZone`, `init(recordsToSave:recordIDsToDelete:atomicByZone:)`, and `init?(pendingChanges:recordProvider:)`.
- Account changes arrive as `signIn(currentUser:)`, `signOut(previousUser:)`, and `switchAccounts(previousUser:currentUser:)`. A deleted zone's reason is `deleted`, `purged`, or `encryptedDataReset`.

## Decisions

Code comments and documents cite these as "sync decision 4".

1. Only pinned tabs outside live folders sync. Open tabs, a live folder's item tabs, and agent folders' tabs stay on each Mac. Open tabs archive after the archive delay and change with every page. Syncing them would open and close tabs on one Mac while the user browses on another. Pinned tabs are bookmarks (bookmark rule 1). A live folder's items come from its source on each Mac.
2. A pinned tab syncs its saved page, not its current address, as `docs/bookmarks.md` states under Interactions with other features ▸ Sync. The current address changes with every page. Syncing it would reload the tab on other Macs as the user browses. The bookmark returns to its saved page.
3. Conflicts merge field by field. The mirror's copy is the common base. Each record keeps an edit time for each field (`fieldModifiedAt`). For a field changed on both sides, the later edit wins. Incoming changes follow the same rule. Two Macs that rename a space and change its tint keep both edits. A merge per record would lose one. A single time per record would let an old rename win because a later edit changed the tint. Fields that only make sense together merge as one unit: a pinned tab's space, folder, and order, a folder's space, parent, and order, and a saved page's address and title. Merged apart, they could put a tab in another space's folder or give an address another page's title.
4. The first sync on a Mac joins matching items: spaces by name within a Persona, pinned folders by name under the matched parent, pinned tabs by saved page (bookmark rule 3) in the matched space and folder, and favorites by address within a Persona. Personas match only by record name. Otherwise a second Mac's first-launch Personal space and the same favorites would appear twice. Browser import already merges folders by name and counts addresses already pinned (`SidebarImport`). A Persona owns site data stored under its UUID. Two Personas of the same name stay apart to avoid signing one out. A local item with the record name of a server record, such as the default Persona or a setting, takes the server's values wherever the server has any. This Mac's edit times are when sync found its values, not when the user made them, so a later time would let a stale sidebar undo the other Macs' edits.
5. Signing out of iCloud or switching accounts turns sync off and keeps the local sidebar. Turning sync on again merges this Mac's sidebar into the current account as a first sync. `session.json` stays the local source of truth, and only the user's action copies one account's sidebar into another.
6. CloudKit environment: Production. `scripts/bundle_app.sh` sets `com.apple.developer.icloud-container-environment` to `Production`, or to `Development` with `ARCH_CLOUDKIT_ENVIRONMENT=Development` for a build that creates new record types or fields. Development and Production are separate databases, so every Mac must use the same one. A Developer ID build reaches only Production. A Development build creates the schema, and the user deploys it from CloudKit Console (User steps).
7. macOS 13 is not supported. The package targets macOS 14, decided with open decision 1 of `docs/windows-personas.md`.
8. A Persona deleted on another Mac is deleted here as Delete Persona does: its tabs close into the closed list, and its cookies, website data, and plugin data are removed at the next launch. While sync is on, the Delete Persona sheet says that every Mac that syncs deletes it. The interface cannot reach a Persona's data once its record is gone. The deletion must win on every Mac for the sidebars to agree.
9. Browsing history never syncs. It is the most private data Arch keeps, it grows without bound, and nothing in the sidebar needs it.
10. Pinned folders sync as `Folder` records with their parent. Open folders and every folder's collapsed state stay on each Mac. Pinned folders hold bookmarks (bookmark rule 1). Collapsing is a view choice, like the current space.
11. Orphans keep their Persona. A pinned tab or folder whose space is gone moves to the first space of its Persona. A space, folder, favorite, or pinned tab whose Persona is gone is deleted, as decision 8 requires. A Persona left without spaces gets a space named Personal whose record name derives from the Persona's. Macs that repair it at the same time write one record. A tab keeps its Persona for life (R11). A deleted Persona's items cannot move to another Persona without leaving their site data behind.
12. Settings: the keys in the Settings list sync, and every other key stays on each Mac.
13. Sync opens `CKContainer(identifier:)` with the first entry of its own `com.apple.developer.icloud-container-identifiers` entitlement. The bundle script copies that entry from the provisioning profile. No container identifier appears in the repository. It belongs to the user's team (Working Rule 8 of `docs/plan.md`). Reading the entitlement avoids depending on how `CKContainer.default()` chooses a container.

## What syncs

| Item | Synced values | Stays on each Mac |
|---|---|---|
| Personas | Name, order | Cookies, site data, installed plugins |
| Spaces | Name, symbol, tint, home page, order, Persona | Which space is current |
| Pinned folders | Name, parent folder, order, space | Whether the folder is collapsed |
| Favorites | Address, title, order, Persona | The favorite's tab (III.13) |
| Pinned tabs | Saved page (address and title), the user's tab name, engine, order, space, folder | The current page, restorable page state, the live page |
| Settings | The keys in the Settings list | Every other key |

## What never syncs

- Cookies, site storage, caches, and HTTP authentication credentials. They stay separate for each engine and Mac. A Persona that arrives from another Mac starts signed out of every site.
- Passwords, passkeys, cards, and addresses. Arch does not store them. Apple Passwords and 1Password sync their own data.
- Keychain items. A live folder whose feed address is in the Keychain stays on its Mac with its items (live folder rule 8 of `docs/bookmarks.md`).
- A pinned tab's current address and title, and the engines' restorable page state (`TabRecord.state`). Page state is engine-specific, can be large, and holds the address of every page in the tab's back-forward list.
- Open tabs and open folders, the closed-tab list, the selected tab, the current space, folders' collapsed state, window frames, small windows, and the sidebar width.
- A live folder's items, read state, and fetch state (`live-folders.json`). Each Mac fetches its own items.
- Browsing history (`history.sqlite`), downloads, captures, and favicons.
- Private API flags (`ARCHPrivateAPIs`, `ARCHPrivateAPI.*`, `ARCHPrivateAPIFeature.*`), whose availability depends on each Mac's macOS version, per-Mac prompts such as `ARCHAskedDefaultBrowser`, and the sync toggle itself (`ARCHSyncEnabled`).
- Installed plugins and extensions and their storage (rows 44 and 50).

## Container, database, and zone

- One iCloud container, named by the app's own entitlements (decision 13). No container name appears in the code.
- The private database holds one custom zone, `ArchSync1`. A custom zone provides change tokens to fetch only what changed and atomic saves across records. The number in the name is the major schema version (see Schema versions).

## Record types

Record names are unique within the zone, regardless of type.

| Record type | Record name | Fields | Local source |
|---|---|---|---|
| `Persona` | The Persona's UUID; `default` for the default Persona | `name`, `order` | `SessionSnapshot.personas` |
| `Space` | `Space.id` | `persona`, `name`, `symbol`, `tint`, `homeURL`, `order` | `SessionSnapshot.spaces` |
| `Folder` | `TabFolder.id` | `persona`, `space`, `parent`, `name`, `order` | `SessionSnapshot.folders` with `isPinned` |
| `Favorite` | `Favorite.id` | `persona`, `url`, `title`, `order` | `SessionSnapshot.favorites` |
| `Tab` | `TabRecord.id` | `persona`, `space`, `folder`, `url`, `title`, `customTitle`, `engine`, `order` | `SessionSnapshot.tabs` with `isPinned` |
| `Setting` | The `UserDefaults` key, such as `ARCHAppearance` | `value` | `UserDefaults.standard` |

Every record also has `modifiedAt`, `fieldModifiedAt`, and `schemaVersion`.

- `persona`, `space`, `folder`, and `parent` are `CKRecord.Reference` values with no delete action. The Mac that deletes a parent also deletes or moves its children in the same batch. A folder at the top of its space's pinned list has no `parent`, and a tab outside folders has no `folder`. A tab's and a folder's `persona` never changes (decision 11).
- A `Tab` record's `url` and `title` are the tab's saved page (decision 2). `customTitle` is the user's name for the tab.
- `order` is a `Double` sort key among the record's siblings: spaces and favorites within their Persona, folders within their parent folder or among their space's top-level pinned folders, and pinned tabs within their folder or among their space's pinned tabs outside folders. Folders and tabs keep separate keys because a list shows folders before tabs. A move writes only the moved record. Its key becomes the midpoint of its new neighbors' keys. Several records placed between the same two neighbors take evenly spaced keys, a record past either end of the list takes a key 1 beyond the end's, and a new list numbers from 1. When no `Double` fits between two neighbors, the Mac renumbers that parent's children 1, 2, 3, and so on in one batch. Equal keys sort by record name, and a record without a usable key sorts after the others.
- `fieldModifiedAt` gives each field's edit time: when a Mac found that field's latest edit. It also keeps the times of fields the record has lost, such as `folder` on a tab that left its folder, and of fields this build does not know. A field keeps its time until its value changes. Conflicts compare these times (decision 3). It is one encrypted string holding a JSON object from raw field name to seconds since 2001-01-01 (`Date.timeIntervalSinceReferenceDate`).
- `modifiedAt` is the time a Mac found the record's latest edit. A merge unit whose fields have no time in `fieldModifiedAt` counts as edited then.
- Edits made while sync was off count as made when sync turns on again, because `session.json` keeps no edit times. A first sync therefore keeps the server's values for records that both sides have (decision 4).
- `schemaVersion` is the record format version that wrote the record, starting at 1.
- `url` and `homeURL` are absolute address strings. `engine` is the raw value of `EngineKind`. `tint` is the raw value of `SpaceTint`. `value` is the setting's value as a string in the Settings list's form.
- Sync stores every field except the references, `order`, `modifiedAt`, and `schemaVersion` in `encryptedValues`. CloudKit encrypts those fields end to end with keys in the user's iCloud Keychain. The server cannot read addresses, titles, or names. Encrypted fields cannot be queried, and sync never queries: it reads zone changes. CloudKit cannot encrypt references.
- The default Persona, `Persona.defaultID` (`D59DAF4B-E372-4AF9-890E-455B8B3860F3`), has the record name `default` on every Mac. Every other Persona uses its UUID string. Two Macs that converted older `session.json` files to the default Persona therefore share one record.

### Settings list

| Key | Values | Applied on the receiving Mac |
|---|---|---|
| `ARCHAppearance` | `system`, `light`, or `dark` | The app shell sets `NSApp.appearance` at once |
| `ARCHTintStrength` | `subtle`, `medium`, or `strong` | Windows redraw their wash, which reads the key through `@AppStorage` |
| `ARCHDefaultEngine` | A raw value of `EngineKind` | `EngineRegistry` reads it for the next new tab and uses its usual fallback if that engine is missing on this Mac |
| `ARCHSearchEngine` | A raw value of `SearchEngine` | The palette reads it for the next search |
| `ARCHArchiveAfterHours` | A whole number from 0 to 168 | The session reads it at its next archive pass |
| `ARCHUnloadAfterHours` | A whole number from 0 to 168, from III.17 | The session reads it at its next unload pass |
| `ARCHOpensLinksInSmallWindow` | `true` or `false` | The app shell reads it for the next link from another app |
| `ARCHAskWhereToSaveDownloads` | `true` or `false` | Every engine context follows it at once |

- A value outside the key's allowed values does not apply. The key keeps its local value.
- A new setting syncs only after it joins this list. A choice that means the same on every Mac can join. A path, such as the downloads folder (`ARCHDownloadsFolder`), cannot. Shortcuts (`ARCHShortcuts`) stay on each Mac because plugin commands differ between Macs and a global shortcut can collide with another app's. Zoom per host (`ARCHZoomFactorsByHost`) stays because displays differ.

## Mapping the session store to records

- `session.json` holds no sync fields. `sync.json`, beside it in Application Support, holds the sync engine's state serialization, each synced item's last known server record (the mirror) archived with secure coding, and each pending save as the last comparison returned it, with its field values and edit times. The next comparison needs those values to tell whether a field still holds the value it found. Deleting `sync.json` makes the next sync a first sync.
- Outgoing changes: session saves already combine changes within 0.5 seconds. After each save, `Browsing` hands Sync the sidebar's syncable state: the Personas, spaces, pinned folders, favorites, and pinned tabs in sidebar order, without open tabs and folders, a live folder's item tabs, or a feed folder whose address is in the Keychain. Sync turns the state into records and compares them with the mirror (`SyncDiff`). The result lists every change still to send and replaces the pending changes in `CKSyncEngine.State`: a `.saveRecord` for each record that differs from its mirror copy, and a `.deleteRecord` for each mirror record that the state lacks. A record that changes again before sending remains one pending change, and one changed back needs none. A field with the mirror's value keeps the mirror's time. Any other field takes the time when Sync finds its new value and keeps it while the value stays. The sidebar and the settings compare apart, each with the mirror's records of its own types. Sync finds settings changes the same way on `UserDefaults.didChangeNotification`. This comparison includes edits made while sync was off, so they upload when it turns on again.
- The record provider builds each outgoing record from the mirror's copy and sets the known fields. Fields written by newer builds survive with their edit times.
- Pinning a tab creates its `Tab` record. Unpinning it or Delete Tab deletes the record. Closing a pinned tab unloads it (III.17) and changes nothing. The record's `url` and `title` change only when the saved page changes (decision 2).
- Incoming changes: Sync merges each fetched record with the local values field by field, using the mirror's copy as the base (decision 3). It applies the result to `BrowserSession` on the main actor through methods that insert, update, move, or delete a Persona, space, pinned folder, favorite, or pinned tab, or apply a setting. These methods select nothing and keep every tab in its Persona. Sync then updates the mirror so applied changes are not sent back. Within a fetch, parents apply before children: Personas, spaces, folders from the top level down, favorites, then tabs. A child whose parent has not arrived waits until the fetch ends.
- Applying a change:
  - A new or changed Persona, space, folder, or favorite updates the sidebar at once.
  - A new pinned tab joins its space and folder without a page, at its saved page. No window selects it.
  - A changed saved page moves the stand-in of a tab without its page to the new address, as Edit Saved Address… does. A tab with its page keeps it, and its row offers Go Back to Saved Page while it is off the saved site (bookmark rule 3).
  - A changed engine applies at once to a tab without its page or one that no window shows. A tab that a window shows switches once no window shows it.
  - A changed tab name, order, folder, or space applies at once.
  - A deleted pinned tab closes into this Mac's closed list, so ⌘Z and Reopen Closed Tab can bring it back.
  - A deleted folder's remaining folders and tabs move up a level, as Delete Folder does.
  - A deleted space moves this Mac's open tabs and open folders to its neighbor, as `deleteSpace` does.
  - A deleted Persona is removed as Delete Persona does (decision 8).
- Orphans: records that each merge cleanly can still disagree with each other, as when one Mac moves a folder to another space while another Mac moves a tab into it. After a fetch, Sync repairs them in this order, folders from the top level down. Every repair keeps the record's order key, and equal keys sort by record name, so every Mac picks the same destination. The Mac that finds the orphan writes the change. Two Macs that write the same change merge without a difference.
  1. A space, folder, favorite, or tab whose Persona is missing is deleted. A Persona left without spaces gets a space named Personal, as at first launch. Its record name is a name-based UUID made from the Persona's record name (decision 11).
  2. A pinned tab or folder whose space is missing moves to the first space of its Persona.
  3. A folder whose parent is missing or belongs to another Persona moves to the top of its space's pinned list. A pinned tab whose folder is missing or belongs to another Persona moves out of folders in its space.
  4. Folders whose parents form a cycle, as when two Macs each move one folder under the other, are cut at the folder whose record name sorts first. It moves to the top of its space's pinned list, and the others stay under it.
  5. A folder whose parent is in another space takes the parent's space, and so does a pinned tab whose folder is in another space. Each stays in its folder, and the folder's contents follow it.
  6. A folder below the fourth level (bookmark rule 6 of `docs/bookmarks.md`) moves up to its ancestor at the third level. Applied from the top level down, a deeper subtree flattens into the fourth level.
- Order keys: the local arrays keep the order. The `order` keys live only in the mirror. The comparison keeps the keys of the largest set of siblings already in order (the longest increasing subsequence) and gives the others new keys, so one move writes one record. A sibling keeps the key of its pending save, else of its mirror copy, when that copy is in the same sibling list.

## First sync on a Mac

- Turning sync on fetches the zone before sending anything.
- An empty zone receives every syncable item from this Mac, with every listed setting that has a saved value.
- Otherwise the server's records apply as incoming changes, and local items without a match upload. A local item matches a server record with the same record name. It takes the server's values wherever the server has any, and its own values fill only the fields or merge units that the server lacks (`SyncMerge`'s first-sync base, decision 4). Other matches follow decision 4:
  - A local space matches a server space with the same name in the same Persona. The local space's tabs and folders move to the server space, and the local space is removed.
  - A local pinned folder matches a server folder with the same name under the matched parent in the matched space. Its folders and tabs move into the server folder, and the local folder is removed.
  - A local pinned tab matches a server tab whose saved page is the same page (bookmark rule 3) in the matched space and folder. The local tab unloads and is removed without joining the closed list. The server's tab takes its place in the list. A window that showed the local tab selects the server's tab.
  - A local favorite matches a server favorite with the same address in the same Persona. The local favorite is removed, and its open tab becomes the server favorite's tab.
  - Personas match only by record name. A local Persona keeps its record and site data even when a server Persona has the same name.
  - For settings, the server's value wins for the keys it has.
- Sync sends the merge in one atomic batch.

## Conflicts

- Sync sends each record with the change tag of its mirror copy. If another Mac saved the record first, CloudKit refuses the save with `serverRecordChanged` and returns the server's record.
- Sync merges that record field by field, using the mirror's copy as the common base (decision 3). A field changed only on this Mac takes the local value. A field changed only on the server keeps the server's value. A field changed on both sides takes the value from the side that edited it later, by `fieldModifiedAt`. The server wins ties. Sync applies the merged record locally and sends it with the server's change tag. A field changed to the same value on both sides needs no send.
- Merge units: a pinned tab's `space`, `folder`, and `order`, a folder's `space`, `parent`, and `order`, and the `url` and `title` of a `Tab` or `Favorite` each merge as one unit (`SyncRecordType.fieldGroups`). A change to any field of a unit takes the whole unit from that side. A unit changed on both sides takes the side with the later of the unit's edit times. Every other field is a unit of its own. Disagreements between records, such as two folders each moved under the other, are left to the orphan repairs (Mapping the session store to records ▸ Orphans).
- A `Setting` record has a fixed name. Two Macs that first write the same setting while sync runs therefore conflict without a base. Both sides count as changed, and the later edit wins. At a first sync the server's value wins instead (First sync on a Mac).
- A field that a record lacks has no value. Removing a field, as when a tab leaves its folder and loses `folder`, is a change like any other.
- Without a base, a field that only one side has keeps its value, since nothing shows that the other side removed it.
- A field that this build does not know for the record type (`SyncRecordType.fields`) counts as unchanged on this Mac, which cannot edit it, so the merge keeps the server's value. Fields from newer builds survive this way.
- Each unit of a merged record keeps the edit times of the side whose values it takes. A merged record that must be sent takes the later `modifiedAt` of the two sides and the higher `schemaVersion`, since it can hold fields of the newer format. A merge that leaves the server's fields unchanged needs no send and keeps the server's record.
- Deletion wins. If a save fails with `unknownItem`, meaning the server record was deleted, Sync applies the deletion locally instead of recreating the record. An incoming deletion drops this Mac's pending save for that record.
- Changes to several records go in one batch with `atomicByZone`, which CloudKit saves atomically within the zone. Examples include deleting a space and moving its tabs and folders, renumbering order keys, and first-sync merges. Other Macs never fetch half of a change.
- Edit times come from each Mac's clock. A Mac whose clock is far ahead can win conflicts it should lose. Network time keeps this rare.

## Offline behavior

- Edits go into `session.json` at once. Pending changes live in the sync engine's state, which Sync writes to `sync.json` at every `stateUpdate` event, with each pending save's field values and edit times. They survive quitting. Sync sends them after a later launch.
- `CKSyncEngine` retries network failures, rate limits, and service unavailability using CloudKit's requested delays. Sync handles the failures it can fix: `zoneNotFound` creates the zone and sends again, `serverRecordChanged` merges, and `unknownItem` applies the deletion.
- `CKSyncEngine` fetches when CloudKit sends a change notification and at launch. Sync also calls `fetchChanges()` when the app becomes active to cover missed notifications.
- A Mac that was offline for weeks sends its pending changes when it reconnects. Conflicts compare each field's edit time, so its old edits do not overwrite newer ones from other Macs, even after it edited another field of the same record.

## Accounts and removed data

- Before creating the sync engine, Sync reads its own entitlements and then calls `accountStatus()` on the container (Requirements). Without the entitlement or an available account, sync stays off and the toggle explains why.
- Signing out of iCloud (`accountChange`, `.signOut`) or switching accounts (`.switchAccounts`) turns sync off, keeps the local sidebar, and deletes `sync.json`. Settings says why. Turning sync on again runs a first sync with the current account and merges this Mac's sidebar into it (decision 5). A `.signIn` while the toggle is on starts or resumes sync.
- When the zone disappears (`fetchedDatabaseChanges` deletions), Sync acts on the reason:
  - `.deleted`: another Mac chose Delete iCloud Data. Sync turns off here, deletes `sync.json`, and keeps local data.
  - `.purged`: the user removed Arch's data in the system's iCloud settings. Same as `.deleted`.
  - `.encryptedDataReset`: the user reset the end-to-end encryption keys, so the encrypted fields are gone. Sync creates the zone again and uploads this Mac's items, as in a first sync with an empty zone.

## Schema versions

- In the CloudKit Development environment, CloudKit creates record types and fields when a record first uses them. The Production environment needs the schema deployed from CloudKit Console. A save that uses an undeployed type or field fails there. Deployed record types and fields can never be removed or change type. Schema changes are additive in both environments. Each is deployed before a Production build writes it (decision 6).
- Within one zone, a new version adds optional fields or record types and raises `schemaVersion`. A missing field means its default: for example, a tab without `engine` uses the default engine. A reader keeps unknown fields because it builds outgoing records from the mirror's full copy. Records of unknown types stay in the mirror untouched. A later build applies them without fetching the zone again.
- A breaking change, such as a field that changes meaning, moves to a new zone (`ArchSync2`). The first Mac with the new build copies the old zone's records into the new zone in the new format. It then stops reading the old zone. Older builds keep syncing in the old zone until updated.
- `session.json` versions and `schemaVersion` are independent. The snapshot version describes the local file; `schemaVersion` describes the records. Only the record mapping translates between them.
- Planned additions: live folders' sidebar (III.22) adds an optional encrypted `live` field on `Folder` with the folder's source, item limit, and refresh interval. A feed folder whose address is in the Keychain never syncs (live folder rule 8). Themes (III.9) add optional fields on `Space`. Multiple windows (III.6) and split view layouts (III.5) add nothing because windows and layouts stay on each Mac.

## Requirements

- `CKSyncEngine` needs macOS 14, the package's deployment target.
- The iCloud capability needs an Apple Developer Program membership (Not verified 4), an explicit App ID for the app's bundle identifier with iCloud (CloudKit) and Push Notifications, an iCloud container assigned to it, and a provisioning profile for the App ID: macOS App Development with each Mac's device, or Developer ID.
- `scripts/bundle_app.sh` takes the profile from `ARCH_PROVISIONING_PROFILE`. It embeds the profile as `Contents/embedded.provisionprofile` and decodes it with `security cms -D`. It checks that the profile's App ID matches the bundle identifier. It also checks that the profile allows the chosen CloudKit environment and includes the signing identity among its certificates. It writes an entitlements file under `build/` with the application and team identifiers, `com.apple.developer.icloud-services` (`CloudKit`), `com.apple.developer.icloud-container-identifiers` with the profile's first container (or `ARCH_ICLOUD_CONTAINER`), `com.apple.developer.aps-environment` as given by the profile, and `com.apple.developer.icloud-container-environment` (decision 6). Working Rule 8 keeps these identifiers out of the repository. The script reads them at bundle time and prints none. It signs the frameworks and helper apps inside out without these entitlements, then the app with them. `codesign --deep` would give them to every helper. Without `ARCH_PROVISIONING_PROFILE` it signs as it does today, and Settings says the build is not signed for iCloud. IV.14 needs the same profile step for its passkey entitlement.
- Without the container entitlement, as with ad hoc signing, `CKContainer` raises an exception. Sync first reads `com.apple.developer.icloud-services` and `com.apple.developer.icloud-container-identifiers` through `SecTaskCopyValueForEntitlement`. It creates no CloudKit object when either is missing.
- While sync is on, the app calls `NSApplication.registerForRemoteNotifications()` so CloudKit's change notifications reach the sync engine (Not verified 1).

## User interface

- A Sync section after General in Settings has a Sync with iCloud toggle, a line saying what syncs ("Personas, spaces, favorites, pinned tabs and their folders, and some settings. Open tabs, history, and website data stay on this Mac."), the account state, the time of the last completed sync, and the last error in plain words. Sync reports nothing elsewhere and sends no usage data.
- The toggle stays off and disabled while sync cannot run, with the reason below it:
  - Without the iCloud entitlement: "This copy of Arch isn't signed for iCloud, so it can't sync."
  - Without an account: "Sign in to iCloud in System Settings to sync."
  - With a restricted account: "iCloud is restricted on this Mac."
  - With a temporarily unavailable account or an unknown status: "iCloud isn't available right now. Arch checks again when it becomes active."
- After a sign-out, an account switch, or a deleted zone, the toggle is off and enabled. The reason says what happened: "Sync turned off because the iCloud account changed. Turn it on to merge this Mac's sidebar into the current account." or "Sync turned off because Arch's iCloud data was deleted. Turn it on to upload this Mac's sidebar again."
- Turning sync off stops the engine and keeps local data, iCloud data, and `sync.json`. Turning it on again resumes from the saved change token.
- After a confirmation sheet, Delete iCloud Data deletes the zone, turns sync off, and deletes `sync.json`. This removes iCloud data for every Mac. Local data stays. Other Macs turn sync off at their next fetch.
- While sync is on, the Delete Persona sheet adds: "It is also deleted on your other Macs that sync with iCloud, which remove its cookies and website data too." (decision 8).
- The section names no Persona. Any label that names a space with its Persona uses `BrowserSession.label(ofSpace:)`.

## Module layout

| File | Role | Task |
|---|---|---|
| `Sync/SyncRecord.swift` | Record types, names, field values, merge units, field edit times, `modifiedAt`, and `schemaVersion`, without CloudKit types | Built |
| `Sync/SyncMerge.swift` | Merge by field and merge unit against the mirror's copy, a first write, or a first sync | Built |
| `Sync/SyncOrderKeys.swift` | Order keys: midpoints, renumbering, and sorting | Built |
| `Sync/SyncDiff.swift` | Pending saves and deletions from the current records and the mirror | Built |
| `Sync/SyncCloudKitRecords.swift` | `SyncRecord` values to `CKRecord` values and back | V.9.3 |
| `Sync/SyncMirror.swift` | Reads and writes `sync.json` | V.9.3 |
| `Sync/SyncedSettings.swift` | The Settings list: reading, validating, and applying values | V.9.4 |
| `Sync/SyncAvailability.swift` | Entitlement and account checks | V.9.5 |
| `Sync/SyncEngineClient.swift` | The protocol the controller uses and Arch's own events | V.9.6 |
| `Sync/CloudKitSyncEngine.swift` | Implements the protocol with `CKSyncEngine` | V.9.6 |
| `Sync/FirstSyncMerge.swift` | The first sync's matches and moves | V.9.7 |
| `Browsing/SidebarSync.swift` | The sidebar's syncable state and the methods that apply incoming changes | V.9.8, V.9.9 |
| `Sync/SidebarRecords.swift` | Converts syncable state to records and fetched records to session changes and orphan repairs | V.9.8, V.9.9 |
| `Sync/SyncController.swift` | The toggle, engine lifetime, and events | V.9.10, V.9.11 |
| `Preferences/SyncSection.swift` | Settings ▸ Sync | V.9.12 |

- Paths are under `Packages/ARCH/Sources/`. `SyncTests` holds `FakeSyncEngine`, which keeps pending changes in memory and replays scripted events, and a fake sidebar. No test reaches CloudKit's servers.
- `Sync` depends on `Browsing`, `ARCHEngine`, and CloudKit. `Preferences` and the `Arch` app target depend on `Sync`. `Package.swift` adds the `Sync` and `SyncTests` targets. `Browsing` does not import CloudKit. It provides the syncable state, a callback after each save, methods to apply incoming changes, and `isSyncing` for the Delete Persona sheet. `Sync` needs no `Preferences` type: the app shell applies appearance through a closure on the controller.
- `AppDelegate` creates the controller after the session, hands it to Settings, registers for remote notifications while sync is on, and calls `fetchChanges()` when the app becomes active.
- Verification needs two Macs signed in to the same Apple Account, or one Mac and the record browser in CloudKit Console, and a second Apple Account for the account checks (User steps).

## User steps

Only the user can take these steps (queue task V.9.14). Steps 1 to 3 can come at any time. The checks need V.9.3 to V.9.13.

1. In the Apple Developer account, make an explicit App ID for the app's bundle identifier (`CFBundleIdentifier` in `scripts/bundle_app.sh`) with the iCloud capability, CloudKit selected, and Push Notifications.
2. Create an iCloud container and assign it to the App ID. Its identifier stays out of the repository.
3. Create a provisioning profile for the App ID: macOS App Development with each Mac's device and the Apple Development certificate that `bundle_app.sh` signs with, or Developer ID with the Developer ID Application certificate. Keep it outside the repository and set `ARCH_PROVISIONING_PROFILE` to its path when running `scripts/bundle_app.sh`.
4. Create the schema: bundle once with `ARCH_CLOUDKIT_ENVIRONMENT=Development`. Turn on Settings ▸ Sync on a Mac whose sidebar has a second Persona, a pinned folder holding a pinned tab, and a favorite. Change one listed setting. Once Last synced shows a time, check in CloudKit Console that the Development environment lists `Persona`, `Space`, `Folder`, `Favorite`, `Tab`, and `Setting`. Add a queryable index on `recordName` for each type so the record browser can list them. Deploy the schema changes to Production. Repeat this step before a build that writes a new field reaches Production (Schema versions).
5. Bundle on each Mac without `ARCH_CLOUDKIT_ENVIRONMENT`, so the build uses Production.
6. Check with two Macs signed in to the same Apple Account:
   1. A build without the profile shows the toggle off and disabled with the reason for an unsigned build.
   2. Turning sync on uploads Mac A's sidebar. Mac B's first sync joins its Personal space with A's and shows A's Personas, spaces, pinned folders and tabs, favorites, and listed settings without duplicates. A's name for the default Persona and A's settings stay.
   3. Renaming a space, pinning a tab, moving a favorite, editing a saved page, and deleting a folder on A take effect on B within a minute while B is in the background (Not verified 1), and at once when B becomes active.
   4. With B offline, a space renamed on B and its tint changed on A both survive after B reconnects. The same space renamed on both keeps the later name, also when B changed the space's tint after its own rename.
   5. Offline edits on B survive quitting B and reach A after B relaunches online.
   6. Deleting a Persona on A closes its tabs on B into the closed list, and B removes its site data at its next launch. A's Delete Persona sheet says so.
   7. Signing out of iCloud on B turns sync off with the reason. B keeps its sidebar. Switching to a second Apple Account turns sync off. Turning it on merges B's sidebar into that account.
   8. Delete iCloud Data on A turns sync off on B at its next fetch, and both Macs keep their sidebars.
   9. CloudKit Console's Production record browser shows the records, with names, addresses, and titles only as encrypted fields (Not verified 2).
7. Record the results in Facts and resolve the Not verified items they settle.

## Not verified

1. Whether `CKSyncEngine` on macOS needs more than the `com.apple.developer.aps-environment` entitlement and `registerForRemoteNotifications()` to receive change notifications. Until verified, fetching when the app becomes active covers missed notifications.
2. Whether an Apple Development build with `com.apple.developer.icloud-container-environment` set to `Production` reaches the Production environment.
3. Whether a test process can create `CKRecord` values and their `encryptedValues` without iCloud entitlements. V.9.3 checks this first. If it cannot, its tests compare the field values the conversion writes.
4. Whether a free personal team can use the iCloud capability. The User steps assume a paid membership.
5. Whether `CKSyncEngine` sends `.signIn` when it starts without a state serialization. The controller starts a first sync either way.
