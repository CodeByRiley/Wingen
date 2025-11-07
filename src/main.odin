package main

import "core:os"
import "core:fmt"
import "shared:nfd"
import "core:strings"
import world   "world"
import wingen "wingen"
import math "core:math"
import helpers "helpers"
import rl "vendor:raylib"
import rand "core:math/rand"
import rlgl "vendor:raylib/rlgl"

UNITS_TO_METER    : f32 = 100 // 100 UNITS TO 1 METER
CAMERA_MOVE_SPEED : f32 = 50
MAX_ENTITIES      : int = 16

load_in_progress : bool
last_load_time   : f64
last_path        : string

app := helpers.App{}
cam_control_active : bool

SimPanel :: struct {
    altitude_m: f32,
    dT_K:       f32,
    airspeed:   f32,
    char_len_m: f32,
    // Polar inputs
    S_ref: f32,
    Cd0:   f32,
    AR:    f32,
    e:     f32,
    Cl_alpha: f32,
    Cm_alpha: f32,
    stall_deg: f32,
    // Pose
    pitch_deg: f32,
    yaw_deg:   f32,
    roll_deg:  f32,
    aoa_deg:   f32,
}

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

init_texture :: proc(width, height: int, format: rl.PixelFormat) -> rl.Texture2D {
    tex := rl.Texture2D{
        id      = rlgl.LoadTexture(nil, cast(i32)width, cast(i32)height, cast(i32)format, 1),
        width   = cast(i32)width,
        height  = cast(i32)height,
        mipmaps = 1,
        format  = format,
    }
    return tex
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

sim_panel := SimPanel{
    altitude_m = 0.0,
    dT_K       = 0.0,
    airspeed   = 650.0,
    char_len_m = 1.0,

    // Polar defaults
    S_ref      = 1.0,
    Cd0        = 0.02,
    AR         = 7.0,
    e          = 0.8,
    Cl_alpha   = 6.28318,  // ≈ 2π per rad
    Cm_alpha   = -0.5,
    stall_deg  = 15.0,

    // Pose / AoA
    pitch_deg  = 0.0,
    yaw_deg    = 0.0,
    roll_deg   = 0.0,
    aoa_deg    = 5.0,
}

shadow_shader      : rl.Shader
u_shadow_light_dir : i32
u_shadow_opacity   : i32
u_shadow_bias      : i32

load_planar_shadow_shader :: proc() {
    shadow_shader = rl.LoadShader("assets/shaders/planar.vert", "assets/shaders/planar.frag")
    if !rl.IsShaderReady(shadow_shader) {
        fmt.println("Failed to compile planar shadow shader")
    }
    u_shadow_light_dir = rl.GetShaderLocation(shadow_shader, "lightDirWS")
    u_shadow_opacity   = rl.GetShaderLocation(shadow_shader, "opacity")
    u_shadow_bias      = rl.GetShaderLocation(shadow_shader, "bias")
}

sun_dir_from_angles :: proc(azimuth_deg, elevation_deg: f32) -> rl.Vector3 {
    az := math.to_radians_f32(azimuth_deg)
    el := math.to_radians_f32(elevation_deg)
    return helpers.v3_norm(rl.Vector3{
        math.cos_f32(el) * math.cos_f32(az),
        math.sin_f32(el),
        math.cos_f32(el) * math.sin_f32(az),
    })
}

render_wireframe: bool

random_f32 :: proc(min, max: f32) -> f32 {
    // Simplified range random number generation
    return min + (max - min) * rand.float32();
}

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
    load_planar_shadow_shader()
    render_wireframe = false
    sun_dir := sun_dir_from_angles(55.0, 75.0)
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

        rl.BeginMode3D(to_raylib_camera(&camera))

            if len(sim_world.entities) > 0 {
                for &e, _ in &sim_world.entities {
                    // shadow first so the model sits on top
                    draw_planar_shadow(&e.owner, sun_dir, 0.73)
                    //draw_planar_shadow_entity(&e, sun_dir, 0.73)
                    draw_aero_for_entity(&e, &sim_panel)
                }
                if (render_wireframe) {
                    rlgl.EnableWireMode()
                    world.draw(&sim_world)
                    rlgl.DisableWireMode()
                } else {
                    world.draw(&sim_world)
                }
            }
        rl.EndMode3D()

        draw_ui()
        rl.EndDrawing()
    }

    if(rl.WindowShouldClose()) {
        app.width = rl.GetScreenWidth()
        app.height = rl.GetScreenHeight()
        helpers.save_settings(&app)
    }
}

