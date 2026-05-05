# TODO

- Fix UTF-8 truncation in the taskbar text path. `fitText()` currently slices raw bytes and can cut a multibyte codepoint in half, which makes `drawText()` reject the truncated string entirely.
- Either implement `Taskbar.width = .min_content` properly or remove that mode from the public config. Right now `measureTaskbarMinWidth()` is a stub that returns `0`.
- Narrow client-property refresh handling so title changes do not force `refreshDesktopState()` and a full window rescan on every update.
- Clean up the text measurement/drawing API split so padding is handled more symmetrically. `textItemWidth()` currently bakes in padding while `drawText()` expects callers to account for padding explicitly.
