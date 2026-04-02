---
name: ios-testflight-release
description: Archive and upload an iOS app to TestFlight/App Store Connect. Use when the user asks to package, archive, export, or publish an iPhone/iPad app build for internal or external TestFlight testing, especially when the project may vary but the release workflow is similar across repos.
---

# iOS TestFlight Release

Use this skill when the user wants an iOS app packaged and uploaded to TestFlight.

## Workflow

1. Prefer a repo-local `codex.testflight.toml` file if present.
2. If the config includes an `xcodegen_command`, run it before archiving.
3. Check the project or workspace, scheme, and team ID before archiving.
4. Run the bundled upload script instead of hand-writing long `xcodebuild` commands.
5. Report the result clearly:
   - whether archive succeeded
   - whether upload succeeded
   - whether the build is now processing in App Store Connect
6. If upload fails, summarize the concrete blocker:
   - signing or provisioning
   - App Store Connect authentication
   - duplicate build number or version issue
   - validation failure from Apple

## Preferred Entry Point

Use `scripts/testflight_release.py`.

Common usage:

```bash
python3 ~/.codex/skills/ios-testflight-release/scripts/testflight_release.py --config codex.testflight.toml
```

Dry run:

```bash
python3 ~/.codex/skills/ios-testflight-release/scripts/testflight_release.py --config codex.testflight.toml --dry-run
```

## Config

See `references/config.md` for the supported TOML keys and examples.

## Notes

- Either `project` or `workspace` is required.
- `scheme` and `team_id` are required.
- The upload path uses `xcodebuild -exportArchive` with `destination=upload` and `method=app-store-connect`.
- The script enables `manageAppVersionAndBuildNumber`, so Xcode can handle build-number collisions during upload when possible.
- If the machine is not signed into Xcode, or the team lacks permissions, upload may still fail even when archive succeeds.