draw_planar_shadow_entity :: proc(e: ^world.EntityParts, light_dir_ws: rl.Vector3, alpha: f32) {
    if !e^.has_model do return
    if math.abs(light_dir_ws.y) < 0.05 do return // avoid crazy stretch

    rl.BeginBlendMode(rl.BlendMode.ALPHA)
    rlgl.DisableDepthMask() // don’t write depth; still test against it

    // Set shader + uniforms
    for i in 0..<int(e^.owner.materialCount) {
        e^.owner.materials[i].shader = shadow_shader
    }
    dir := light_dir_ws
    rl.SetShaderValue(shadow_shader, u_shadow_light_dir, cast(rawptr)&dir, rl.ShaderUniformDataType.VEC3)

    opacity := alpha
    rl.SetShaderValue(shadow_shader, u_shadow_opacity, cast(rawptr)&opacity, rl.ShaderUniformDataType.FLOAT)

    bias : f32 = 0.002 // tweak per scene scale
    rl.SetShaderValue(shadow_shader, u_shadow_bias, cast(rawptr)&bias, rl.ShaderUniformDataType.FLOAT)

    planeY : f32 = 0.0 // ground plane height
    loc_planeY := rl.GetShaderLocation(shadow_shader, "planeY")
    rl.SetShaderValue(shadow_shader, loc_planeY, cast(rawptr)&planeY, rl.ShaderUniformDataType.FLOAT)

    // Draw with the SAME rlgl transform you use for the entity
    rlgl.PushMatrix()
    rlgl.Translatef(e^.offset.x, e^.offset.y, e^.offset.z)
    rlgl.Rotatef(e^.yaw_deg, 0, 1, 0)
    rlgl.Scalef(e^.scale, e^.scale, e^.scale)

    // render the whole model using shadow shader
    rl.DrawModel(e^.owner, rl.Vector3{0,0,0}, 1.0, rl.BLACK)

    rlgl.PopMatrix()

    // Restore materials to their original shaders if you cached them,
    // or just leave them—your normal draw sets its own shaders anyway.

    rlgl.EnableDepthMask()
    rl.EndBlendMode()
}

draw_planar_shadow :: proc(model: ^rl.Model, light_dir_ws: rl.Vector3, alpha: f32) {
    if math.abs(light_dir_ws.y) < 0.05 {
        return // grazing angles make huge smears; skip
    }

    // uniforms
    dir := light_dir_ws
    rl.SetShaderValue(shadow_shader, u_shadow_light_dir, cast(rawptr)&dir, rl.ShaderUniformDataType.VEC3)
    op  := alpha
    rl.SetShaderValue(shadow_shader, u_shadow_opacity,   cast(rawptr)&op,  rl.ShaderUniformDataType.FLOAT)
    bz  := f32(0.002) // ~2mm if your world units are meters*100; tweak per scene scale
    rl.SetShaderValue(shadow_shader, u_shadow_bias,      cast(rawptr)&bz,  rl.ShaderUniformDataType.FLOAT)

    // state: blended, but don't WRITE depth so the shadow never occludes
    rl.BeginBlendMode(rl.BlendMode.ALPHA)
    rlgl.DisableDepthMask()
    rlgl.DisableDepthTest()
    // Save original shaders, swap to shadow shader, draw, restore
    orig := make([]rl.Shader, int(model.materialCount))
    for i in 0..<int(model.materialCount) {
        orig[i] = model.materials[i].shader
        model.materials[i].shader = shadow_shader
    }

    rl.DrawModel(model^, helpers.v3(0,0,0), 1.0, rl.BLACK)

    for i in 0..<int(model.materialCount) {
        model.materials[i].shader = orig[i]
    }

    rlgl.EnableDepthTest()
    rlgl.EnableDepthMask()
    rl.EndBlendMode()
}

