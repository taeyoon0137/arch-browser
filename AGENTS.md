# Arch Working Instructions

Follow these instructions when working in the Arch repository. Before starting, read this file, then `docs/plan.md`.

## Response principles

- Lead with the conclusion. Separate verified facts from assumptions.
- Run commands, builds, and tests before reporting success. Verify each file's state before reporting success for that file.
- Do not add praise, filler, or decorative wording.

## Repository role

Arch is a sidebar-first macOS browser with its own implementation. It runs on Chromium through the Chromium Embedded Framework (CEF) as the primary engine with WebKit as a secondary engine. It runs no servers. It ships no AI model or provider account; AI features use providers the user connects.

- The repository contains the engine abstraction, the WebKit adapter, and the Chromium adapter built on CEF. It also contains the feature modules in `Packages/ARCH/Sources` (`Agent`, `AgentControl`, `AI`, `Browsing`, `Events`, `Extensions`, `History`, `Hooks`, `Import`, `Plugins`, `Preferences`, and `Terminal`) and the `Arch` app shell. `docs/plan.md` lists what each part supports.
- For implementation decisions, read `docs/plan.md` first. It covers the goals, approach, current state, working rules, and next steps.
- Do not name other browser products in code or documents. One exception is the opening of the README, which credits the project's inspiration by name. Another is browser import: it names the browsers it reads only in the `Import` module's source definitions (display names, bundle identifiers, and data locations), the import interface, and the feature's documents (`docs/import-browsers.md` and its rows in `docs/plan.md` and `docs/features.md`). The last is the Web Store: its page hosts, whose names contain another browser product, appear only as constants in `Packages/ARCH/Sources/Extensions/WebStore.swift`, which its tests use, and in `docs/web-store.md`.

## Instruction priority

1. The latest user instruction
2. This `AGENTS.md`
3. `docs/plan.md` and the design documents in `docs/`
4. Existing conventions of the file being edited

Items higher in the list take precedence. Ask if a conflict is unclear.

## Start-of-work checks

- Run `git status --short`.
- Read the files you will change and the related documents.
- Read `docs/engine-protocol.md` for engine decisions and `docs/features.md` for feature scope.
- Before non-trivial work, write a short plan. List the files to change, the expected behavior, and the verification steps.

## How code is written

- Write new code for each feature. Start from a row in `docs/features.md` and build the smallest module that delivers it.
- Design type names, module boundaries, method signatures, and file layout for Arch. A row in `docs/features.md` describes what a feature does, not how to build it.
- Add engine protocol members only when a feature needs them.
- All AI features use Arch's AI interface, a single provider-neutral API; no feature calls a provider directly. The user connects providers using an API key for a service they subscribe to or a command-line tool signed in through the built-in terminal, and chooses a provider and model for each feature. API keys stay in the Keychain and go only to their provider.

## Files and sources of truth

- `Package.swift` is maintained by hand. Add one target for each new module.
- Engine modules are in `Packages/ARCHKit/Sources/ARCHEngine*`. The CEF bridge is in `Packages/ARCHKit/Sources/CEFBridge`. Feature modules go in `Packages/ARCH/Sources/<Feature>`. The app target, the CEF helper, and `arch-cli` (the `ArchCLI` target) are in `Packages/ARCHApp/Sources/`.
- `README.md` is generated from `resources/README.preset.md` by `./scripts/readme_update.sh`. Edit the preset, not the output.
- `CLAUDE.md` is a symbolic link to `AGENTS.md`. Do not replace it with a copy.
- Every document in `docs/` is maintained by hand.

## Change policy

- Make the smallest change that satisfies the request.
- Do not reformat, refactor, or reorganize code outside the request's scope.
- Do not add unrequested abstractions, dependencies, or configuration.
- Treat existing modifications as intentional. Do not revert them.
- Do not create graphic assets. Leave placeholders for the user to fill.
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. By default, features use macOS facilities on both engines; for example, picture in picture uses AVKit rather than an engine's implementation. Follow the Platform integration table in `docs/features.md`.
- Prefer public APIs. Use a private API (an undocumented class, selector, function, or key in a system framework or engine) only behind flags on `flags://`: one for all private APIs, one for each private API, and one for each feature that uses one. Check each private API's availability quietly and quickly, in the background or just before use. If a feature's private API is unavailable or switched off, the feature falls back to its public behavior or stays hidden. List every private API in the Private APIs section of `docs/features.md`.
- You may change the Chromium (CEF) or WebKit source when a feature needs it. CEF changes are commits in the private repository `taeyoon0137/arch-chromium`, which follows its own `AGENTS.md`. They reach the app only through a release pinned by `scripts/setup_cef.sh`. Keep each change small and list it in the engine changes table in `docs/plan.md`.

## Language

- Write code comments, documents, commit messages, and the README in English.
- Use only ARCH prefixes: `ARCH*` for packages, `Arch` for the app module, and `ARCHKit` for the core layer.
- Write Markdown so that GitHub shows what the text says:
  - Outside code, escape an angle-bracket placeholder as `\<Engine>`. GitHub drops an unknown tag such as `<Engine>` from the rendered page.
  - Inside a table cell, escape a pipe as `\|`, also within a code span.
  - Do not leave paired `~` or `$` in prose. GitHub renders them as strikethrough or math.
  - `./scripts/check_markdown.py` finds all of these, and `--fix` escapes placeholders.

## Verification

After a change, run the applicable checks:

- For source changes, run `swift build` and `swift test`. `swift test --filter <Module>Tests` runs one module's tests; the Build section of `docs/plan.md` Current State describes each test target's checks.
- For README or hero changes, run `./scripts/readme_update.sh`, then check the output.
- For changes to Markdown documents, run `./scripts/check_markdown.py`.
- Run `git diff --check` and `git status --short`.
- When relevant, check the symbolic link with `ls -l CLAUDE.md`.

Report a check as passed only after running it and confirming that it passed.

## After each task

Check each item before reporting a task as finished:

1. `README.md` still matches the repository: the introduction, the getting started steps, the docs list, the scripts table, and the repository structure. If the task changed any of them, edit `resources/README.preset.md`, run `./scripts/readme_update.sh`, and commit the regenerated files with the task.
2. `docs/plan.md` Current State and `docs/features.md` describe the result, as the plan's Working Rules require.
3. The checks under Verification ran and passed.

## Security and record keeping

- Never commit secrets, tokens, credentials, or private keys.
- Do not add analytics, crash reporting, or remote feature flag services, or their identifiers and keys. Local flags on the `flags://` page are allowed.
- Only Sparkle may check for updates, using the appcast and archives in the project's own GitHub Releases, with system profiling off (`docs/updates.md`). Add no update server or other update service. Only the EdDSA public key goes into the repository.
- Do not add trailers such as `Co-Authored-By`, agent or model names, or "generated with" notes unless the user asks.

## Commits

- Commit only when the user asks.
- Use the subject format enforced by `.githooks/commit-msg`. Enable the hook once with `git config core.hooksPath .githooks`:
  - Maintenance: `<Prefix>: <subject>` with `Feat`, `Docs`, `Refactor`, `Fix`, `Chore`, or `Test`.
  - Planned work: `Task(<ID>): <subject>`. The ID consists of a Roman numeral phase and dotted numbers, such as `I.1.1`.
- Write non-empty subjects in English. Keep each commit to one purpose. Stage only related hunks.

## Final response format

When you finish, include:

1. A summary of changes
2. The changed files
3. The verification commands run and their results
4. Remaining risks, limits, and follow-ups

State explicitly when only documents changed.
