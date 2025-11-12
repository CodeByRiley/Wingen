package ui

import "core:strings"
import rl   "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import fmt  "core:fmt"
import math "core:math"
import aero "../wingen"

SimPanel :: struct {
// -------- Inputs (SI) --------
   altitude_m        : f32,     // geometric altitude
   dT_K              : f32,    // weather offset from ISA
   airspeed_m        : f32,    // V in m/s (convert from your world units)

   // Geometry / reference
   char_len_m        : f32,     // chord, height, diameter, or body length
   S_ref_m2          : f32,     // planform for wings, frontal area for bodies

   // Drag model
   Cd0               : f32,    // zero-lift/base drag (0.05 streamlined, 0.3 car, 1.0 cube)
   S_wet_over_Sref   : f32,     // 2–3 slender, 5–8 boxy

   // Lift/moment (ignorede_wing=false)
   use_wing          : bool,  // flip to true to enable lift model
   AR                : f32,     // ~1 for non-wings
   e                 : f32,     // 0.7–0.9 wings, ~0.6 bluff
   Cl_alpha          : f32,     // per rad, ~4.5–6.0 for typical wings
   Cm_alpha          : f32,     // per rad, often negative for stable
   stall_deg         : f32,    // 12–16 typical clean
   alpha_deg         : f32,     // AoA
   alpha0_deg        : f32,     // zero-lift AoA (e.g., -2 for cambered)

   // Compressibility (set Mcrit>=1 or k=0 to disable at low speeds)
   Mcrit             : f32,     // 0.7–0.8 transonic airfoils, 2 disables for cars
   wave_drag_k       : f32,     // 0 disables

   // -------- Derived (read-only HUD) --------
   rho               : f32,           // kg/m^3
   mu                : f32,           // Pa·s
   a_ms              : f32,           // m/s
   Mach              : f32,           // -
   Re                : f64,           // -
   q_Pa              : f32,           // Pa
   Cl                : f32,           // -
   Cd                : f32,           // -
   Cm                : f32,           // -
   L_N               : f32,           // N
   D_N               : f32,           // N
}

model_verts : int
model_tris  : int
sim_panel   : SimPanel

// ---------------- Layout helpers ----------------

RowLayout :: struct {
    panel : rl.Rectangle,
    y     : f32,
    pad   : f32,
    h     : f32,
    gap   : f32,
    lab_w : f32,
}

row_start :: proc(panel: rl.Rectangle) -> RowLayout {
    r: RowLayout
    r.panel = panel
    r.y     = panel.y + 10
    r.pad   = 10
    r.h     = 22
    r.gap   = 6
    r.lab_w = 130
    return r
}

// Returns label and control rectangles; advances y
row_split :: proc(r: ^RowLayout) -> (lab: rl.Rectangle, ctrl: rl.Rectangle) {
    lab  = rl.Rectangle{ r.panel.x + r.pad, r.y, r.lab_w, r.h }
    ctrl = rl.Rectangle{ lab.x + lab.width + 8, r.y, r.panel.width - (lab.width + 3*r.pad + 8), r.h }
    r.y += r.h + r.gap
    return
}

section_header :: proc(r: ^RowLayout, title: string) {
    // Thin title + separator line
    rl.GuiLabel(rl.Rectangle{ r.panel.x + r.pad, r.y, r.panel.width - 2*r.pad, r.h }, strings.clone_to_cstring(title))
    r.y += r.h
    rl.GuiLine(rl.Rectangle{ r.panel.x + r.pad, r.y, r.panel.width - 2*r.pad, 1 }, "")
    r.y += r.gap
}

// Slider with live numeric on the right
slider_f32 :: proc(r: ^RowLayout, label: string, v: ^f32, min, max: f32) {
    lab, ctrl := row_split(r)
    rl.GuiLabel(lab, strings.clone_to_cstring(label))
    // Split ctrl into slider + value label
    val_w: f32 = 70
    sld := rl.Rectangle{ ctrl.x, ctrl.y, ctrl.width - val_w - 8, ctrl.height }
    val := rl.Rectangle{ sld.x + sld.width + 8, ctrl.y, val_w, ctrl.height }
    // raygui takes a pointer to value
    rl.GuiSliderBar(sld, "", "", v, min, max)
    rl.GuiLabel(val, fmt.ctprintf("%.3g", v^))
}