draw_aero_for_entity :: proc(e: ^world.EntityParts, panel: ^SimPanel) {
    // 0) Units
    U2M        := 1.0/UNITS_TO_METER
    scale_draw := rl.Vector3{ e^.scale, e^.scale, e^.scale }     // world units
    scale_m    := rl.Vector3{ e^.scale*U2M, e^.scale*U2M, e^.scale*U2M } // meters

    // 1) Entity pose -> row-major TRS
    R_ent  := rl.QuaternionFromAxisAngle(rl.Vector3{0,1,0}, math.to_radians_f32(e^.yaw_deg))
    M_draw := wingen.make_trs_rm(e^.offset, R_ent, scale_draw)   // world-space TRS for CP/axes

    // Body axes from entity
    x_axis, y_axis, z_axis := wingen.axes_from_row_major(M_draw) // x=fwd, y=right, z=up

    // 2) Flow (AoA about body +Y). Air comes FROM this dir.
    aoa      := math.to_radians_f32(panel^.aoa_deg)
    q_aoa    := rl.QuaternionFromAxisAngle(y_axis, aoa)
    flow_dir := -(rl.Vector3RotateByQuaternion(x_axis, q_aoa))
    alpha, beta, flow_hat, drag_dir, lift_dir, _,_,_,_ :=
        wingen.angles_and_dirs(flow_dir, x_axis, y_axis, z_axis)

    mesh := &e^.owner.meshes[0]

    // Areas/volume in meters; CP in world units
    A_surf_m2 := wingen.surface_area(mesh, R_ent, scale_m)
    V_m3      := wingen.approx_mesh_vol(mesh, R_ent, scale_m)

    // Planform area (two-sided) for wings (project onto XY: ±Z)
    A_up_u, _ := wingen.projected_area_and_pressure_center_world(mesh, M_draw,  z_axis)
    A_dn_u, _ := wingen.projected_area_and_pressure_center_world(mesh, M_draw, -z_axis)
    S_wing_m2 := (A_up_u + A_dn_u) * (U2M * U2M)

    // Frontal area for bluff body (project along flow)
    A_front_u, cp_world := wingen.projected_area_and_pressure_center_world(mesh, M_draw, flow_hat)
    S_front_m2          := A_front_u * (U2M * U2M)

    // 4) Atmosphere / inputs
    props := wingen.flow_props(panel^.altitude_m, panel^.airspeed, panel^.dT_K, math.max(panel^.char_len_m, 1e-3))
    inp := wingen.AeroInputs{}
    if panel^.S_ref > 0 {
        inp = wingen.AeroInputs{
            S_ref     = panel^.S_ref,
            L_ref     = panel^.char_len_m,
            Cd0       = panel^.Cd0, AR = panel^.AR, e = panel^.e,
            Cl_alpha  = panel^.Cl_alpha, Cm_alpha = panel^.Cm_alpha,
            stall_deg = panel^.stall_deg,
        }
    } else {
        inp = wingen.AeroInputs{
            S_ref     = S_wing_m2,
            L_ref     = panel^.char_len_m,
            Cd0       = panel^.Cd0, AR = panel^.AR, e = panel^.e,
            Cl_alpha  = panel^.Cl_alpha, Cm_alpha = panel^.Cm_alpha,
            stall_deg = panel^.stall_deg,
        }
    }


    out := wingen.compute_aero_from_inputs(props, alpha, beta, inp.S_ref, &inp, cp_world, lift_dir, drag_dir)

    // 5) HUD + gizmos
    rl.DrawText(fmt.ctprintf("rho=%.3f q=%.0f M=%.2f Re=%.2e", out.props.rho, out.props.q, out.props.M, out.props.Re), 10, 10, 18, rl.WHITE)
    rl.DrawText(fmt.ctprintf("A_surf=%.3f  S_plan=%.3f  S_front=%.3f  Vol≈%.3f", A_surf_m2, S_wing_m2, S_front_m2, V_m3), 10, 30, 18, rl.WHITE)
    rl.DrawText(fmt.ctprintf("AoA=%.1f°  Beta=%.1f°  Cl=%.3f  Cd=%.3f  L=%.1fN  D=%.1fN",
        math.to_degrees_f32(alpha), math.to_degrees_f32(beta), out.Cl, out.Cd, out.Lift, out.Drag), 10, 50, 18, rl.WHITE)

    gain : f32 = 0.02
    rl.DrawLine3D(cp_world, cp_world + flow_hat * (0.5*panel^.airspeed), rl.RED)
    rl.DrawLine3D(cp_world, cp_world + lift_dir * (out.Lift * gain),     rl.GREEN)
    rl.DrawLine3D(cp_world, cp_world + drag_dir * (out.Drag * gain),     rl.BLUE)
}

