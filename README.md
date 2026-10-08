# voice-remove

A compiled macOS command-line tool for conversation suppression. Originals stay unchanged.
Outputs use `<stem>_voiceremoved.<original extension>` beside each input.

Implementation is in progress. Build with `swift build -c release`.
Requires macOS 15 or later, FFmpeg, and ffprobe.