// Checkbox (bool)
checkbox :: proc(r: ^RowLayout, label: string, b: ^bool) {
    lab, ctrl := row_split(r)
    rl.GuiLabel(lab, strings.clone_to_cstring(label))
    rl.GuiCheckBox(ctrl, "", b)
}

// Small numeric readout row
readout_f32 :: proc(r: ^RowLayout, label: string, value: f32, unit: string) {
    lab, ctrl := row_split(r)
    rl.GuiLabel(lab, strings.clone_to_cstring(label))
    rl.GuiLabel(ctrl, fmt.ctprintf("%.4g %s", value, unit))
}

readout_f64 :: proc(r: ^RowLayout, label: string, value: f64, unit: string) {
    lab, ctrl := row_split(r)
    rl.GuiLabel(lab, strings.clone_to_cstring(label))
    rl.GuiLabel(ctrl, fmt.ctprintf("%.4g %s", value, unit))
}

update_sim_panel :: proc(sp: ^SimPanel) {
    inputs: aero.SimInputs
    inputs.altitude_m          = sp.altitude_m
    inputs.delta_t_k           = sp.dT_K
    inputs.velocity_ms         = sp.airspeed_m
    inputs.char_len_m          = sp.char_len_m
    inputs.S_ref_m2            = sp.S_ref_m2
    inputs.cd0                 = sp.Cd0
    inputs.S_wet_over_Sref     = sp.S_wet_over_Sref

    if sp.use_wing {
        inputs.ar                  = math.max(0.001, sp.AR)
        inputs.e_oswald            = sp.e
        inputs.Cl_alpha_per_rad    = sp.Cl_alpha
        inputs.Cm_alpha_per_rad    = sp.Cm_alpha
        inputs.stall_deg           = sp.stall_deg
        inputs.alpha_deg           = sp.alpha_deg
        inputs.alpha0_deg          = sp.alpha0_deg
    } else {
        // drag-only defaults
        inputs.ar                  = 1.0
        inputs.e_oswald            = 0.6
        inputs.Cl_alpha_per_rad    = 0.0
        inputs.Cm_alpha_per_rad    = 0.0
        inputs.stall_deg           = 1.0
        inputs.alpha_deg           = 0.0
        inputs.alpha0_deg          = 0.0
    }

    inputs.Mcrit               = sp.Mcrit
    inputs.wave_drag_k         = sp.wave_drag_k

    st := aero.solve_aero(inputs)

    sp.rho   = st.rho
    sp.mu    = st.mu_Pa_s
    sp.a_ms  = st.a_ms
    sp.Mach  = st.Mach
    sp.Re    = st.Re
    sp.q_Pa  = st.q_Pa
    sp.Cl    = st.Cl
    sp.Cd    = st.Cd
    sp.Cm    = st.Cm
    sp.L_N   = st.L_N
    sp.D_N   = st.D_N
}

// ---------------- Main panel ----------------

