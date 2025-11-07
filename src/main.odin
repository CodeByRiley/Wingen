package main

import "core:mem"
import "core:simd"
import "core:c"
import math "core:math"
import "core:strings"
import "core:fmt"
import rlgl "vendor:raylib/rlgl"
import rl "vendor:raylib"
import "shared:nfd"
import world   "world"
import helpers "helpers"


UNITS_TO_METER    : f32 = 100 // 100 UNITS TO 1 METER
CAMERA_MOVE_SPEED : f32 = 50
MAX_ENTITIES      : int = 16

app := helpers.App{}
cam_control_active : bool

Camera :: struct {
    // state
    pivot        : rl.Vector3, // point we orbit around
    distance     : f32,        // eye-to-pivot distance
    yaw          : f32,        // radians, around +Y (turntable)
    pitch        : f32,        // radians, +up is positive; clamp near +/- 90°

    // optics
    fov_y_deg    : f32,        // vertical FOV in degrees
    projection   : rl.CameraProjection,

    // tuning
    orbit_speed  : f32, // radians per pixel
    pan_speed    : f32, // multiplier for world-units per pixel at distance 1
    zoom_speed   : f32, // dolly per pixel (ctrl+MMB) or per wheel step
    min_distance : f32,
    max_distance : f32,
    invert_y     : bool,
}

camera := Camera {
    pivot        = rl.Vector3{0, 0, 0},
    distance     = 10.0,
    yaw          = 0.0,
    pitch        = 0.0,
    fov_y_deg    = 45.0,
    projection   = .PERSPECTIVE,
    orbit_speed  = 0.01,
    pan_speed    = 0.1,
    zoom_speed   = 0.1,
    min_distance = 1.0,
    max_distance = 100.0,
    invert_y     = false,
}

camera_make :: proc(pivot: rl.Vector3) -> Camera {
    return Camera {
            pivot        = pivot,
            distance     = 6.0,
            yaw          = math.to_radians_f32(45.0),
            pitch        = math.to_radians_f32(20.0),
            fov_y_deg    = 70.0,
            projection   = rl.CameraProjection.PERSPECTIVE,

            orbit_speed  = 0.005,   // ~0.3 rad for 60px drag
            pan_speed    = 1.0,     // used with distance & FOV scaling below
            zoom_speed   = 0.05,    // dolly per pixel and wheel scalar
            min_distance = 0.1,
            max_distance = 1000.0,
            invert_y     = true,
        }
}

sim_world : world.World

main :: proc() {
    helpers.Log("Creating Wingen")
    helpers.load_settings(&app)
    helpers.Log(app.title)
    helpers.Log(fmt.tprintf("Window Size %dx%d", app.width, app.height))
    rl.SetConfigFlags({rl.ConfigFlag.MSAA_4X_HINT, rl.ConfigFlag.WINDOW_RESIZABLE})
    switch (app.fullscreen) {
        case .BORDERLESS:
            rl.SetConfigFlags({.BORDERLESS_WINDOWED_MODE})
        case .EXCLUSIVE:
            rl.SetConfigFlags({.FULLSCREEN_MODE})
        case .WINDOWED:
            rl.SetConfigFlags({.WINDOW_RESIZABLE})
    }
    rl.InitWindow(app.width, app.height, strings.clone_to_cstring(app.title))
    defer rl.CloseWindow()
    rl.GuiLoadStyle("assets/style/cherry.style")
    sim_world = world.make_world()
    defer world.clear_world(&sim_world)

    // id := world.add_parts_from_file(&sim_world, "assets/models/cow.glb", "Suzanne")
    // if id >= 0 {
    //     bmin, bmax, ok := world.get_entity_bounds(&sim_world.entities[id])
    //     if ok do cam_focus_aabb(&camera, bmin, bmax, 1.2)
    // }

    rlgl.SetClipPlanes(0.05, 50000.0)

    camera = camera_make(helpers.v3(0,0,0))

    for(!rl.WindowShouldClose()) {
        update()

        rl.BeginDrawing()
        rl.ClearBackground(rl.GRAY)
        draw_ui()
        rl.BeginMode3D(to_raylib_camera(&camera))
        world.draw(&sim_world)
        //draw_world()
        rl.EndMode3D()
        rl.EndDrawing()
    }

    if(rl.WindowShouldClose()) {
        app.width = rl.GetScreenWidth()
        app.height = rl.GetScreenHeight()
        helpers.save_settings(&app)
    }
}

draw_world :: proc() {
    rl.DrawGrid(250,1*UNITS_TO_METER) // 100 units to 1 meter
    rl.DrawCube(helpers.v3(0,0,0), 2*UNITS_TO_METER, 2*UNITS_TO_METER, 2*UNITS_TO_METER, rl.BLACK)
}

