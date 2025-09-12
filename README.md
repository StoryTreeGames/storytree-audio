# Zig Audio

Cross platform audio management

- https://learn.microsoft.com/en-us/windows/win32/coreaudio/about-the-windows-core-audio-apis?redirectedfrom=MSDN
    - [XAudio2](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/ee416960(v=vs.85)) (replaces DirectSound | win 10 + 11)
        - [Programming Guide](https://learn.microsoft.com/en-us/windows/win32/xaudio2/xaudio2-apis-portal)
        - Works directly with audio buffers
        - Requires manual switching of devices when the user switches outputs
    - @ [Audio Graphs](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/audio-graphs) (replaces DirectSound | win 10 + 11)
        - Works directly with I/O and has automatic redirect when user switches output devices
        - Better support in both c++ and c# based apps
    - @ [Media Foundation](https://learn.microsoft.com/en-us/windows/win32/medfound/microsoft-media-foundation-sdk)
        - [Programming Guide](https://learn.microsoft.com/en-us/windows/win32/medfound/media-foundation-programming-guide)

