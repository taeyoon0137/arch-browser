# Tabs from other Macs

## Behavior

Each space shows the open, unpinned tabs published by other Macs signed in to the same iCloud sync. Each publishing Mac has one read-only folder below the space's own pinned items, named "\<Mac name>'s Tabs" in English and "\<Mac 이름>의 탭" in Korean. The folder belongs to that Persona and space; a tab from another Persona or space never appears there.

- Collapsing a folder affects only this Mac.
- Rows show a title and a favicon loaded on this Mac. Favicons never enter the sync payload.
- Clicking a row opens a new unpinned tab in the displayed space with the published address and engine. The source Mac's tab stays untouched. The new tab uses this Mac's existing Persona profile and its own sign-in state.
- Remote rows cannot be renamed, moved, pinned, or closed. A remote folder accepts no local tabs or folders. They do not become local bookmarks or live tabs until clicked.
- A folder disappears when the publishing Mac has no eligible tabs in the space or its publication is at least 14 days old. A Mac that reconnects can publish it again.
- Settings ▸ Sync offers Open Tabs from Other Macs under the main iCloud switch, and the sidebar's context menu offers Show Tabs from Other Macs. A remote folder's context menu offers Hide Tabs from Other Macs. These control one preference on this Mac, enabled by default when sync is on. Turning it off hides all remote folders and removes this Mac's published records. Turning sync off also removes its publications.

Interface strings and their Korean translations are in `Packages/ARCH/Sources/Browsing/Resources/Localizable.xcstrings`. Remote folder and tab rows use the neighboring sidebar rows' sizes, weights, and color roles.

## Published data

`BrowserSession.openTabsSyncState` projects eligible tabs in sidebar order, grouped by Persona and space. It includes ordinary open tabs with http or https addresses, including tabs inside ordinary open folders. Pinned tabs, favorites' live tabs, agent tabs, small-window tabs, blank tabs, and internal or file addresses are excluded. Open folders and the tabs' local IDs do not sync. Embedded usernames and passwords are removed from eligible addresses before publication.

Each tab contributes only these values:

| JSON key | Value |
|---|---|
| `url` | Absolute http or https address |
| `title` | The tab's title |
| `engine` | Raw `EngineKind` value |
| `order` | Integer position in the space's open-tab list |

The list is encrypted with CloudKit's `encryptedValues`, including the order inside its JSON. The device identifier and name fields are encrypted strings too. Record names still contain the device UUID and space UUID; those identifiers, the Persona and space references, schema version, and timestamps are visible metadata. Cookies, website data, credentials, sign-in state, page state, back-forward lists, page contents, and favicon data never enter these records. Nothing in this feature reads either engine's cookie store.

## Publication and lifetime

Each installation keeps a random device UUID in the local `ARCHRemoteTabsDeviceID` preference and takes its display name from macOS. `ARCHShowRemoteTabs` is local, defaults to true, and is absent from the synced Settings list.

A successful session write reports its captured open-tab projection. The controller replaces pending publication work after each change and publishes after 10 seconds without another change. It publishes after the first sidebar merge, so a first sync's matched Persona and space identifiers are used. Each Mac writes and deletes only its own `RemoteTabs` records; ordinary sidebar and settings comparisons leave every remote-tab record alone. A timer checks every 60 seconds for expiry and for a daily heartbeat that republishes unchanged lists while sync runs, so an active Mac's tabs do not expire.

The controller stores received publications in the sync mirror and exposes matching nonempty, fresh lists to the sidebar. Receiving a list never creates local session tabs. The decoder and sidebar filter the current device, unknown owners, invalid entries, incomplete chunk sets, and stale publications. A timestamp more than five minutes in the future is refused. A stale record can remain in iCloud; readers hide it without deleting another Mac's data.

When the local switch turns off, the controller cancels pending publication work and deletes its records. When sync turns off, a deletion-only engine fetches this zone and removes this device's publications without applying the shared sidebar or advancing the normal sync token. `ARCHRemoteTabsCleanupPending` keeps an interrupted or offline cleanup pending across launches, scoped to the container and environment by the digest in `ARCHRemoteTabsCleanupDatabase`; activation or relaunch retries it with a full fetch. The local folders hide immediately even while cleanup waits. Signing out or switching accounts can make the old account inaccessible before deletion succeeds; the 14-day expiry then removes the old publication from other Macs' sidebars. An observed account or zone loss, or a different database digest, clears the pending cleanup. The marker has no saved account identifier, so an account switch while Arch is not running cannot be distinguished by that marker; cleanup still selects only records whose device identity and record name match this installation.

