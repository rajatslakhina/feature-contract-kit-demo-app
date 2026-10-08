# Contract Console: FeatureContracts demo app

**Three app versions, two server deploys and a planned third, two models, one contract. This app shows which combinations are actually safe, and why.**

[![CI](https://github.com/rajatslakhina/feature-contract-kit-demo-app/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/feature-contract-kit-demo-app/actions/workflows/ci.yml)

A SwiftUI app that consumes [**FeatureContracts**](https://github.com/rajatslakhina/feature-contract-kit) as a **remote Swift package, pinned to a release** (`upToNextMajorVersion` from `1.0.0`, never a branch or a local path). It runs the library against a realistic AI feature, a receipt extractor with three shipped contract revisions, and renders what a lead needs to see before shipping a schema change or rolling a server.

## Why this matters

Sharing one Swift package between an iOS app and a Swift server gives you a single *definition* of an AI feature's output schema. It does not stop the app fleet and the server rollout from running *different revisions* of that definition at the same time. This console makes that skew visible: who gets served, who gets an "upgrade required", which model answered, and whether the two models even agree.

## Screenshots

Screenshots are captured by this repo's CI on a GitHub-hosted iOS Simulator and committed to `Demo/Screenshots/`. This section is updated once the first run completes.

## What each tab shows

| Tab | What you see | Library types behind it |
|---|---|---|
| **Fleet** | App 3.8 / 4.0 / 4.1 (6% / 31% / 63% of installs, contract v1.0 / v1.1 / v1.2) against `api-2026.09` (v1.1), `api-2026.10` (v1.2) and a planned `api-2026.11` that retires v1.0. Every cell says `native`, `server ↓` (the server downgrades its answer), `app ↓` (the app resends at an older revision), `upgrade required`, or one of those plus `lossy` (amber): served, but the downgrading side crosses a declared-lossy widening. App 4.1 on `api-2026.09` is one of these, because its long requests, like the nine-page folio, cannot be expressed at v1.1. The planned deploy shows the **6% of installs it would break**, and each footer gives the share served on a lossy path (63%, 37% and 31% respectively). | `CompatibilityMatrix`, `Negotiation` |
| **Router** | Six scripted requests through `TierRouter`, each with its full decision trace: a short receipt answered on-device; a device without Apple Intelligence; a nine-page folio (~1.25k tokens) over the 1,024-token on-device budget; an on-device answer that invents the category `"groceries"`, gets rejected and is answered by the server; an app one revision ahead of the server that renegotiates to v1.1 and upgrades the answer; and the same invalid answer under an `onDeviceOnly` contract, which **fails closed instead of sending the receipt off the device**. | `TierRouter`, `ContractClient`, `ContractEndpoint` (in-process), `Validator`, `SkewTranslator` |
| **Lint** | The shipped history (v1.0 → v1.2) passes, with two `lossy` widenings and the prompt fingerprints. A proposed v1.3 "tidy-up" is blocked by five breaking findings: a narrowed input limit, a renamed field, a removed enum case, and two required fields with no default. | `ContractLinter` |
| **Parity** | Five golden receipts through the server fixture and the on-device fixture. 19 of 20 compared fields agree (95% ≥ 90% threshold, so **PASS**); the one disagreement (`Uber`: `travel` vs `other`) is listed. | `ParityEval` |

**About the models:** both are deterministic `ScriptedModel` fixtures (keyword extraction over the rendered prompt). This app does not call Foundation Models or any hosted LLM. What it shows is the contract, skew, routing and validation machinery around a model, end to end.

## How the app uses the package

`Demo/DemoApp.swift` owns every product decision the library leaves open: the three contract revisions (`ReceiptContract`), the proposed v1.3, the fleet, the routing budget, the parity rules and threshold. It hands them to `ContractConsoleView` from `FeatureContractsUI`. The client and server halves are wired together through `InProcessTransport`, so the full wire protocol (envelopes, negotiation, renegotiation, translation) runs on every request. Only the network is skipped.

## How to run it

1. `git clone https://github.com/rajatslakhina/feature-contract-kit-demo-app.git`
2. Open `Demo.xcodeproj` in Xcode 16 or later. Xcode resolves `feature-contract-kit` from GitHub at the pinned version.
3. Select the **Demo** scheme and any iPhone Simulator (iOS 17+).
4. Build and run. To land on a specific tab, add `-tab router` (or `fleet`, `lint`, `parity`) under *Scheme → Run → Arguments*.

## Verification

Pending the first CI run. This section is written only after the run reports.

## License

MIT. See [LICENSE](LICENSE).
