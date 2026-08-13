# Venera Community

Venera Community 是归档项目 [Venera](https://github.com/venera-app/venera) 的非官方社区维护分支，保留原项目的 GPL-3.0 许可与作者署名。本分支优先处理可复现的阅读、下载、同步和本地文件缺陷。

> 本项目与原作者及上游项目没有官方隶属关系。Android 包名为
> `io.github.casthan321.venera`，可与原版 `com.github.wgh136.venera` 同时安装。

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/casthan321/Venerax)](LICENSE)
[![Android](https://github.com/casthan321/Venerax/actions/workflows/android.yml/badge.svg)](https://github.com/casthan321/Venerax/actions/workflows/android.yml)
[![Download](https://img.shields.io/github/v/release/casthan321/Venerax)](https://github.com/casthan321/Venerax/releases)

A comic reader that support reading local and network comics.

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build from source
1. Install Flutter 3.41.4 and JDK 17.
2. Install Android platforms 33–36, Build Tools 35.0.0/36.0.0, NDK 27.0.12077973/28.0.13004108, and CMake 3.22.1.
3. Install Rust 1.85.1 and the Android targets listed in `rust-toolchain.toml`.
4. Run `flutter pub get && flutter test`.
5. Configure a private `android/key.properties` and build with `flutter build apk --release`.

Do not commit a release keystore or its passwords. The first public release key must be retained for every later update.

For signed GitHub Actions releases, configure these repository secrets:
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
`ANDROID_KEY_PASSWORD`, plus `ANDROID_SIGNING_CERT_SHA256` for the permanent
certificate fingerprint. Keep an encrypted offline backup of the original
keystore; creating a new key later will make existing Venera Community
installations impossible to upgrade in place.

The verified fix scope and the upstream issue triage are tracked in
[the maintenance status](doc/maintenance_status.md).
The permanent-key and first-publication procedure is documented in the
[Android release checklist](doc/android_release.md).

## Coexistence and data

The community fork uses a separate Android sandbox. It does not overwrite the official app, but it also cannot automatically read the official app's settings, logins, favorites, or persisted storage permissions. Use Venera's data export/import feature for a manual migration, then grant storage access again. Avoid pointing both apps at the same writable download directory.

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

