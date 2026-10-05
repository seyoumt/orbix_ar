# Publishing to pub.dev

## Before first publish

1. Confirm `homepage` / `repository` / `issue_tracker` in `pubspec.yaml` match your
   public GitHub (or other) repo. Update them if the placeholder URLs are wrong.
2. Ensure the LICENSE copyright holder is correct.
3. Run checks:

```bash
flutter pub get
flutter analyze
flutter test
flutter pub outdated
dart pub global activate pana
dart pub global run pana .
flutter pub publish --dry-run
```

4. Review the dry-run file list: `android_backends/` must **not** appear (see `.pubignore`).

## Publish

```bash
dart pub login
flutter pub publish
```

Publishing is effectively permanent. Prefer fixing issues with a new version rather
than retracting.

## After publish

- Optionally transfer the package to a [verified publisher](https://dart.dev/tools/pub/publishing#verified-publisher).
- Hosts depend with `ar_measurement: ^0.1.0`.
- Device checklist: [OWNER_VERIFY.md](OWNER_VERIFY.md).
