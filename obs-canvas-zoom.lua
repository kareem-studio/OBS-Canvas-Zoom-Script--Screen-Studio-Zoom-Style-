--
-- OBS Canvas Zoom (Screen Studio Style)
-- A canvas-level virtual camera zoom for OBS.
-- Zooms a Group containing background + screen recording by transforming
-- the group's scale/position instead of cropping the video source.
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.0"

---------------------------------------------------------------------------
-- Settings variables
---------------------------------------------------------------------------
local use_script_enabled = true
local group_name = "ZoomGroup"
local zoom_value = 2.0
local zoom_speed = 0.06
local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local follow_speed = 0.25
local follow_border = 8
local follow_safezone_sensitivity = 4
local use_follow_auto_lock = false
local edge_padding = 5          -- % margin so cursor never hits edge
local debug_logs = false

-- Screen Studio click-zoom settings
local use_click_zoom = false
local click_zoom_left = true
local click_zoom_right = false
local click_zoom_middle = false
local click_zoom_release_delay = 0.3
local click_zoom_min_duration = 0.3

-- Monitor override settings
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 1920
local monitor_override_h = 1080

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

-- Group scene item references
local group_sceneitem = nil
local group_source = nil
local group_pos_orig = { x = 0, y = 0 }
local group_scale_orig = { x = 1, y = 1 }
local canvas_w = 1920
local canvas_h = 1080

-- Animation state
local zoom_time = 0
local current_pos = { x = 0, y = 0 }
local current_scale = 1.0
local start_pos = { x = 0, y = 0 }   -- captured at animation start
local start_scale = 1.0               -- captured at animation start
local target_pos = { x = 0, y = 0 }
local target_scale = 1.0

-- Follow state
local is_following_mouse = false
local locked_center = nil
local locked_last_pos = nil

-- Timer state
local is_timer_running = false

-- Logging state
local has_logged_missing_group = false

-- Click-zoom internal state
local is_click_down = false
local click_down_time = 0
local click_release_time = -1
local click_zoom_unzoom_pending = false
local click_poll_timer_running = false
local CLICK_POLL_INTERVAL_MS = 16

-- VK codes
local VK_LBUTTON = 0x01
local VK_RBUTTON = 0x02
local VK_MBUTTON = 0x04

-- Hotkey IDs
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local hotkey_enable_id = nil

-- Platform FFI handles
local win_point = nil
local x11_lib = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

---------------------------------------------------------------------------
-- Platform FFI setup
---------------------------------------------------------------------------
local version_str = obs.obs_get_version_string()
local major = tonumber(version_str:match("(%d+%.%d+)")) or 0

-- Wrap cdef in pcall to avoid crash if obs-zoom-to-mouse.lua already defined these types
if ffi.os == "Windows" then
    pcall(function()
        ffi.cdef([[
            typedef int BOOL;
            typedef struct{
                long x;
                long y;
            } POINT, *LPPOINT;
            BOOL GetCursorPos(LPPOINT);
            short GetKeyState(int nVirtKey);
        ]])
    end)
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    pcall(function()
        ffi.cdef([[
            typedef unsigned long XID;
            typedef XID Window;
            typedef void Display;
            Display* XOpenDisplay(char*);
            XID XDefaultRootWindow(Display *display);
            int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
            int XCloseDisplay(Display*);
        ]])
    end)

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    pcall(function()
        ffi.cdef([[
            typedef struct {
                double x;
                double y;
            } CGPoint;
            typedef void* SEL;
            typedef void* id;
            typedef void* Method;

            SEL sel_registerName(const char *str);
            id objc_getClass(const char*);
            Method class_getClassMethod(id cls, SEL name);
            void* method_getImplementation(Method);
            int access(const char *path, int amode);
        ]])
    end)

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

function format_table(tbl, indent)
    if not indent then indent = 0 end
    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"
    return str
end

function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t
end

function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

function clamp(min_val, max_val, value)
    return math.max(min_val, math.min(max_val, value))
end

---------------------------------------------------------------------------
-- Mouse position
---------------------------------------------------------------------------
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if ffi.os == "Windows" then
        if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
            mouse.x = win_point[0].x
            mouse.y = win_point[0].y
        end
    elseif ffi.os == "Linux" then
        if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
            if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                mouse.x = tonumber(x11_mouse.win_x[0])
                mouse.y = tonumber(x11_mouse.win_y[0])
            end
        end
    elseif ffi.os == "OSX" then
        if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
            local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
            mouse.x = point.x
            if use_monitor_override then
                mouse.y = monitor_override_h - point.y
            end
        end
    end

    return mouse
end

function is_mouse_button_down(button_index)
    if ffi.os == "Windows" then
        local vk
        if button_index == 1 then vk = VK_LBUTTON
        elseif button_index == 2 then vk = VK_RBUTTON
        else vk = VK_MBUTTON
        end
        local state = ffi.C.GetKeyState(vk)
        return (state < 0)
    end
    return false
