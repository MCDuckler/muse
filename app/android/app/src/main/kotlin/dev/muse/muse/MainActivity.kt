package dev.muse.muse

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity, not FlutterActivity: audio_service routes lockscreen and
// headset-button events through it. With a plain FlutterActivity the notification
// appears but its buttons do nothing.
class MainActivity : AudioServiceActivity()
