# OBS Screen Studio (v1.0)

<p align="center">
  <a href="https://ko-fi.com/kareemstudio">
    <img src="https://storage.ko-fi.com/cdn/kofi5.png?v=3" alt="Support on Ko-fi" height="45">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-8A2BE2?style=flat-square" alt="version">
  <img src="https://img.shields.io/badge/OBS_Studio-28.0%2B-FF7F50?style=flat-square" alt="OBS Studio">
  <img src="https://img.shields.io/badge/platform-Windows_%7C_macOS_%7C_Linux-00a8ff?style=flat-square" alt="platform">
  <img src="https://img.shields.io/badge/license-MIT-1cbc7c?style=flat-square" alt="license">
</p>

**OBS Screen Studio** is a robust, Lua-based scripting plugin for OBS Studio that enables a dynamic, Screen Studio-style zoom effect seamlessly at the canvas level.

Instead of traditional cropping methods that obliterate your framing or cut off backgrounds, this script leverages OBS Group abstractions. It zooms the group encompassing both your display capture and your background image by shifting transform coordinates. This keeps your background beautifully visible and proportionally accurate around the edges while highlighting the exact action under your cursor.

## 📸 Screenshots

<p align="center">
  <img src="images/Screenshot%201.png" alt="OBS Script Setup" width="48%">
  &nbsp;
  <img src="images/Screenshot%202.png" alt="OBS Canvas Preview" width="48%">
</p>

## ✨ Features

- **True Resolution Zoom:** Transforms your camera/screen elements directly via scaling and position vectors, bypassing quality-destructive cropping.
- **Screen Studio Click-Zoom:** Configure immediate Zoom-In triggers across any combination of Left, Right, or Middle mouse clicks. Customizable unzoom delays and hold durations ensure your broadcast feels deliberately produced rather than erratic.
- **Dynamic Mouse Tracking:** Auto-follows your cursor across the zoomed broadcast dynamically. 
    - Full custom parameter tuning over Follow Speed and deadzones (Follow Border percentage).
    - Custom "Edge Padding" ensures your cursor never hits the sheer edge of the frame.
- **Background Retention:** Automatically keeps designated background textures beautifully in frame during scale transformations.
- **One-Click Auto-Setup:** Quickly generates the exact required scene layer hierarchy with a single click inside the script window.

## 🚀 Installation & Setup

1. **Prerequisites:** Ensure you are running OBS Studio 28.0+ (Fully compatible and tested up to **OBS 32.x**).
2. Download the `obs-screen-studio.lua` script.
3. In OBS Studio, navigate to **Tools > Scripts**.
4. Click the **`+`** icon and select `obs-screen-studio.lua`.
5. **Initial Setup:** Look for the **⚡ Auto Create Zoom Setup** button in the script properties configuration panel and click it. 
6. Drag your target Window/Display capture into the newly generated `ZoomGroup` group folder, and double click the generated `Background Image (Assign Me)` layer to select an image from your computer to use as your background frame.

## 💡 How it Works & Usage

- **Activate & Zoom:** Once your captures are in the group, simply start clicking. The script listens natively to OS inputs and dynamically scales your "ZoomGroup" forward, framing exactly what you clicked on.
- **Hands-Free Following:** Moving your mouse off center naturally pans the camera.
- **Hotkeys:** You can assign custom Hotkeys (via *OBS Settings > Hotkeys*) to manually override the zoom, toggle the script on and off, or pause the mouse-following logic.
- **Refresh Flow:** If you make large edits to the scene, add new things to the group, or something feels out of sync, press the **↻ Refresh Group** button to quickly re-sync the system.

## 🔥 Best Recommended Settings
For the most authentic and smooth "Screen Studio" feel, apply the following baseline settings:

- **Zoom Speed:** `0.02`
- **Edge Padding (%):** `5`
- **Screen Studio Click Zoom:** `Checked`
  - Left Click / Right Click / Middle Click: `Checked`
- **Unzoom Delay (sec):** `2.00`
- **Min Zoom Duration (sec):** `5.55`
- **Auto Follow Mouse:** `Checked`
- **Follow Outside Bounds:** `Unchecked`
- **Follow Speed:** `0.05`
- **Follow Border (%):** `50`
- **Lock Sensitivity:** `1`
- **Auto Lock on Reverse Direction:** `Unchecked`

## 🎨 Example Scene & Background Template

To help you achieve a stunning aesthetic right out of the box, we have included a **`scene example`** folder in this repository. 

1. **`obs-zoom-blured-bg.jpg`**: A ready-to-use, high-quality blurred background image. When configuring your scene, simply set this image as the file for your `Background Image (Assign Me)` source.
2. **`obs-zoom-blured-bg.psd`**: A fully layered Adobe Photoshop template. You can open this file to completely customize the colors, shadows, and layout of the background to match your own brand before exporting it to OBS!

## 📜 License

This project is generously released under the fully permissive **MIT License**. Feel free to branch, modify, implement within commercial productions, or contribute upstream optimizations.