draw_ui :: proc() {
    model_viewer_rect := rl.Rectangle {
        x = 5, y = 5,
        width = 200,
        height = 700,
    }
    rl.DrawRectangle(cast(i32)model_viewer_rect.x, cast(i32)model_viewer_rect.y, cast(i32)model_viewer_rect.width, cast(i32)model_viewer_rect.height, rl.Color{77,77,77,150})
    rl.GuiGroupBox(model_viewer_rect, "Model Viewer")
    ent_amt := len(sim_world.entities)
    rl.GuiLabel(rl.Rectangle{x=10, y=70, width=200,height=10}, fmt.ctprintf("Entites: %d", ent_amt))
    // rl.GuiLabel(rl.Rectangle{x=7, y=105, width=200,height=10}, fmt.ctprintf("Vertices: %d", for i in sim_world.entities[:] {

    // }))
    if ent_amt < MAX_ENTITIES {
            if rl.GuiButton(rl.Rectangle{x=10, y=15, width=190, height=35}, "Load Model") {
                ok, path := open_model_dialog()
                if !ok || len(path) == 0 {
                    helpers.Log("User cancelled file import")
                    return
                }

                id := world.add_parts_from_file(&sim_world, path, helpers.file_stem_from_path(path))
                if id < 0 {
                    helpers.Log("Failed to load model into world", .ERROR)
                    return
                }

                bmin, bmax, got_bounds := world.get_entity_bounds(&sim_world.entities[id])
                if got_bounds {
                    fmt.printf("AABB min=(%.2f, %.2f, %.2f) max=(%.2f, %.2f, %.2f)\n",
                               bmin.x, bmin.y, bmin.z, bmax.x, bmax.y, bmax.z)
                }

                helpers.Log("Model loaded successfully", .INFO)
            }
        }
}

update :: proc() {
    update_cam_control_state()
    cam_update(&camera, rl.GetFrameTime())
    move_speed := CAMERA_MOVE_SPEED * rl.GetFrameTime()
    pos, fwd, right, up := cam_basis(&camera)
    _ = pos; _ = up


    //helpers.Log(fmt.tprintf("Camera Position: x%f y%f z%f", camera.pivot.x, camera.pivot.y, camera.pivot.z))
    if helpers.key_action_down(app.keybinds, "cam_move_enable") {
        spd := CAMERA_MOVE_SPEED * rl.GetFrameTime() * (helpers.key_action_down(app.keybinds, "cam_speed") ? 3.0 : 1.0)
        if helpers.key_action_down(app.keybinds, "cam_move_left")     do camera.pivot = helpers.v3_add(camera.pivot, helpers.v3_scale(right, -spd))
        if helpers.key_action_down(app.keybinds, "cam_move_right")    do camera.pivot = helpers.v3_add(camera.pivot, helpers.v3_scale(right,  spd))
        if helpers.key_action_down(app.keybinds, "cam_move_forward")  do camera.pivot = helpers.v3_add(camera.pivot, helpers.v3_scale(fwd,    spd))
        if helpers.key_action_down(app.keybinds, "cam_move_backward") do camera.pivot = helpers.v3_add(camera.pivot, helpers.v3_scale(fwd,   -spd))
    }
    if helpers.key_action_pressed(app.keybinds, "cam_focus") {

        cam_focus_aabb(&camera, helpers.v3(-1,-1,-1), helpers.v3(1,1,1))
    }
}

update_cam_control_state :: proc() {
    look_want := helpers.key_action_down(app.keybinds, "cam_move_enable") ||
                 helpers.mouse_action_down(app.mousebinds, "cam_look")

    if helpers.key_action_pressed(app.keybinds, "cam_focus") {
        cam_focus_aabb(&camera, helpers.v3(-1,-1,-1), helpers.v3(1,1,1))
        look_want = true
    }

    if rl.IsWindowMinimized() || !rl.IsWindowFocused() {
        look_want = false
    }

    if look_want && !cam_control_active {
        cam_control_active = true
        rl.DisableCursor()
        _ = rl.GetMouseDelta() // flush initial jump
    } else if !look_want && cam_control_active {
        cam_control_active = false
        rl.EnableCursor()
    }

    // Hardcode esc to save cursor
    if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) && cam_control_active {
        cam_control_active = false
        rl.EnableCursor()
    }
}

cam_focus_aabb :: proc(c: ^Camera, bmin, bmax: rl.Vector3, margin :f32= 1.2) {
    center := helpers.v3_scale(helpers.v3_add(bmin, bmax), 0.5)
    ext    := helpers.v3_scale(helpers.v3_sub(bmax, bmin), 0.5) // half-extents
    radius := helpers.v3_len(ext)

    c^.pivot = center
    // compute distance to fit height and width, pick the larger
    aspect := f32(rl.GetScreenWidth()) / f32(rl.GetScreenHeight())
    fov_y := math.to_radians(c^.fov_y_deg)
    fov_x := 2.0*math.atan(math.tan(fov_y*0.5)*aspect)
    need_h := ext.y / math.tan(fov_y*0.5)
    need_w := math.max(ext.x, ext.z) / math.tan(fov_x*0.5)
    c^.distance = margin * math.max(need_h, need_w)
    c^.distance = math.clamp(c^.distance, c^.min_distance, c^.max_distance)
}

