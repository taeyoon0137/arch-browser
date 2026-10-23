# Arch Working Instructions

Follow these instructions when working in the Arch repository. Before starting, read this file, then `docs/plan.md`.

## Response principles

- Lead with the conclusion. Separate verified facts from assumptions.
- Run commands, builds, and tests before reporting success. Verify each file's state before reporting success for that file.
- Do not add praise, filler, or decorative wording.

## Repository role

Arch is a sidebar-first macOS browser with its own implementation. It runs on Chromium through the Chromium Embedded Framework (CEF) as the primary engine with WebKit as a secondary engine. It runs no servers. It includes no AI features.

- The repository contains the engine abstraction, the WebKit adapter, and the Chromium adapter built on CEF. It also contains `Browsing`, the first feature module, and the `Arch` app shell. `docs/plan.md` lists what each part supports.
- For implementation decisions, read `docs/plan.md` first. It covers the goals, approach, current state, working rules, and next steps.
- Do not name other browser products in code or documents.

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
- This implementation excludes AI features. Do not add AI code or extension points for AI.

## Files and sources of truth

- `Package.swift` is maintained by hand. Add one target for each new module.
- Engine modules are in `Packages/ARCHKit/Sources/ARCHEngine*`. The CEF bridge is in `Packages/ARCHKit/Sources/CEFBridge`. Feature modules go in `Packages/ARCH/Sources/<Feature>`. The app target and CEF helper are in `Packages/ARCHApp/Sources/`.
- `README.md` is generated from `resources/README.preset.md` by `./scripts/readme_update.sh`. Edit the preset, not the output.
- `CLAUDE.md` is a symbolic link to `AGENTS.md`. Do not replace it with a copy.
- Every document in `docs/` is maintained by hand.

## Change policy

- Make the smallest change that satisfies the request.
- Do not reformat, refactor, or reorganize code outside the request's scope.
- Do not add unrequested abstractions, dependencies, or configuration.
- Treat existing modifications as intentional. Do not revert them.
- Do not create graphic assets. Leave placeholders for the user to fill.
- Keep features lightweight. Delegate autofill to Apple Passwords or 1Password. On both engines, use macOS system frameworks for every feature that is part of the platform user experience. Follow the Platform integration table in `docs/features.md`.

## Language

- Write code comments, documents, commit messages, and the README in English.
- Use only ARCH prefixes: `ARCH*` for packages, `Arch` for the app module, and `ARCHKit` for the core layer.

## Verification

After a change, run the applicable checks:

- For source changes, run `swift build`.
- For README or hero changes, run `./scripts/readme_update.sh`, then check the output.
- Run `git diff --check` and `git status --short`.
- When relevant, check the symbolic link with `ls -l CLAUDE.md`.

Report a check as passed only after running it and confirming that it passed.

## Security and record keeping

- Never commit secrets, tokens, credentials, or private keys.
- Do not add analytics, crash reporting, feature flag, or update services, or their identifiers and keys.
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
