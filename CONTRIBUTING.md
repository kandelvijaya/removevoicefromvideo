# Contributing

## Development

Use macOS 15 or later, a compatible Swift toolchain, and FFmpeg with `libx264`.
The project has no third-party Swift package dependencies.

```sh
brew install ffmpeg
swift test
swift build -c release
BIN="$(swift build -c release --show-bin-path)/voice-remove"
"$BIN" --help
python3 Integration/run.py --binary "$BIN" -v
```

The unit tests use deterministic renderers. They do not require the native Apple model.
Some process tests locate FFmpeg and ffprobe, so install both before unit tests.
Native integration tests instantiate Apple's isolation units and create synthetic media.
Their output can vary across macOS releases. Do not assert exact native audio hashes.

For pipeline changes, obtain an independent review before final acceptance tests.
Check frame counts, latency correction, bounded buffers, channel preservation, and cancellation.
Check both video mode and audio-only mode. Preserve the no-overwrite guarantee.
Use disposable synthetic inputs for failure tests. Keep personal videos outside the repository.

## Repository hygiene

Media, build products, raw test evidence, credentials, and Python caches are ignored.
Never force-add these files. Keep test reports free of personal paths, secrets, and system identifiers.
Keep complete local logs in `.build/` or another ignored directory.
Attribute commits to the responsible human author. Do not add an AI co-author.

## First GitHub publication

No remote or GitHub repository is created automatically.

1. Confirm the personal account with `gh auth status`.
2. If the account is incorrect, authenticate your personal account with `gh auth login --hostname github.com`.
3. Check `git config user.name` and `git config user.email` before new commits.
4. Review `git status --short`, `git remote -v`, and the full Git history.
5. Choose repository visibility and a license before public distribution.

Existing commits include the author's configured email and historical local paths in a test report.
Current reports use relative paths. Editing current files does not remove values from Git history.
If those historical details must remain private, agree on a history rewrite before publication.
No media or large files were found in the existing history during preparation.

After account and visibility confirmation, create and push a private repository:

```sh
gh repo create PERSONAL_USERNAME/voice-remove --private --source=. --remote=origin --push
```

Replace `PERSONAL_USERNAME` with the confirmed account. This command creates a remote repository and uploads commits.
If `origin` already exists, verify its owner and URL before any push.
A private repository is the recommended first publication while license and public-history review remain open.

## License

No license is selected yet. GitHub publication alone does not grant an open-source license.
The author must approve a license before this project is offered for unrestricted reuse.
Apple frameworks, native models, and FFmpeg remain separate dependencies under their own terms.