cam_update :: proc(c: ^Camera, dt: f32) {
    mmb   := helpers.mouse_action_down(app.mousebinds, "cam_look")
    shift := rl.IsKeyDown(rl.KeyboardKey.LEFT_SHIFT)   || rl.IsKeyDown(rl.KeyboardKey.RIGHT_SHIFT)
    ctrl  := rl.IsKeyDown(rl.KeyboardKey.LEFT_CONTROL) || rl.IsKeyDown(rl.KeyboardKey.RIGHT_CONTROL)
    moving := helpers.key_action_down(app.keybinds, "cam_move_enable")

    // (Optional) focus key — make sure the name matches your INI ("cam_focus")
    if helpers.key_action_pressed(app.keybinds, "cam_focus") {
        cam_focus_aabb(c, helpers.v3(-1,-1,-1), helpers.v3(1,1,1))
    }

    // Wheel zoom – always allowed (or gate on cam_control_active if you prefer)
    wheel := rl.GetMouseWheelMove()
    if wheel != 0 {
        factor := math.pow(1.0 - c^.zoom_speed, wheel)
        c^.distance = math.clamp(c^.distance * factor, c^.min_distance, c^.max_distance)
    }

    if cam_control_active {
        md := rl.GetMouseDelta()
        dx := md.x
        dy := md.y

        // Only PAN/DOLLY when MMB is down (Blender-like)
        if mmb && shift {
            // PAN
            _, _, right, up := cam_basis(c)
            px_to_world := (2.0 * c^.distance * math.tan(math.to_radians(c^.fov_y_deg)*0.5)) / f32(rl.GetScreenHeight())
            scale := c^.pan_speed * px_to_world
            c^.pivot = helpers.v3_add(c^.pivot,
                helpers.v3_add(helpers.v3_scale(right, -dx*scale),
                               helpers.v3_scale(up,     dy*scale)))
        } else if mmb && ctrl {
            // DOLLY
            sign : f32 = -1.0
            c^.distance = c^.distance * (1.0 + sign * dy * c^.zoom_speed * 0.01)
            c^.distance = math.clamp(c^.distance, c^.min_distance, c^.max_distance)
        } else if mmb || moving {
            // ORBIT when either MMB is held OR cam_move_enable is held
            sy : f32 = 1.0; if c^.invert_y do sy = -1.0
            c^.yaw   += dx * c^.orbit_speed
            c^.pitch -= dy * c^.orbit_speed * sy
            if c^.yaw >  math.PI { c^.yaw -= 2.0*math.PI }
            if c^.yaw < -math.PI { c^.yaw += 2.0*math.PI }
        }
    }
}

cam_position :: proc(c: ^Camera) -> rl.Vector3 {
    // clamp pitch to avoid gimbal flip
    max_pitch := math.to_radians_f32(89.0)
    c^.pitch = math.clamp(c^.pitch, -max_pitch, max_pitch)

    cp := math.cos_f32(c^.pitch)
    sp := math.sin_f32(c^.pitch)
    cy := math.cos_f32(c^.yaw)
    sy := math.sin_f32(c^.yaw)

    // forward from pivot to camera is opposite of look dir
    offset := rl.Vector3{ c^.distance*cp*cy, c^.distance*sp, c^.distance*cp*sy }
    // camera sits at pivot + offset
    return helpers.v3_add(c^.pivot, offset)
}

cam_basis :: proc(c: ^Camera) -> (pos, fwd, right, up: rl.Vector3) {
    pos = cam_position(c)
    world_up := helpers.v3(0,1,0)

    // forward is from camera to pivot
    fwd = helpers.v3_norm(helpers.v3_sub(c^.pivot, pos))
    right = helpers.v3_norm(helpers.v3_cross(fwd, world_up))
    up = helpers.v3_cross(right, fwd) // already normalized
    return
}

to_raylib_camera :: proc(c: ^Camera) -> rl.Camera3D {
    pos := cam_position(c)
    return rl.Camera3D{
        position   = pos,
        target     = c^.pivot,
        up         = helpers.v3(0,1,0),       // keep turntable “up” stable
        fovy       = c^.fov_y_deg,
        projection = c^.projection,
    }
}

open_model_dialog :: proc() -> (ok: bool, path: string) {
    filters := [2]nfd.Filter_Item{
        {"3D Models", "obj,fbx,gltf,glb,dae"},
        {"All Files", "*"},
    }
    args := nfd.Open_Dialog_Args{
        filter_list  = raw_data(filters[:]),
        filter_count = len(filters),
        // parentWindow can be set if the binding exposes it; see NFDe docs.
    }

    selected: cstring
    res := nfd.OpenDialogU8_With(&selected, &args)
    #partial switch res {
    case .Okay:
        s := strings.clone_from_cstring(selected)
        nfd.FreePathU8(selected)
        return true, s
    case .Error:
        fmt.println("NFD error:", nfd.GetError())
    }
    return false, ""
}