## CloudKit schema to deploy

This build writes `SyncRecord.currentSchemaVersion` **4**. It adds `RemoteTabs` to the existing **private database**, custom zone **`ArchSync1`**, in the container named by the signed app's entitlements. It adds no container or server and changes no existing field's type. Older builds preserve this unknown record type in their mirror.

One record holds one device's publication for one space, split into chunks when necessary. Its record name is `remote-tabs-<device UUID>-<space UUID>-<chunk index>`. The encrypted `tabs` field is a JSON object with `generation`, `index`, `count`, and `tabs`. Its `tabs` array holds only the four values listed above per tab. The generation is a SHA-256 digest of the ordered tab list; index and count identify the complete set of chunks. Each payload is at most 128 KiB. A single encoded tab of 128 KiB minus 512 bytes or more is omitted. Readers show a folder only after all chunks of its latest generation arrive with matching owners and counts, ordered by each tab's encrypted `order` value. Reducing the list deletes unused chunks; an empty list deletes every chunk for that space.

Deploy the following fields on **`RemoteTabs`**, with the spelling, capitalization, and encryption shown:

| Field | CloudKit type | Stored in | Meaning |
|---|---|---|---|
| `persona` | Reference | Plain values | Owning `Persona` record, with delete action `none` |
| `space` | Reference | Plain values | Owning `Space` record, with delete action `none` |
| `deviceID` | Encrypted String | `encryptedValues` | Installation's device UUID |
| `deviceName` | Encrypted String | `encryptedValues` | macOS computer name used by the folder |
| `tabs` | Encrypted String | `encryptedValues` | JSON object with `generation`, `index`, `count`, and a `tabs` array of `url`, `title`, `engine`, and `order` values |
| `fieldModifiedAt` | Encrypted String | `encryptedValues` | Existing sync metadata: JSON edit times by field name |
| `modifiedAt` | Date/Time | Plain values | Publication time; the oldest chunk determines the complete list's freshness |
| `schemaVersion` | Int(64) | Plain values | `4` |

`RemoteTabs` has no plain `order`, `url`, `title`, `engine`, or tab-ID field. It needs no query index for sync because the engine reads zone changes. A Queryable index on `recordName` allows CloudKit Console's record browser to list records, as for the other types. Encrypted fields cannot be queried.

Before a Production build writes schema version 4:

1. Use a provisioned Development build as described in `docs/sync.md`, User steps. Enable sync and Open Tabs from Other Macs, and leave an eligible open tab in a space.
2. After the debounce and completed sync, inspect `RemoteTabs` in CloudKit Console's Development environment. Check all fields above and confirm that `tabs`, `deviceID`, `deviceName`, and `fieldModifiedAt` are encrypted strings.
3. Deploy the added `RemoteTabs` record type and its fields from **Development to Production**. If `Folder.tint` from schema version 3 is still undeployed, deploy that Encrypted String field too. Changing `schemaVersion` in the app does not deploy a schema.
4. With provisioned Production builds on two Macs signed in to the same Apple Account, verify publication, appearance in the matching Persona / Space, updates, ordering, and opening a local tab. Verify disabling either switch removes the publishing Mac's folders elsewhere after sync, and exercise offline cleanup and reconnect.

The Production deployment and live two-Mac behavior have not been verified for this feature. A Production server rejects writes to an undeployed type or field; Settings ▸ Sync reports that save error.

## Verification

Automated tests use session fixtures and a fake sync engine without contacting iCloud. They cover the open-tab projection, encrypted payloads, publication debounce, device ownership, folder filtering and expiry, the local switch, cleanup, and opening a remote row in the correct space. Run `swift build`, `swift test --filter BrowsingTests`, and `swift test --filter SyncTests`.

The running app's folder layout, collapsed state, favicon rendering, context menus, and two-Mac delivery still need a manual check.
