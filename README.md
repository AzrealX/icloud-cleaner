# iCloud Cleaner

A menu bar app that keeps the local copies of your iCloud Drive files under a size limit.

When local copies go over the limit (10 GB by default), it removes the local copies of the least recently used files until usage is back down to the target (80% of the limit by default). This is the same action as Finder's **Remove Download**: files stay in iCloud Drive and download again when you open them. It never touches:

- files that haven't finished uploading
- files used within the last N days (default 7)
- folders on your "Never touch" list

## Build & install

```bash
./build.sh install
```

This builds `build/iCloud Cleaner.app`, copies it to `~/Applications`, and launches it. In Settings, turn on **Open at login** to keep it running.

## Preview without changing anything

```bash
.build/release/ICloudCleaner --dry-run
```

The **Preview Cleanup…** window in the menu shows the same list.

Activity is logged to `~/Library/Logs/iCloudCleaner.log`.