to_remove := -1
draw_ui :: proc() {
    btn_offset : f32 = 65
    model_viewer_rect := rl.Rectangle {
        x = 5, y = 5,
        width = 200,
        height = 700,
    }
    rl.DrawRectangle(cast(i32)model_viewer_rect.x, cast(i32)model_viewer_rect.y, cast(i32)model_viewer_rect.width, cast(i32)model_viewer_rect.height, rl.Color{77,77,77,150})
    rl.GuiGroupBox(model_viewer_rect, "Model Viewer")
    ent_amt := len(sim_world.entities)
    rl.GuiLabel(rl.Rectangle{x=10, y=70, width=200,height=10}, fmt.ctprintf("Entities: %d", ent_amt))
    for i in 0..<len(sim_world.entities) {
        e := sim_world.entities[i]
        if (rl.GuiButton({10, btn_offset, 190, 35},fmt.ctprintf("remove: %s", e.name))) {
            helpers.Log(fmt.tprintf("Unloading %s", e.name))
            world.remove_entity(&sim_world, cast(int)e.id)
        }
        btn_offset += 40
    }
    if ent_amt < MAX_ENTITIES {
        if rl.GuiButton(rl.Rectangle{x=10, y=15, width=190, height=35}, "Load Model") {
            // Debounce: ignore if we just loaded within 250 ms
            now := rl.GetTime()
            if load_in_progress || (now - last_load_time) < 0.25 {
                // ignore spurious repeat click
            } else {
                load_in_progress = true
                defer { load_in_progress = false }

                ok, path := open_model_dialog()
                if ok && len(path) > 0 {
                    if path != last_path {
                        fmt.printf("LOAD: add_parts_from_file(%s)\n", path)
                        id := world.add_parts_from_file(&sim_world, path, helpers.file_stem_from_path(path))
                        if id < 0 {
                            helpers.Log("Failed to load model into world", .ERROR)
                        } else {
                            last_load_time = rl.GetTime()
                            last_path = path
                        }
                    } else {
                        fmt.println("Skipped: same path as last load")
                    }
                } else {
                    helpers.Log("User cancelled file import")
                }
            }
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

    if(helpers.key_action_pressed(app.keybinds, "render_wireframe")) {
        render_wireframe = !render_wireframe
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
    def := strings.concatenate({os.get_current_directory(context.allocator), "\\assets\\"})
    args := nfd.Open_Dialog_Args{
        filter_list  = raw_data(filters[:]),
        filter_count = len(filters),
        default_path = strings.clone_to_cstring(def)
        // parentWindow can be set if the binding exposes it; see NFDe docs.
    }

    helpers.Log(def)
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
