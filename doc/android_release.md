# Android release checklist

Venera Community uses the permanent Android application id
`io.github.casthan321.venera`. The first public signing key is part of that
identity: every later update must use the same application id and the same
certificate with a higher version code.

The permanent release certificate SHA-256 fingerprint is
`9cfcda753fddb426bb1b2b5078d140b00085508c937785bbf32c1cfc75a2ea37`.
Verify this value against every downloaded release APK.

## One-time signing setup

Generate the key interactively so passwords never enter shell history or the
repository. Keep the keystore name and alias stable; the example validity is
longer than the expected lifetime of the application.

```powershell
keytool -genkeypair -v `
  -keystore 'venera-community-release.jks' `
  -alias 'venera-community' `
  -keyalg RSA -keysize 4096 -validity 10000
```

Create `android/key.properties` locally. Both this file and `*.jks` are ignored
by Git. `storeFile` is resolved from the Android app module, so a keystore at
`android/venera-community-release.jks` uses the following path:

```properties
storeFile=../venera-community-release.jks
storePassword=<local secret>
keyAlias=venera-community
keyPassword=<local secret>
```

Make at least two encrypted offline backups of the keystore and recovery
information before publishing the first APK. Never regenerate the key as a
routine recovery action: a different certificate cannot update installed
copies of the community app.

## GitHub Actions secrets

Configure these secrets in `casthan321/venera`:

- `ANDROID_KEYSTORE_BASE64`: base64-encoded bytes of the permanent keystore.
- `ANDROID_KEYSTORE_PASSWORD`: keystore password.
- `ANDROID_KEY_ALIAS`: permanent alias, normally `venera-community`.
- `ANDROID_KEY_PASSWORD`: key password.
- `ANDROID_SIGNING_CERT_SHA256`: the 64-hex-character SHA-256 fingerprint of
  the permanent signing certificate. The workflow rejects every other key.

After `gh auth login`, secret values can be supplied through standard input so
they do not become command-line arguments. PowerShell's `Read-Host` keeps the
two passwords out of shell history:

```powershell
[Convert]::ToBase64String(
  [IO.File]::ReadAllBytes('venera-community-release.jks')
) | gh secret set ANDROID_KEYSTORE_BASE64

$StorePassword = Read-Host 'Keystore password' -AsSecureString
$StoreBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($StorePassword)
try {
  [Runtime.InteropServices.Marshal]::PtrToStringBSTR($StoreBstr) |
    gh secret set ANDROID_KEYSTORE_PASSWORD
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($StoreBstr)
}

gh secret set ANDROID_KEY_ALIAS --body 'venera-community'
```

Repeat the secure-input block for `ANDROID_KEY_PASSWORD`. Obtain the
certificate fingerprint with `keytool -list -v` and set its 64 hexadecimal
digits (colons are accepted) as `ANDROID_SIGNING_CERT_SHA256`.

Do not paste secret values into an issue, pull request, release note, workflow
file, or chat transcript.

## First-release sequence

1. Run `dart format`, `flutter analyze`, and `flutter test`.
2. Build locally with `flutter build apk --release` and verify every APK with
   Android Build Tools `apksigner`.
3. Push the reviewed source tree and configure the five repository secrets.
4. Run the Android workflow manually (`workflow_dispatch`) before creating a
   release. Download its APK/checksum artifacts and R8 mapping.
5. Install the upstream APK and the community APK on the same Android device.
   Confirm both packages launch, keep independent data, share files, and can
   access their separately granted storage locations.
6. Install a second community build with the same certificate and a higher
   version code using `adb install -r`; it must update in place without
   affecting the upstream app.
7. Push the reviewed `v1.6.4` tag. The Android workflow builds and verifies the
   commit, creates a draft release, attaches the universal and ABI-specific
   APKs, `SHA256SUMS`, and the compressed R8 mapping, then publishes the release
   only after every asset has been attached.
8. Verify the attached checksums and signing-certificate SHA-256 digest again.
   Archive the release's R8 mapping with the source tag.

The universal APK has version code 1640. ABI-specific codes are 1641
(armeabi-v7a), 1642 (arm64-v8a), and 1643 (x86_64). Keep future codes strictly
higher across every distribution format; do not publish the debug code 1644 as
an update candidate.

Temporary or smoke certificates are suitable only for build validation. APKs
signed by them must never be attached to a public release.

For a reproducible x86_64 emulator check, the archived upstream fixture is
[`venera-1.6.3-x86_64.apk`](https://github.com/venera-app/venera/releases/download/v1.6.3/venera-1.6.3-x86_64.apk)
with SHA-256
`6b45f62082e9ea81a55fb424e5a3fa953ca8eabae37231b9151f6a303db66728`.
Its application id is `com.github.wgh136.venera`.
