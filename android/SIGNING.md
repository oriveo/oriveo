# Signing an Android release build

Debug builds are signed automatically with the local debug key and need no setup. This page is
about producing a release APK or App Bundle you can install or distribute yourself.

Nothing here is committed. The keystore, its passwords, and the Gradle properties that point at
them all live outside the repository.

## 1. Create a keystore

```bash
keytool -genkey -v \
  -keystore oriveo-release.jks \
  -alias oriveo \
  -keyalg RSA -keysize 4096 \
  -validity 9125 \
  -dname "CN=Your Name, O=Your Organisation, C=US"
```

`keytool` prompts for the store password and the key password. Type them at the prompt rather than
passing `-storepass` or `-keypass` on the command line, which would leave both in your shell
history.

Keep the file somewhere outside the repository and readable only by you:

```bash
mkdir -p "$HOME/.oriveo/keystore"
mv oriveo-release.jks "$HOME/.oriveo/keystore/"
chmod 600 "$HOME/.oriveo/keystore/oriveo-release.jks"
```

**Back it up, and keep the backup.** An app store identifies your app by its signing key. Lose the
key and you cannot publish an update to an app that is already installed; users have to uninstall
and start over.

If you store the backup in a syncing folder, keep the copy Gradle reads on local disk. Cloud
folders evict file contents to save space, and an evicted keystore reads as missing rather than as
an error, so the build silently falls back to the debug key.

## 2. Point Gradle at it

Add four properties to `~/.gradle/gradle.properties` (not to any file in the repository):

```properties
ORIVEO_RELEASE_KEYSTORE_PATH=/Users/you/.oriveo/keystore/oriveo-release.jks
ORIVEO_RELEASE_KEYSTORE_PASSWORD=<store password>
ORIVEO_RELEASE_KEY_ALIAS=oriveo
ORIVEO_RELEASE_KEY_PASSWORD=<key password>
```

All four must be present and the file must exist, otherwise the build refuses to produce a release
artifact rather than quietly signing it with the debug key.

## 3. Build

```bash
./gradlew :app:assembleRelease   # APK
./gradlew :app:bundleRelease     # App Bundle
```

The output lands in `app/build/outputs/`.

## 4. Verify which key was used

A successful build is not proof that the right key signed it, so check the certificate:

```bash
keytool -printcert -jarfile app/build/outputs/bundle/release/app-release.aab
```

The owner line should be the `-dname` you chose in step 1. If it says `CN=Android Debug`, the
release signing configuration was not picked up: re-check the four properties and that the
keystore path exists.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The build fails saying release signing is not configured | One of the four properties is missing, or the keystore path does not exist | Re-check `~/.gradle/gradle.properties` and that the file is present locally |
| A warning that the release build was signed with the debug key | Same as above, on a build that does not require signing | Configure signing before distributing the artifact |
| `Keystore was tampered with, or password was incorrect` | Wrong store password | Re-enter it; the store and key passwords may differ |
| A store rejects the upload as signed with the wrong key | A different keystore than the first upload | Use the original keystore. Some stores offer a key reset process; most do not |

## Do not

- Commit the keystore or its passwords. `.gitignore` already covers `*.jks`.
- Put passwords in `app/build.gradle.kts` or in `local.properties`.
- Pass passwords on the `keytool` command line.
- Send the keystore over chat or email.
