---
"hex-app": patch
---

End the take instead of hanging forever when the microphone stops responding mid-recording.

A device change during a long take could leave the recorder rebuilding its capture engine inside
CoreAudio, and that call never returned: stopping then hung, the transcript was never produced, and
the bar spun on "transcribing". The rebuild is now bounded and runs off the recorder, `stopRecording`
never applies a deferred rebuild inline, and CoreAudio is left alone for the rest of the launch once
it has wedged.
