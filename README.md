# OBS Canvas Zoom (Screen Studio Style)

**OBS Canvas Zoom** is a robust, Lua-based scripting plugin for OBS Studio that enables a dynamic, Screen Studio-style zoom effect dynamically at the canvas level. 

Instead of traditional cropping methods that obliterate your framing or cut off backgrounds, this script leverages OBS Group abstractions. It zooms the group encompassing both your display capture and your background image by shifting transform coordinates. This keeps your background beautifully visible and proportionally accurate around the edges while highlighting the exact action under your cursor.

## ✨ Features

- **True Resolution Zoom:** Transforms your camera/screen elements directly via scaling and position vectors, bypassing quality-destructive cropping.
- **Screen Studio Click-Zoom:** Configure immediate Zoom-In triggers across any combination of Left, Right, or Middle mouse clicks. Customizable unzoom delays and hold durations ensure your broadcast feels deliberately produced rather than erratic.
- **Dynamic Mouse Tracking:** Auto-follows your cursor across the zoomed broadcast dynamically. 
    - Full custom parameter tuning over Follow Speed and deadzones (Follow Border percentage).
    - Custom "Edge Padding" ensures your cursor never hits the sheer edge of the frame.
- **Background Retention:** Automatically keeps designated background textures beautifully in frame during scale transformations.
- **One-Click Auto-Setup:** Employs OBS 32.x memory-safe source group instantiation to quickly generate the required scene structure with a single click.

## 🚀 Installation & Setup

1. **Prerequisites:** Ensure you are running OBS Studio 28.0+ (Fully compatible and tested up to **OBS 32.x**).
2. Download the `obs-canvas-zoom.lua` script.
3. In OBS Studio, navigate to **Tools > Scripts**.
4. Click the **`+`** icon and select `obs-canvas-zoom.lua`.
5. **Initial Setup:** Look for the **⚡ Auto Create Zoom Setup** button in the script properties configuration panel and click it. 
6. Drag your target Window/Display capture into the newly generated `ZoomGroup` nested layer, and assign a local image file to the `Background Image` dummy layer.

## 🛠 Script Progress & Technical Architecture

The script relies heavily on FFI implementation bindings to interface directly with OS-layer cursor events (Windows API, Linux X11, macOS NSEvent) for extreme precision cursor tracking, unaffected by the main thread OBS loop speeds.

### Recent Stabilizations:
- **OBS 32 Garbage Collection Fixes:** The Lua implementation handles rigorous SWIG wrapping object lifecycles. Handled memory crashes by systematically mapping standard C API callback deletions so that OBS Scene Tear-down sequences do not encounter "double-free" garbage collection overlaps, preventing previously common `obs_sceneitem_release` access violations.
- **Memory-Safe Auto Generators:** The Auto setup tool safely fetches and delegates `obs_scene` wrappers avoiding ownership corruption inside the backend `obs.dll`.

### 🐛 Help Wanted: Current Open Dependencies / Known Bugs

This project is actively welcoming contributor Pull Requests! The following critical bugs currently need addressing:

**1. OBS Shutdown Exit Crash**
- **Symptom:** OBS sporadically throws an Access Violation (`Error Code: c0000005`) crash when closing the application.
- **Trace Context:** The crash points to `obs_source_release` being called by `obs_sceneitem_release` inside an OBS shutdown background task thread.
- **Cause Hypothesis:** There is likely an ongoing memory race condition where Lua's SWIG garbage collector is still either holding a dangling pointer to `group_sceneitem` or deleting a borrowed reference behind the scenes before OBS can officially clean up the scene, causing a double-free memory violation.

**2. Sporadic Auto-Follow Stuttering**
- **Symptom:** Mouse Auto-Follow tracking is buggy—it sometimes tracks perfectly, but sometimes halts/stutters and drops tracking frames completely without providing any log errors.
- **Cause Hypothesis:** This is heavily suspected to be linked to the `use_follow_outside_bounds` boundary logic cutting off tracking if the mouse exceeds canvas width/height coordinates, combined with potential multi-monitor scaling anomalies in `get_mouse_pos()`. Setting `Follow Outside Bounds` to True may not completely avert this edge-case rejection.

### Roadmap & Enhancements
- Support for seamlessly shifting the group structure dynamically between various main scenes without having to press `↻ Refresh Group`.
- Extending the FFI Linux backend for Wayland specific bounds since it currently defaults heavily into X11 architectures.

## 📜 License

This project is generously released under the fully permissive **MIT License**. Feel free to branch, modify, implement within commercial productions, or contribute upstream optimizations. 
See the attached `LICENSE` file for full terms.
