# CommunityCAD for Klipper: Feature Overview

## The idea

Browse CommunityCAD models from a clean, purpose-built browser inside Mainsail or Fluidd, slice with your own print profile, and start the print from any device. No PC needed. When the print is done, share it back to CommunityCAD with one click.

MakerWorld offers this for Bambu printers only. Nothing like it exists for open printers running Klipper.

## Who it's for

Klipper users. They are enthusiasts, technically comfortable, and print often. They already have tuned slicer profiles and care about print quality.

## Supported interfaces

- **Mainsail and Fluidd, both from day one**
- Many commercial Klipper printers ship with Fluidd (Creality K2 Plus, Snapmaker U1, Elegoo Neptune 4), while DIY and Voron builds often use Mainsail
- Same features and same experience in both

## Features, simplest first

The plugin gets built in this order. Each stage should work extremely well before the next one starts.

### Stage 1: Connect and browse
The foundation. Everything else builds on this.

**Connect a CommunityCAD account**
- Sign in once from Mainsail or Fluidd
- Stays connected

**Browse the catalog**
- A purpose-built browser inside Mainsail or Fluidd, designed for the plugin
- Not the CommunityCAD website shown inside the interface. The plugin pulls models from CommunityCAD and displays them in its own clean interface
- Works on phone, tablet, or PC
- Browsing should feel effortless: fast, clean, few taps
- Search the full catalog
- Model pages show preview, files, creator, and license

**Made for your printer**
- The plugin reads your printer's build volume automatically
- By default, models that fit your printer show first
- Each model shows whether it fits, at a glance
- Nothing is hidden. One tap shows everything
- Printable files (STL, 3MF) shown before CAD-only models
- Goal: convenience by default, never limiting

### Stage 2: Get it to the printer
- Sliced files go straight into the printer's G-code files, the same way Orca and PrusaSlicer send them
- Option to start the print right away, always with a confirm
- Warns when a file was sliced for a different printer
- Unsliced files (STL, STEP) can be downloaded to your phone or PC to slice there, until on-printer slicing arrives
- Requires a CommunityCAD account. Browsing doesn't.

### Stage 3: Share
The main reason the plugin exists: getting CommunityCAD in front of more makers.

**One-tap print profile share**
- When a print finishes, share its print profile with one tap
- Settings, printer, material, and result are filled in automatically. Nothing to type
- Profiles show up on the model's page: "Printed 12 times", with what worked
- Only print settings are shared, never private details like network addresses or keys (always on, not a setting)

**Posts**
- Share a photo of your print with a short caption, straight from the plugin
- If the print was recorded with a timelapse, add the video to the post (optional, off by default)
- Publish right away, or save as a draft to review on CommunityCAD first

**Share anywhere**
- After posting, share to X, Bluesky, Reddit, Mastodon, or anything on your phone
- Links show a preview card with the photo of your print, so people click through
- The model's creator gets notified and can reshare it to their own followers

### Stage 4: Bring your own print profile
- One-time import of your existing slicer profile
- Your printer, nozzle, filament, and tuning carry over
- Support for more than one profile (different filaments or printers)

### Stage 5: Slice and print from anywhere
- Pick a model, pick a profile, slice right on the printer
- Quick orient and preview before printing
- Send to print instantly
- Slicing only runs while the printer is idle
- If a model has no printable file, use its CAD source file instead
- Large or complex jobs still go through the PC as usual

## Settings

Each setting lives in one place.

**In the plugin (this printer)**
- Linked account and the printer name shown on CommunityCAD
- Build volume (detected automatically, can be adjusted)
- Default view: "Fits your printer" or "All"
- Where sent files are saved
- Sharing: ask to share when a print finishes
- Webcam photos for posts: off by default. When off, the plugin never touches your webcam
- Timelapse in posts: off by default. When on, a print's timelapse can be added to its post with one checkbox

**In your CommunityCAD account (you, on every printer)**
- Connected printers: rename or disconnect any of them
- Notifications when someone prints your models: each time, daily digest, or off
- Privacy: whether your printer name and print results show publicly

## More than one printer

- Install the plugin on each printer and connect each one to the same account
- Every printer keeps its own size, settings, and "Fits your printer" results
- All your printers show up by name in your CommunityCAD account
- Works with Mainsail and Fluidd setups that switch between several printers, and with several printers running on one Pi
- Only downloads from CommunityCAD count toward your limits. What you do with a file afterwards, like copying or reprinting it, never counts
- Later, optional: share your print activity for your own print history. Off by default, and it never affects limits
- Download limits are per account, shared across your printers. Each printer that downloads from CommunityCAD counts as its own download, so two printers count as 2. Downloading again to the same printer on the same day is free
- Before every send, the plugin tells you whether it will use a download and how many you have left
- Your account shows a full download history, so you can always see what used your limit
- Later: send a model to any of your printers from anywhere, including the website

## Always true, every stage

- Works in both Mainsail and Fluidd
- Single install command
- Updates with one click from Mainsail or Fluidd, like other Klipper add-ons
- Clean uninstall that leaves the user's setup as it was
- Does not overwrite existing themes or settings
- The plugin itself is open source (Apache 2.0), and lives on GitHub where this audience already is

## Open questions

- How "made for your printer" should rank models beyond size (printer type, popularity, what others with the same printer have printed)
- CommunityCAD needs size info for every model to know what fits
- How the plugin's browser gets placed inside Mainsail and Fluidd: added by the plugin itself, or through a feature added to each interface
- Printers with locked or customized Klipper (Creality, Anycubic, older Qidi): support through community firmware like Rinkhals, or later
- Where it gets announced: r/klippers, Klipper Discord, Klipper plugin stores, Rinkhals app store