draw_sim_panel :: proc() {
    // Anchor to right edge; adapts on resize
    sw := cast(f32) rl.GetScreenWidth()
    sh := cast(f32) rl.GetScreenHeight()
    M  : f32 = 8.0
    W  : f32 = 400.0

    panel := rl.Rectangle{ x = sw - W - M, y = M, width = W, height = sh - 2*M }

    // Background + frame
    rl.DrawRectangleRec(panel, rl.Color{77,77,77,150})
    rl.GuiGroupBox(panel, "Simulation Panel")

    // Content
    r := row_start(panel)

    // --- Model stats ---
    section_header(&r, "Model")
    rl.GuiLabel(rl.Rectangle{ panel.x + r.pad, r.y, panel.width - 2*r.pad, r.h },
        fmt.ctprintf("Vertices: %d   Triangles: %d", model_verts, model_tris))
    r.y += r.h + r.gap

    // --- Flight condition ---
    section_header(&r, "Flight Condition")
    slider_f32(&r, "Altitude (m)",  &sim_panel.altitude_m, 0, 15000)
    slider_f32(&r, "ΔT from ISA (K)", &sim_panel.dT_K,   -30, 30)
    slider_f32(&r, "Airspeed (m/s)", &sim_panel.airspeed_m, 0, 200)

    // --- Geometry & base drag ---
    section_header(&r, "Geometry & Base Drag")
    slider_f32(&r, "Char length L (m)", &sim_panel.char_len_m, 0.01, 10)
    slider_f32(&r, "Ref area S (m^2)",  &sim_panel.S_ref_m2,   0.01, 20)
    slider_f32(&r, "Cd0 (form/base)",   &sim_panel.Cd0,        0.0,  1.5)
    slider_f32(&r, "S_wet / S_ref",     &sim_panel.S_wet_over_Sref, 0.0, 10.0)

    // --- Wing / lift (optional) ---
    section_header(&r, "Wing / Lift")
    checkbox(&r, "Enable wing model", &sim_panel.use_wing)
    if sim_panel.use_wing {
        slider_f32(&r, "Aspect ratio AR",   &sim_panel.AR,        0.5, 20)
        slider_f32(&r, "Oswald e",          &sim_panel.e,         0.3, 1.0)
        slider_f32(&r, "Cl_alpha (1/rad)",  &sim_panel.Cl_alpha,  0.0, 8.0)
        slider_f32(&r, "Cm_alpha (1/rad)",  &sim_panel.Cm_alpha, -1.0, 1.0)
        slider_f32(&r, "Stall angle (deg)", &sim_panel.stall_deg,  1.0, 25.0)
        slider_f32(&r, "AoA alpha (deg)",   &sim_panel.alpha_deg, -20.0, 20.0)
        slider_f32(&r, "Alpha0 (deg)",      &sim_panel.alpha0_deg,-10.0, 10.0)
    }

    // --- Compressibility (rarely needed at low V) ---
    section_header(&r, "Compressibility")
    slider_f32(&r, "M_crit",      &sim_panel.Mcrit,      0.5, 2.0)    // set to >=1 to effectively disable for cars
    slider_f32(&r, "Wave drag k", &sim_panel.wave_drag_k, 0.0, 1.0)

    // Recompute aero from inputs (one call; keeps UI live)
    update_sim_panel(&sim_panel)

    // --- Outputs ---
    section_header(&r, "Air Properties")
    readout_f32(&r, "T (K)",     sim_panel.a_ms*sim_panel.a_ms/(aero.GAMMA*aero.R_AIR), "") // or show T from state if you store it
    readout_f32(&r, "ρ (kg/m^3)", sim_panel.rho, "")
    readout_f32(&r, "μ (Pa·s)",   sim_panel.mu, "")

    section_header(&r, "Flow Numbers")
    readout_f32(&r, "a (m/s)",  sim_panel.a_ms, "")
    readout_f32(&r, "Mach",     sim_panel.Mach, "")
    readout_f64(&r, "Re",       sim_panel.Re,   "")
    readout_f32(&r, "q (Pa)",   sim_panel.q_Pa, "")

    section_header(&r, "Coefficients")
    readout_f32(&r, "Cl", sim_panel.Cl, "")
    readout_f32(&r, "Cd", sim_panel.Cd, "")
    readout_f32(&r, "Cm", sim_panel.Cm, "")

    section_header(&r, "Forces")
    readout_f32(&r, "Lift L (N)", sim_panel.L_N, "")
    readout_f32(&r, "Drag D (N)", sim_panel.D_N, "")

    // Optional: footer buttons
    r.y += 4
    btn_row := rl.Rectangle{ panel.x + r.pad, r.y, panel.width - 2*r.pad, r.h }
    half := (btn_row.width - 6) / 2
    if rl.GuiButton(rl.Rectangle{ btn_row.x, btn_row.y, half, r.h }, "Reset") {
        reset_sim_defaults()
    }
    if rl.GuiButton(rl.Rectangle{ btn_row.x + half + 6, btn_row.y, half, r.h }, "Sea-Level Std") {
        sim_panel.altitude_m = 0
        sim_panel.dT_K = 0
    }
}

// Quick defaults you can tweak
reset_sim_defaults :: proc() {
    sim_panel.altitude_m      = 0
    sim_panel.dT_K            = 0
    sim_panel.airspeed_m      = 30

    sim_panel.char_len_m      = 1.0
    sim_panel.S_ref_m2        = 0.5
    sim_panel.Cd0             = 0.30
    sim_panel.S_wet_over_Sref = 2.0

    sim_panel.use_wing        = false
    sim_panel.AR              = 1.0
    sim_panel.e               = 0.6
    sim_panel.Cl_alpha        = 0.0
    sim_panel.Cm_alpha        = 0.0
    sim_panel.stall_deg       = 12
    sim_panel.alpha_deg       = 0
    sim_panel.alpha0_deg      = 0

    sim_panel.Mcrit           = 2.0
    sim_panel.wave_drag_k     = 0.0
}