end

---------------------------------------------------------------------------
-- Canvas & group helpers
---------------------------------------------------------------------------
function get_canvas_size()
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        canvas_w = ovi.base_width
        canvas_h = ovi.base_height
        log("Canvas size: " .. canvas_w .. "x" .. canvas_h)
    end
end

function release_group()
    if is_timer_running then
        obs.timer_remove(on_zoom_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None

    if group_sceneitem ~= nil then
        -- Restore original transform
        local pos = obs.vec2()
        pos.x = group_pos_orig.x
        pos.y = group_pos_orig.y
        obs.obs_sceneitem_set_pos(group_sceneitem, pos)

        local scale = obs.vec2()
        scale.x = group_scale_orig.x
        scale.y = group_scale_orig.y
        obs.obs_sceneitem_set_scale(group_sceneitem, scale)

        group_sceneitem = nil
    end

    -- group_source is a borrowed ref from obs_sceneitem_get_source — do NOT release it
    group_source = nil

    current_scale = 1.0
    current_pos = { x = 0, y = 0 }
    is_following_mouse = false
    locked_center = nil
    locked_last_pos = nil
end

function find_zoom_group()
    release_group()

    if group_name == nil or group_name == "" then
        log("ERROR: No group name configured")
        return
    end

    get_canvas_size()

    log("Looking for group '" .. group_name .. "'")

    -- Get current scene
    local scene_source = obs.obs_frontend_get_current_scene()
    if scene_source == nil then
        log("ERROR: No current scene")
        return
    end

    local current_scene_name = obs.obs_source_get_name(scene_source)
    local scene = obs.obs_scene_from_source(scene_source)
    if scene == nil then
        log("ERROR: Could not get scene from source")
        return
    end

    -- Strategy 1: Find the group/source directly in the current scene
    group_sceneitem = obs.obs_scene_find_source(scene, group_name)

    -- Strategy 2: Look inside nested scenes
    if group_sceneitem == nil then
        local all_items = obs.obs_scene_enum_items(scene)
        if all_items then
            for _, item in pairs(all_items) do
                local nested_src = obs.obs_sceneitem_get_source(item)
                if nested_src ~= nil and obs.obs_source_is_scene(nested_src) then
                    local nested_scene = obs.obs_scene_from_source(nested_src)
                    if nested_scene then
                        group_sceneitem = obs.obs_scene_find_source(nested_scene, group_name)
                        if group_sceneitem ~= nil then break end
                    end
                end
            end
        end
    end

    -- Strategy 3: The named source exists but isn't in the current scene.
    -- This happens when the user created a Scene named "ZoomGroup" instead
    -- of a Group inside the active scene. We detect this and give guidance.
    if group_sceneitem == nil then
        local found_source = obs.obs_get_source_by_name(group_name)
        if found_source ~= nil then
            local is_scene = obs.obs_source_is_scene(found_source)
            local is_group = obs.obs_source_is_group(found_source)

            if is_scene then
                if current_scene_name == group_name then
                    -- The user has the ZoomGroup scene as the ACTIVE scene.
                    -- We can't zoom the active scene itself — we need it nested inside another scene.
                    if not has_logged_missing_group then
                        log("ERROR: '" .. group_name .. "' is the active scene — it cannot zoom itself.\n" ..
                            "         HOW TO FIX:\n" ..
                            "         1. Create a new scene (e.g., 'Main')\n" ..
                            "         2. In 'Main', click + in Sources → Scene → select '" .. group_name .. "'\n" ..
                            "         3. Switch to 'Main' as your active scene\n" ..
                            "         The script will then find and zoom '" .. group_name .. "' correctly.")
                        obs.script_log(obs.OBS_LOG_WARNING,
                            "[Canvas Zoom] '" .. group_name .. "' is the active scene.\n" ..
                            "Create a new scene, add '" .. group_name .. "' as a Source in it, and switch to that scene.")
                        has_logged_missing_group = true
                    end
                    return
                else
                    -- The source exists as a scene but isn't added to the current scene
                    if not has_logged_missing_group then
                        log("ERROR: '" .. group_name .. "' exists as a Scene but is not added to the current scene '" .. current_scene_name .. "'.\n" ..
                            "         HOW TO FIX:\n" ..
                            "         1. In scene '" .. current_scene_name .. "', click + in Sources\n" ..
                            "         2. Choose 'Scene' → select '" .. group_name .. "'\n" ..
                            "         3. Click 'Refresh Group' in the script settings")
                        obs.script_log(obs.OBS_LOG_WARNING,
                            "[Canvas Zoom] '" .. group_name .. "' exists but isn't in the active scene.\n" ..
                            "In your active scene, click + → Scene → select '" .. group_name .. "', then click Refresh Group.")
                        has_logged_missing_group = true
                    end
                    return
                end
            elseif is_group then
                if not has_logged_missing_group then
                    log("ERROR: Group '" .. group_name .. "' exists but is not in the current scene '" .. current_scene_name .. "'.\n" ..
                        "         Switch to the scene that contains this group.")
                    obs.script_log(obs.OBS_LOG_WARNING,
                        "[Canvas Zoom] Group '" .. group_name .. "' exists but isn't in scene '" .. current_scene_name .. "'. Switch to the correct scene.")
                    has_logged_missing_group = true
                end
                return
            end
        end
        if not has_logged_missing_group then
            log("WARNING: '" .. group_name .. "' not found anywhere.\n" ..
                "         HOW TO CREATE IT:\n" ..
                "         1. Use the 'Auto Create Zoom Setup' button below.\n" ..
                "         2. OR In your scene, add an Image source + your Display Capture\n" ..
                "         3. Select both → Right-click → 'Group Items'\n" ..
                "         4. Rename the group to '" .. group_name .. "'\n" ..
                "         5. Click 'Refresh Group' in the script settings")
            obs.script_log(obs.OBS_LOG_WARNING,
                "[Canvas Zoom] '" .. group_name .. "' not found. Use 'Auto Create Zoom Setup' or manually select your background + display capture → Right-click → Group Items → rename to '" .. group_name .. "'")
            has_logged_missing_group = true
        end
        return
    end

    has_logged_missing_group = false

    -- Get the source for this group (borrowed ref — do NOT addref/release)
    group_source = obs.obs_sceneitem_get_source(group_sceneitem)

    -- Capture original position and scale
    local pos = obs.vec2()
    obs.obs_sceneitem_get_pos(group_sceneitem, pos)
    group_pos_orig.x = pos.x
    group_pos_orig.y = pos.y
    current_pos.x = pos.x
    current_pos.y = pos.y

    local scale = obs.vec2()
    obs.obs_sceneitem_get_scale(group_sceneitem, scale)
    group_scale_orig.x = scale.x
    group_scale_orig.y = scale.y
    current_scale = scale.x  -- assume uniform scale

    log("Found group '" .. group_name .. "' at pos (" .. pos.x .. ", " .. pos.y ..
        ") scale (" .. scale.x .. ", " .. scale.y .. ")")
end

---------------------------------------------------------------------------
-- Zoom transform calculation
---------------------------------------------------------------------------
--- Gets the mouse position in canvas coordinates
function get_mouse_canvas_pos()
    local mouse = get_mouse_pos()

    -- Offset mouse by monitor position if using override
    if use_monitor_override then
        mouse.x = mouse.x - monitor_override_x
        mouse.y = mouse.y - monitor_override_y
    end

    -- Mouse is in desktop pixel space. We need it in canvas space.
    local mouse_canvas_x = mouse.x
    local mouse_canvas_y = mouse.y
    if use_monitor_override and monitor_override_w > 0 and monitor_override_h > 0 then
        mouse_canvas_x = mouse.x * (canvas_w / monitor_override_w)
        mouse_canvas_y = mouse.y * (canvas_h / monitor_override_h)
    end

    return mouse_canvas_x, mouse_canvas_y
end

--- Clamp a group position to keep content within canvas bounds (with padding)
function clamp_group_position(pos_x, pos_y, zoom)
    local content_w = canvas_w / group_scale_orig.x
    local content_h = canvas_h / group_scale_orig.y
    local scaled_w = content_w * zoom
    local scaled_h = content_h * zoom

    local pad_x = canvas_w * (edge_padding * 0.01)
    local pad_y = canvas_h * (edge_padding * 0.01)

    local min_x = canvas_w - scaled_w + pad_x
    local max_x = -pad_x
    if min_x > max_x then
        pos_x = (canvas_w - scaled_w) * 0.5
    else
        pos_x = clamp(min_x, max_x, pos_x)
    end

    local min_y = canvas_h - scaled_h + pad_y
    local max_y = -pad_y
    if min_y > max_y then
        pos_y = (canvas_h - scaled_h) * 0.5
    else
        pos_y = clamp(min_y, max_y, pos_y)
    end

    return pos_x, pos_y
end

--- Maps cursor position to the group position needed to center the cursor.
--- Uses the ORIGINAL (fixed) group transform to compute local coordinates,
--- eliminating feedback loops during animation.
---@param target_zoom number The target zoom factor
---@return table {pos_x, pos_y, scale, raw_mouse} The target transform
function calculate_zoom_target(target_zoom)
    local mouse_canvas_x, mouse_canvas_y = get_mouse_canvas_pos()

    -- Convert mouse canvas position to group-local coordinates
    -- using the ORIGINAL group transform (fixed, not the animated one)
    -- This prevents feedback: target doesn't depend on current animation state
    local local_x = (mouse_canvas_x - group_pos_orig.x) / group_scale_orig.x
    local local_y = (mouse_canvas_y - group_pos_orig.y) / group_scale_orig.y

    -- Compute group position so this local point appears at canvas center
    local cx = canvas_w * 0.5
    local cy = canvas_h * 0.5
    local new_pos_x = cx - local_x * target_zoom
    local new_pos_y = cy - local_y * target_zoom

    -- Clamp to keep content visible
    new_pos_x, new_pos_y = clamp_group_position(new_pos_x, new_pos_y, target_zoom)

    return {
        pos_x = new_pos_x,
        pos_y = new_pos_y,
        scale = target_zoom,
        raw_mouse = { x = mouse_canvas_x, y = mouse_canvas_y }
    }
end

function apply_group_transform(pos_x, pos_y, scale)
    if group_sceneitem == nil then return end

    current_pos.x = pos_x
    current_pos.y = pos_y
    current_scale = scale

    local pos = obs.vec2()
    pos.x = pos_x
    pos.y = pos_y
    obs.obs_sceneitem_set_pos(group_sceneitem, pos)

    local s = obs.vec2()
    s.x = scale
    s.y = scale
    obs.obs_sceneitem_set_scale(group_sceneitem, s)
end

---------------------------------------------------------------------------
-- Zoom actions
---------------------------------------------------------------------------
function do_zoom_in()
    if not use_script_enabled then return end

    if group_sceneitem == nil then
        find_zoom_group()
        if group_sceneitem == nil then return end
    end

    if zoom_state == ZoomState.None then
        log("Canvas zooming in")
        zoom_state = ZoomState.ZoomingIn
        zoom_time = 0
        locked_center = nil
        locked_last_pos = nil

        -- Capture start state for proper lerp animation
        start_pos.x = current_pos.x
        start_pos.y = current_pos.y
        start_scale = current_scale

        local t = calculate_zoom_target(zoom_value)
        target_pos.x = t.pos_x
        target_pos.y = t.pos_y
        target_scale = t.scale

        if not is_timer_running then
            is_timer_running = true
            local interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
            obs.timer_add(on_zoom_timer, interval)
        end
    end
end

function do_zoom_out()
    if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn then
        log("Canvas zooming out")
        zoom_state = ZoomState.ZoomingOut
        zoom_time = 0
        locked_center = nil
        locked_last_pos = nil

        -- Capture start state for proper lerp animation
        start_pos.x = current_pos.x
        start_pos.y = current_pos.y
        start_scale = current_scale

        -- Target: back to original position and scale
        target_pos.x = group_pos_orig.x
        target_pos.y = group_pos_orig.y
        target_scale = group_scale_orig.x

        if is_following_mouse then
            is_following_mouse = false
            log("Mouse tracking off (zoom out)")
        end

        if not is_timer_running then
            is_timer_running = true
            local interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
            obs.timer_add(on_zoom_timer, interval)
        end
    end
end

---------------------------------------------------------------------------
-- Animation timer
---------------------------------------------------------------------------
function on_zoom_timer()
    if group_sceneitem == nil then return end

    zoom_time = zoom_time + zoom_speed

    if zoom_state == ZoomState.ZoomingIn or zoom_state == ZoomState.ZoomingOut then
        if zoom_time <= 1 then
            -- During zoom-in, keep tracking cursor so it stays centered
            if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                local t = calculate_zoom_target(zoom_value)
                target_pos.x = t.pos_x
                target_pos.y = t.pos_y
            end

            -- Lerp from START to TARGET (not current→target)
            -- This gives a true eased animation instead of exponential decay
            local eased = ease_in_out(zoom_time)
            local new_scale = lerp(start_scale, target_scale, eased)
            local new_x = lerp(start_pos.x, target_pos.x, eased)
            local new_y = lerp(start_pos.y, target_pos.y, eased)
            apply_group_transform(new_x, new_y, new_scale)
        end
    elseif zoom_state == ZoomState.ZoomedIn then
        -- Follow mouse while zoomed in
        if is_following_mouse then
            local t = calculate_zoom_target(zoom_value)

            local skip_frame = false
            if not use_follow_outside_bounds then
                -- Check if mouse is outside the canvas bounds
                if t.raw_mouse.x < 0 or t.raw_mouse.x > canvas_w or
                   t.raw_mouse.y < 0 or t.raw_mouse.y > canvas_h then
                    skip_frame = true
                end
            end

            if not skip_frame then
                -- Safe-zone / locked-center logic
                if locked_center ~= nil then
                    local diff = {
                        x = t.raw_mouse.x - locked_center.x,
                        y = t.raw_mouse.y - locked_center.y
                    }
                    local track = {
                        x = canvas_w * (0.5 - (follow_border * 0.01)),
                        y = canvas_h * (0.5 - (follow_border * 0.01))
                    }

                    if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                        locked_center = nil
                        locked_last_pos = {
                            x = t.raw_mouse.x,
                            y = t.raw_mouse.y,
                            diff_x = diff.x,
                            diff_y = diff.y
                        }
                        log("Safe-zone exited — resume tracking")
                    end
                end

                if locked_center == nil and (t.pos_x ~= current_pos.x or t.pos_y ~= current_pos.y) then
                    local new_x = lerp(current_pos.x, t.pos_x, follow_speed)
                    local new_y = lerp(current_pos.y, t.pos_y, follow_speed)
                    apply_group_transform(new_x, new_y, current_scale)

                    -- Check if we should lock again
                    if locked_last_pos ~= nil then
                        local diff = {
                            x = math.abs(current_pos.x - t.pos_x),
                            y = math.abs(current_pos.y - t.pos_y),
                            auto_x = t.raw_mouse.x - locked_last_pos.x,
                            auto_y = t.raw_mouse.y - locked_last_pos.y
                        }

                        locked_last_pos.x = t.raw_mouse.x
                        locked_last_pos.y = t.raw_mouse.y

                        local lock = false
                        if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                            if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or
                               (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                lock = true
                            end
                        else
                            if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or
                               (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                lock = true
                            end
                        end

                        if (lock and use_follow_auto_lock) or
                           (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                            locked_center = {
                                x = t.raw_mouse.x,
                                y = t.raw_mouse.y
                            }
                            log("Cursor stopped — tracking locked")
                        end
                    end
                end
            end
        end
    end

    -- Check animation completion
    if zoom_time >= 1 then
        local should_stop = false

        if zoom_state == ZoomState.ZoomingOut then
            log("Canvas zoom out complete")
            -- Snap to exact original values
            apply_group_transform(group_pos_orig.x, group_pos_orig.y, group_scale_orig.x)
            zoom_state = ZoomState.None
            should_stop = true

        elseif zoom_state == ZoomState.ZoomingIn then
            log("Canvas zoom in complete")
            -- Snap to exact target
            apply_group_transform(target_pos.x, target_pos.y, target_scale)
            zoom_state = ZoomState.ZoomedIn
            should_stop = (not use_auto_follow_mouse) and (not is_following_mouse)

            if use_auto_follow_mouse then
                is_following_mouse = true
                log("Mouse tracking on (auto follow)")
            end

            -- Set initial safe-zone lock
            if is_following_mouse and follow_border < 50 then
                local t = calculate_zoom_target(zoom_value)
                locked_center = { x = t.raw_mouse.x, y = t.raw_mouse.y }
                log("Initial tracking lock set")
            end
        end

        if should_stop then
            is_timer_running = false
            obs.timer_remove(on_zoom_timer)
        end
    end
end

---------------------------------------------------------------------------
-- Click-zoom polling
---------------------------------------------------------------------------
function on_click_poll_timer()
    if not use_script_enabled or not use_click_zoom then
        click_poll_timer_running = false
        obs.timer_remove(on_click_poll_timer)
        return
    end

    local now = obs.os_gettime_ns() / 1e9

    local button_held = false
    if click_zoom_left and is_mouse_button_down(1) then button_held = true end
    if click_zoom_right and is_mouse_button_down(2) then button_held = true end
    if click_zoom_middle and is_mouse_button_down(3) then button_held = true end

    if button_held then
        if not is_click_down then
            is_click_down = true
            click_down_time = now
            click_release_time = -1
            click_zoom_unzoom_pending = false
            log("[ClickZoom] Button pressed — zooming in")
            do_zoom_in()
        end
    else
        if is_click_down then
            is_click_down = false
            click_release_time = now
            click_zoom_unzoom_pending = true
            log("[ClickZoom] Button released — will zoom out after delay")
        end

        if click_zoom_unzoom_pending and click_release_time > 0 then
            local release_elapsed = now - click_release_time
            local time_since_press = now - click_down_time
            local ready = (time_since_press >= click_zoom_min_duration) and
                          (release_elapsed >= click_zoom_release_delay)

            if ready then
                click_zoom_unzoom_pending = false
                log("[ClickZoom] Triggering zoom-out")
                do_zoom_out()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Hotkey handlers
---------------------------------------------------------------------------
function on_toggle_enable(pressed)
    if pressed then
        local current_settings = obs.obs_data_create()
        -- Load current settings so we don't wipe them, then flip the enabled flag
        obs.obs_data_set_bool(current_settings, "script_enabled", not use_script_enabled)
        -- We apply this indirectly by updating our global variable and triggering
        -- the same cleanup logic we'd do in script_update
        use_script_enabled = not use_script_enabled
        log("Script is now " .. (use_script_enabled and "ENABLED" or "DISABLED"))

        if not use_script_enabled then
            release_group()
            if click_poll_timer_running then
                click_poll_timer_running = false
                obs.timer_remove(on_click_poll_timer)
                is_click_down = false
                click_zoom_unzoom_pending = false
                log("[ClickZoom] Poll timer stopped (script disabled)")
            end
        else
            if use_click_zoom and not click_poll_timer_running then
                click_poll_timer_running = true
                obs.timer_add(on_click_poll_timer, CLICK_POLL_INTERVAL_MS)
                log("[ClickZoom] Poll timer started (script enabled)")
            end
        end
    end
end

function on_toggle_zoom(pressed)
    if pressed and use_script_enabled then
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            if zoom_state == ZoomState.ZoomedIn then
                do_zoom_out()
            else
                do_zoom_in()
            end
        end
    end
end

function on_toggle_follow(pressed)
    if pressed and use_script_enabled then
        is_following_mouse = not is_following_mouse
        log("Mouse tracking is " .. (is_following_mouse and "on" or "off"))

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            if not is_timer_running then
                is_timer_running = true
                local interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_zoom_timer, interval)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------
function on_transition_start(t)
    log("Transition started — resetting zoom")
    release_group()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("Scene changed — re-finding group")
        find_zoom_group()
    end
end

---------------------------------------------------------------------------
-- Script description
---------------------------------------------------------------------------
function script_description()
    return "<h2>OBS Canvas Zoom v" .. VERSION .. "</h2>" ..
           "<p>Screen Studio-style canvas-level zoom.</p>" ..
           "<p>Zooms a Group (background + screen recording) by transforming " ..
           "position/scale instead of cropping. The background stays visible " ..
           "around the edges during zoom.</p>" ..
           "<p><b>Setup:</b> Use the 'Auto Create Zoom Setup' button below, then " ..
           "add your Display Capture into the newly created <i>ZoomGroup</i>, and " ..
           "choose a background Image file.</p>"
end

---------------------------------------------------------------------------
-- Auto Setup helper
---------------------------------------------------------------------------
function do_auto_setup()
    if group_name == nil or group_name == "" then
        obs.script_log(obs.OBS_LOG_WARNING, "[Canvas Zoom] Set a group name first!")
        return false
    end

    local scene_source = obs.obs_frontend_get_current_scene()
    if not scene_source then return false end
    
    local scene = obs.obs_scene_from_source(scene_source)
    if not scene then
        return false
    end

    local group = obs.obs_scene_find_source(scene, group_name)
    if group then
        obs.script_log(obs.OBS_LOG_INFO, "[Canvas Zoom] Group '" .. group_name .. "' already exists. Setup skipped.")
        return true
    end

    -- Create group source (OBS owns it after obs_scene_add, we release our ref after)
    local new_group_source = obs.obs_source_create("group", group_name, nil, nil)
    if new_group_source then
        -- Add group to current scene
        obs.obs_scene_add(scene, new_group_source)
        
        -- Get the group's internal scene via obs_group_from_source (the correct API)
        local group_inner_scene = obs.obs_group_from_source(new_group_source)
        if group_inner_scene then
            -- Create image source and add it directly into the group's inner scene
            local img_settings = obs.obs_data_create()
            obs.obs_data_set_string(img_settings, "file", "")
            local img_source = obs.obs_source_create("image_source", "Background Image (Assign Me)", img_settings, nil)
            
            if img_source then
                obs.obs_scene_add(group_inner_scene, img_source)
            end
        end
        
        obs.script_log(obs.OBS_LOG_INFO, "=========================================")
        obs.script_log(obs.OBS_LOG_INFO, "[Canvas Zoom] Auto Setup Complete!")
        obs.script_log(obs.OBS_LOG_INFO, "  1. Drag your Display/Window Capture into '" .. group_name .. "'")
        obs.script_log(obs.OBS_LOG_INFO, "  2. Double-click 'Background Image (Assign Me)' to pick your image file.")
        obs.script_log(obs.OBS_LOG_INFO, "=========================================")
    end

    has_logged_missing_group = false
    find_zoom_group()
    return true
end

---------------------------------------------------------------------------
-- Script properties (UI)
---------------------------------------------------------------------------
function script_properties()
    local props = obs.obs_properties_create()

    -- ── Setup ────────────────────────────────────────────────
    obs.obs_properties_add_bool(props, "script_enabled", "Enable Script")
    obs.obs_properties_add_text(props, "group_name", "Group Source Name", obs.OBS_TEXT_DEFAULT)

    obs.obs_properties_add_button(props, "auto_setup_scene", "⚡ Auto Create Zoom Setup", function()
        do_auto_setup()
        return true
    end)
    obs.obs_properties_add_button(props, "refresh_group", "↻ Refresh Group", function()
        find_zoom_group()
        return true
    end)

    -- ── Zoom ─────────────────────────────────────────────────
    obs.obs_properties_add_float(props, "zoom_value", "Zoom Factor", 1.0, 10.0, 0.05)
    obs.obs_properties_add_float_slider(props, "zoom_speed", "Zoom Speed", 0.01, 1.0, 0.01)
    obs.obs_properties_add_int_slider(props, "edge_padding", "Edge Padding (%)", 0, 20, 1)

    -- ── Click Zoom ───────────────────────────────────────────
    obs.obs_properties_add_group(props, "click_zoom_group", "Screen Studio Click Zoom",
        obs.OBS_GROUP_CHECKABLE, (function()
            local sub = obs.obs_properties_create()
            obs.obs_properties_add_bool(sub, "click_zoom_left",   "Left Click")
            obs.obs_properties_add_bool(sub, "click_zoom_right",  "Right Click")
            obs.obs_properties_add_bool(sub, "click_zoom_middle", "Middle Click")
            obs.obs_properties_add_float_slider(sub, "click_zoom_release_delay",
                "Unzoom Delay (sec)", 0.0, 10.0, 0.05)
            obs.obs_properties_add_float_slider(sub, "click_zoom_min_duration",
                "Min Zoom Duration (sec)", 0.0, 10.0, 0.05)
            return sub
        end)())

    -- ── Mouse Follow ─────────────────────────────────────────
    obs.obs_properties_add_bool(props, "follow", "Auto Follow Mouse")
    obs.obs_properties_add_bool(props, "follow_outside_bounds", "Follow Outside Bounds")
    obs.obs_properties_add_float_slider(props, "follow_speed", "Follow Speed", 0.01, 1.0, 0.01)
    obs.obs_properties_add_int_slider(props, "follow_border", "Follow Border (%)", 0, 50, 1)
    obs.obs_properties_add_int_slider(props, "follow_safezone_sensitivity", "Lock Sensitivity", 1, 20, 1)
    obs.obs_properties_add_bool(props, "follow_auto_lock", "Auto Lock on Reverse Direction")

    -- ── Monitor Override ─────────────────────────────────────
    local override = obs.obs_properties_add_bool(props, "use_monitor_override", "Manual Monitor Position")
    obs.obs_property_set_long_description(override,
        "Override the auto-detected monitor position/size for cursor mapping")
    local ov_x = obs.obs_properties_add_int(props, "monitor_override_x", "Monitor X", -10000, 10000, 1)
    local ov_y = obs.obs_properties_add_int(props, "monitor_override_y", "Monitor Y", -10000, 10000, 1)
    local ov_w = obs.obs_properties_add_int(props, "monitor_override_w", "Monitor Width",  0, 10000, 1)
    local ov_h = obs.obs_properties_add_int(props, "monitor_override_h", "Monitor Height", 0, 10000, 1)

    obs.obs_property_set_visible(ov_x, use_monitor_override)
    obs.obs_property_set_visible(ov_y, use_monitor_override)
    obs.obs_property_set_visible(ov_w, use_monitor_override)
    obs.obs_property_set_visible(ov_h, use_monitor_override)

    obs.obs_property_set_modified_callback(override, function(p, prop, settings)
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(p, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(p, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(p, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(p, "monitor_override_h"), visible)
        return true
    end)

    -- ── Debug ────────────────────────────────────────────────
    obs.obs_properties_add_bool(props, "debug_logs", "Enable Debug Logging")

    return props
end

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "script_enabled", true)
    obs.obs_data_set_default_string(settings, "group_name", "ZoomGroup")
    obs.obs_data_set_default_double(settings, "zoom_value", 1.4)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_int(settings, "edge_padding", 5)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
    obs.obs_data_set_default_bool(settings, "click_zoom_group", true)
    obs.obs_data_set_default_bool(settings, "click_zoom_left", true)
    obs.obs_data_set_default_bool(settings, "click_zoom_right", true)
    obs.obs_data_set_default_bool(settings, "click_zoom_middle", true)
    obs.obs_data_set_default_double(settings, "click_zoom_release_delay", 2.0)
    obs.obs_data_set_default_double(settings, "click_zoom_min_duration", 5.0)
end

---------------------------------------------------------------------------
-- Load
---------------------------------------------------------------------------
function script_load(settings)
    -- Register hotkeys
    hotkey_enable_id = obs.obs_hotkey_register_frontend("canvas_enable_toggle", "Toggle canvas script ON/OFF",
        on_toggle_enable)
    hotkey_zoom_id = obs.obs_hotkey_register_frontend("canvas_zoom_toggle", "Toggle canvas zoom",
        on_toggle_zoom)
    hotkey_follow_id = obs.obs_hotkey_register_frontend("canvas_follow_toggle", "Toggle canvas follow",
        on_toggle_follow)

    -- Restore hotkey bindings
    local arr = obs.obs_data_get_array(settings, "canvas_zoom.hotkey.enable")
    obs.obs_hotkey_load(hotkey_enable_id, arr)
    obs.obs_data_array_release(arr)

    arr = obs.obs_data_get_array(settings, "canvas_zoom.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, arr)
    obs.obs_data_array_release(arr)

    arr = obs.obs_data_get_array(settings, "canvas_zoom.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, arr)
    obs.obs_data_array_release(arr)

    -- Load settings
    use_script_enabled = obs.obs_data_get_bool(settings, "script_enabled")
    group_name = obs.obs_data_get_string(settings, "group_name")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    edge_padding = obs.obs_data_get_int(settings, "edge_padding")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")
    use_click_zoom = obs.obs_data_get_bool(settings, "click_zoom_group")
    click_zoom_left = obs.obs_data_get_bool(settings, "click_zoom_left")
    click_zoom_right = obs.obs_data_get_bool(settings, "click_zoom_right")
    click_zoom_middle = obs.obs_data_get_bool(settings, "click_zoom_middle")
    click_zoom_release_delay = obs.obs_data_get_double(settings, "click_zoom_release_delay")
    click_zoom_min_duration = obs.obs_data_get_double(settings, "click_zoom_min_duration")

    -- Start click poll if enabled
    if use_script_enabled and use_click_zoom and not click_poll_timer_running then
        click_poll_timer_running = true
        obs.timer_add(on_click_poll_timer, CLICK_POLL_INTERVAL_MS)
    end

    -- Events
    obs.obs_frontend_add_event_callback(on_frontend_event)

    -- Transition handlers
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for _, s in pairs(transitions) do
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
    end

    if ffi.os == "Linux" and not x11_display then
        log("ERROR: Could not get X11 Display for Linux")
    end
end

---------------------------------------------------------------------------
-- Save
---------------------------------------------------------------------------
function script_save(settings)
    if hotkey_enable_id ~= nil then
        local arr = obs.obs_hotkey_save(hotkey_enable_id)
        obs.obs_data_set_array(settings, "canvas_zoom.hotkey.enable", arr)
        obs.obs_data_array_release(arr)
    end
    if hotkey_zoom_id ~= nil then
        local arr = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "canvas_zoom.hotkey.zoom", arr)
        obs.obs_data_array_release(arr)
    end
    if hotkey_follow_id ~= nil then
        local arr = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "canvas_zoom.hotkey.follow", arr)
        obs.obs_data_array_release(arr)
    end
end

---------------------------------------------------------------------------
-- Update (when user changes settings)
---------------------------------------------------------------------------
function script_update(settings)
    local old_enabled = use_script_enabled
    local old_group = group_name

    use_script_enabled = obs.obs_data_get_bool(settings, "script_enabled")
    group_name = obs.obs_data_get_string(settings, "group_name")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    edge_padding = obs.obs_data_get_int(settings, "edge_padding")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")
    use_click_zoom = obs.obs_data_get_bool(settings, "click_zoom_group")
    click_zoom_left   = obs.obs_data_get_bool(settings, "click_zoom_left")
    click_zoom_right  = obs.obs_data_get_bool(settings, "click_zoom_right")
    click_zoom_middle = obs.obs_data_get_bool(settings, "click_zoom_middle")
    click_zoom_release_delay = obs.obs_data_get_double(settings, "click_zoom_release_delay")
    click_zoom_min_duration  = obs.obs_data_get_double(settings, "click_zoom_min_duration")

    -- Re-find group if name changed
    if use_script_enabled and group_name ~= old_group then
        find_zoom_group()
    end

    -- Process enable/disable toggle
    if use_script_enabled and not old_enabled then
        log("Script enabled from settings")
        find_zoom_group()
    elseif not use_script_enabled and old_enabled then
        log("Script disabled from settings - releasing group")
        release_group()
    end

    -- Manage click poll timer
    if use_script_enabled and use_click_zoom and not click_poll_timer_running then
        click_poll_timer_running = true
        obs.timer_add(on_click_poll_timer, CLICK_POLL_INTERVAL_MS)
        log("[ClickZoom] Poll timer started")
    elseif (not use_script_enabled or not use_click_zoom) and click_poll_timer_running then
        click_poll_timer_running = false
        obs.timer_remove(on_click_poll_timer)
        is_click_down = false
        click_zoom_unzoom_pending = false
        log("[ClickZoom] Poll timer stopped")
    end
end

---------------------------------------------------------------------------
-- Unload
---------------------------------------------------------------------------
function script_unload()
    -- CRITICAL: Remove ALL timers first. A timer firing after Lua context
    -- is destroyed causes an access violation crash.
    if is_timer_running then
        obs.timer_remove(on_zoom_timer)
        is_timer_running = false
    end
    if click_poll_timer_running then
        obs.timer_remove(on_click_poll_timer)
        click_poll_timer_running = false
    end

    zoom_state = ZoomState.None
    is_click_down = false
    click_zoom_unzoom_pending = false

    -- These are unowned/borrowed refs — just nil them, never release.
    group_sceneitem = nil
    group_source = nil

    -- Wrap signal disconnect in pcall — during OBS shutdown the transition
    -- sources may already be invalid, causing obs_source_release to crash.
    pcall(function()
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for _, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end
    end)

    pcall(function() obs.obs_frontend_remove_event_callback(on_frontend_event) end)
    pcall(function() obs.obs_hotkey_unregister(hotkey_enable_id) end)
    pcall(function() obs.obs_hotkey_unregister(hotkey_zoom_id) end)
    pcall(function() obs.obs_hotkey_unregister(hotkey_follow_id) end)

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
    end
end
