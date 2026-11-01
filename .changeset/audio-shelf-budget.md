---
"hex-app": patch
---

Keep recordings from growing without limit.

Takes are now stored at 16-bit instead of 32-bit float — half the size, nothing audible lost. And
Settings → History has a "Keep recordings under" budget (1, 2, 4 or 8 GB): only when the shelf
passes it are takes tidied — halving any remaining float recordings first, then re-encoding the
biggest, oldest ones to AAC, and only takes that already have a usable transcript. Nothing is deleted, and a take whose transcript failed or is empty keeps its audio untouched.
