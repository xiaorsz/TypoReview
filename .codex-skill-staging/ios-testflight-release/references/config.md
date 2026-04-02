# Config Format

Create a repo-local `codex.testflight.toml` file with a `[testflight]` table.

## Required Keys

- `scheme`
- `team_id`
- one of `project` or `workspace`

## Optional Keys

- `configuration` - defaults to `Release`
- `xcodegen_command` - command to run before archiving
- `archive_path` - default is a timestamped path in `/tmp`

## Example: Xcode project

```toml
[testflight]
project = "听写复习本.xcodeproj"
scheme = "听写复习本"
team_id = "FCAW792CJD"
configuration = "Release"
xcodegen_command = "/Users/xiaorsz/bin/xcodegen generate"
```

## Example: Workspace

```toml
[testflight]
workspace = "MyApp.xcworkspace"
scheme = "MyApp"
team_id = "ABCDE12345"
configuration = "Release"
```

## Override Rules

Command-line flags override TOML values. This is useful when a repo has multiple schemes or when a single machine needs a temporary change.
