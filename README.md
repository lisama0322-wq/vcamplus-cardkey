# VCam Plus

Virtual camera tweak for iOS 16 + Dopamine rootless jailbreak.
Replaces camera output with a video file — works in all apps **and** Safari web pages.

---

## How to build (via GitHub Actions)

1. Create a new **public** repository on your GitHub account (lisama0322-wq)
2. Upload all files in this folder to the repository root
3. Go to **Actions** tab → select **Build VCam Plus** → click **Run workflow**
4. After ~5 minutes the build finishes → click the run → download **vcamplus-deb** artifact
5. Install the `.deb` with Sileo (local deb install)

---

## How to use after installing

The tweak does nothing until you put two files on the phone:

| File | Purpose |
|------|---------|
| `/var/mobile/Library/Caches/vcamplus/video.mp4` | The video to show as camera |
| `/var/mobile/Library/Caches/vcamplus/enabled`   | Empty file — acts as on/off switch |

**To enable:** copy your video to `/var/mobile/Library/Caches/vcamplus/video.mp4`
then create the empty file `/var/mobile/Library/Caches/vcamplus/enabled`.

**To disable:** delete the `enabled` file (camera returns to normal immediately).

You can manage these files with any file manager app (e.g. Filza).

The directory `/var/mobile/Library/Caches/vcamplus/` is created automatically
on first launch after installing the tweak.

---

## Technical notes

- Hooks `AVCaptureVideoDataOutput setSampleBufferDelegate:queue:`
- Wraps the delegate with a proxy that substitutes video frames from the file
- Frame timestamps are retimed to match the live camera stream
- Video loops automatically when it reaches the end
- No UIApplication usage — works in sandboxed processes like WebContent
- Filter: UIKit bundles (all apps) + WebContent executable (Safari web pages)
