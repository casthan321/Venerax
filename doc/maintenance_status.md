# Venera Community maintenance status

This document records what the community fork has actually verified. It is not
a claim that every open upstream issue has been fixed.

Snapshot: 2026-08-13, based on upstream commit
[`a0eba91`](https://github.com/venera-app/venera/commit/a0eba914f4c2a84ac1bc925adec2baabe920b9be).
The archived upstream repository had 142 open issues: 42 labelled `bug` and 100
labelled `enhancement`. Enhancement requests remain a roadmap and are not
silently counted as defects.

## Implemented and covered by automated tests

| Area | Upstream reports | Community-fork coverage |
| --- | --- | --- |
| Reader progress | User-reported regression | Continuous-mode progress seeking now commits once and uses a non-animated jump, preventing a re-entrant `scrollTo` future from leaving the reader input lock active. |
| Reader gesture animation | [#745](https://github.com/venera-app/venera/issues/745) | Disabling page animation now also disables gallery swipe ballistics while preserving horizontal, RTL and vertical navigation. |
| Reader chapter loading | [#772](https://github.com/venera-app/venera/issues/772), [#825](https://github.com/venera-app/venera/issues/825) | Stale history pages are clamped after the real image count is known, and a comic-source call that never completes becomes a retryable timeout instead of an endless spinner. |
| Download state | [#813](https://github.com/venera-app/venera/issues/813), [#707](https://github.com/venera-app/venera/issues/707), [#799](https://github.com/venera-app/venera/issues/799), [#766](https://github.com/venera-app/venera/issues/766) | A task cannot complete until every selected chapter has a non-empty image list and every expected page exists. Image-list calls time out, partial resumes are reconstructed from disk, and stale continuations cannot complete a newer run. Images and covers are committed through flushed temporary files. |
| WebDAV failure handling | [#771](https://github.com/venera-app/venera/issues/771) | Startup/background sync converts transport failures to an application result instead of leaking an unhandled future. |
| WebDAV import | [#683](https://github.com/venera-app/venera/issues/683) | Imported databases use staged copy-and-replace, including cross-volume paths, with rollback on replacement failure. |
| Local files | [#595](https://github.com/venera-app/venera/issues/595), [#845](https://github.com/venera-app/venera/issues/845), [#473](https://github.com/venera-app/venera/issues/473) | Non-image files are filtered, deletion uses the resolved comic path, and recursive self-copy/repeated migration is rejected. |
| Android local folders | [#772](https://github.com/venera-app/venera/issues/772) | Android no longer exposes a raw `file://` URI. Supported external-storage and persisted SAF paths are opened as DocumentsProvider URIs, with the system tree picker and a copied-path message as safe fallbacks. |
| Configured storage | [#510](https://github.com/venera-app/venera/issues/510) | A temporarily unavailable configured path is retained and retried instead of silently switching the library to the default directory. |
| Search | [#676](https://github.com/venera-app/venera/issues/676), [#791](https://github.com/venera-app/venera/issues/791) | OpenCC mapping works with CRLF assets and aggregate searches are recorded in history. |
| SQLite worker ownership | [#733](https://github.com/venera-app/venera/issues/733) | History, favorites and cache workers open and dispose isolate-local SQLite connections rather than sharing owning native pointers. History writes are serialized, wait through short lock contention and are drained before export/import. |
| Image favorites | [#513](https://github.com/venera-app/venera/issues/513) | Downloaded source chapters are no longer mistaken for imported-local comics; offline lookup now uses the comic id, validates partial downloads, and handles chapter/page indexing and `file://` paths correctly. |
| Favorite refresh | [#768](https://github.com/venera-app/venera/issues/768) | Notifications received during a large asynchronous query are coalesced into a compensating refresh; errors cannot permanently leave the page loading. |
| History covers | [#742](https://github.com/venera-app/venera/issues/742) | Expired stored cover URLs refresh once from current comic details and the valid URL is written back. |
| Reader tap handling | [#680](https://github.com/venera-app/venera/issues/680) | Continuous scrolling blocks tap actions immediately and releases them 300 ms after scroll end without stale timer races. |
| Interrupted download directories | [#720](https://github.com/venera-app/venera/issues/720) | New downloads write an identity marker, enabling safe reuse and page/cover resume after a task record is lost without guessing from titles. |
| Local comic import | [#495](https://github.com/venera-app/venera/issues/495) | A parent directory containing chapter subdirectories is imported as one chaptered comic; its fallback cover keeps the complete relative path. |
| GIF processing | [#693](https://github.com/venera-app/venera/issues/693) | GIF87a/GIF89a bytes bypass source scripts that decode and re-encode only one static frame, preserving animation and preventing strip scrambling. |
| Responsive navigation | [#738](https://github.com/venera-app/venera/issues/738) | The folded side-navigation layout keeps the current page title without duplicating top actions. |
| Favorite quick reader | [#767](https://github.com/venera-app/venera/issues/767) | All favorite-page reader entries use the root navigator, so the reader covers the navigation shell instead of leaving a side or bottom bar visible. |
| WebView proxy | [#762](https://github.com/venera-app/venera/issues/762) | Platform-specific proxy setup no longer calls an Android-only API on Windows. Manual proxy input is normalized, credentials are excluded from Chromium command-line arguments, malformed saved values fall back safely, and authentication is limited to the configured proxy host. |

The release gate runs `dart format`, `flutter analyze`, and the complete Flutter
test suite. The Android package identity and signing workflow are checked
separately before an APK is published.

## Validation snapshot

The current tree passes `flutter analyze` and all 138 Flutter tests on Flutter
3.41.4 / Dart 3.11.1. A clean Android release build also completed with R8
enabled and produced the universal, armeabi-v7a, arm64-v8a and x86_64 APKs.

The permanent release-key build verified package id
`io.github.casthan321.venera`, version codes 1640–1643, the independent
`Venera Community` label and launcher icon, application-scoped provider
authorities, removal of the upstream web-link handlers, preservation of the
text-share entry, APK Signature Scheme v2 verification, and generation of the
R8 `mapping.txt`. All four APKs were signed by the permanent certificate with
SHA-256 fingerprint
`9cfcda753fddb426bb1b2b5078d140b00085508c937785bbf32c1cfc75a2ea37`.

No Android device was connected during this snapshot. Installation alongside
the upstream APK, provider conflict checks, storage access, and in-place
community-fork upgrade still form the real-device release gate for the first
public build.

## Implemented defensively; device or source validation still required

| Reports | Remaining validation |
| --- | --- |
| [#121](https://github.com/venera-app/venera/issues/121), [#605](https://github.com/venera-app/venera/issues/605) | SAF objects are reopened inside the worker isolate and cover lookup uses the resolved base path. Cold-start URI permission and removable-SD behavior still require real Android hardware. |
| [#433](https://github.com/venera-app/venera/issues/433) | Confirmed missing/empty downloaded directories invalidate only the stale chapter/comic marker and fall back to the source. Transient SAF or removable-storage failures preserve metadata and remain retryable; existing purely local comics intentionally remain an actionable error. |
| [#733](https://github.com/venera-app/venera/issues/733) | Unsafe cross-isolate connection ownership is fixed. Automatic quarantine and salvage of a database that is already corrupt, plus SQLite-native consistent snapshots for export, remain future work; damaged user data is never silently deleted. |
| [#798](https://github.com/venera-app/venera/issues/798) | High-resolution AVIF failures depend on the Android codec/device. A tested decoder fallback is still needed. |
| [#760](https://github.com/venera-app/venera/issues/760) | macOS no longer hides and shows the native window around AppKit's asynchronous fullscreen toggle. The change is covered by sequence tests but still needs repeated fullscreen transitions on macOS hardware. |
| [#772](https://github.com/venera-app/venera/issues/772) | The Android 13 `FileUriExposedException` path is removed. Exact folder navigation still needs an Android device check across AOSP DocumentsUI and OEM file managers; unsupported app-private paths deliberately fall back to copying the path rather than broad file sharing. |

## Already present in the archived upstream base

- [#770](https://github.com/venera-app/venera/issues/770) was addressed by upstream
  PR #764 / commit `8370d2a`.
- [#779](https://github.com/venera-app/venera/issues/779) was addressed by upstream
  PR #763 / commit `ac50557`.
- [#446](https://github.com/venera-app/venera/issues/446) is covered by the
  upstream HyperOS abnormal-window-inset workaround merged in PR #467 and its
  later Android/threshold refinements.
- [#570](https://github.com/venera-app/venera/issues/570) duplicates the
  Windows non-ASCII zip-path failure fixed by the upstream upgrade to
  `zip_flutter` 0.0.13 (`d225011`).

These issues remained open in the archived tracker, but their fixes are already
part of the source this fork started from.

## External, source-specific, stale, or insufficiently actionable

- [#263](https://github.com/venera-app/venera/issues/263) and
  [#710](https://github.com/venera-app/venera/issues/710) concern comic-source
  configuration rather than the reader application. The latter reporter
  confirmed that updating the source script version resolved it.
- [#653](https://github.com/venera-app/venera/issues/653),
  [#660](https://github.com/venera-app/venera/issues/660),
  [#692](https://github.com/venera-app/venera/issues/692), and
  [#756](https://github.com/venera-app/venera/issues/756) are Flutter, Windows
  installation-path, or vendor-font behavior. They need an upstream framework
  fix or a reproducible application-level workaround.
- [#792](https://github.com/venera-app/venera/issues/792) lacks a reproducible
  application failure; the reporter confirmed that another storage service
  worked.
- [#249](https://github.com/venera-app/venera/issues/249),
  [#774](https://github.com/venera-app/venera/issues/774), and
  [#839](https://github.com/venera-app/venera/issues/839) do not include logs or
  a reproducible application-level failure. They concern OEM window chrome or
  iPad-only startup/performance and require the named hardware before changing
  system UI or rendering behavior.

## Open validation queue

The remaining upstream `bug` labels are not being marked fixed without a
reproduction and an acceptance test.

Platform-specific reports require the named OS/device and logs. Source-specific
reports require a minimal legal source fixture that can be included in tests.
This boundary is intentional: speculative changes to storage, decoding, or
reader gestures can lose user data or introduce new navigation regressions.
