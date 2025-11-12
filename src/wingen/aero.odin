package wingen

import "core:mem"
import rl "vendor:raylib"
import "core:math"

/// ---- MATH CONSTANTS ----
PI      :: math.PI
TWO_PI  :: 2.0*math.PI
GRAVITY :: 9.80665      // standard gravity
R_AIR   :: 287.05287    // kg*K
GAMMA   :: 1.4          //a= pow(γRT.)
T0      :: 288.15       // K
P0      :: 101325.0     // Pa
L_LAPSE :: 0.0065       // K/m
T_REF   :: 273.15       // K
MU_REF  :: 1.716e-5     // Pa*s
S_SUTH  :: 110.4        // K

Tri :: struct {
    v0,v1,v2: rl.Vector3
}

SimInputs :: struct {
    altitude_m          : f32, // object altitude in meters
    delta_t_k           : f32, // temperature offset in kelvin
    velocity_ms         : f32, // velocity in meters per second
    char_len_m          : f32, // characteristic length in meters
    S_ref_m2            : f32, // reference area in square meters
    cd0                 : f32, // zero lift drag coefficient
    S_wet_over_Sref     : f32, // wetted area over reference area
    ar                  : f32, // aspect ratio
    e_oswald            : f32, // Oswald efficiency factor
    Cl_alpha_per_rad    : f32, // lift coefficient per radian of angle of attack
    Cm_alpha_per_rad    : f32, // pitch coefficient per radian of angle of attack
    stall_deg           : f32, // stall angle of attack in degrees
    alpha_deg           : f32, // angle of attack in degrees
    alpha0_deg          : f32, // zero lift angle of attack in degrees
    Mcrit               : f32, // critical Mach number
    wave_drag_k         : f32, // wave drag coefficient
}

SimState :: struct {
    // Air/flow
    T_K     : f32, // air temperature in kelvin
    p_Pa    : f32, // air pressure in pascals
    rho     : f32, // air density in kg/m^3
    mu_Pa_s : f32, // air dynamic viscosity in pascal-seconds
    a_ms    : f32, // speed of sound in meters per second
    Mach    : f32, // Mach number
    Re      : f64, // Reynolds number
    q_Pa    : f32, // dynamic pressure in pascals
    // Coefficients
    Cl      : f32, // lift coefficient
    Cd      : f32, // drag coefficient
    Cm      : f32, // moment coefficient
    // Forces
    L_N     : f32, // lift force in newtons
    D_N     : f32, // drag force in newtons
}

/// ---- MATH HELPERS ----
// Multiply a point (w=1) and a direction (w=0)
mul_point_rm :: proc(M: rl.Matrix, p: rl.Vector3) -> rl.Vector3 {
    return rl.Vector3{
         M[0,0]*p.x + M[0,1]*p.y + M[0,2]*p.z + M[0,3],
         M[1,0]*p.x + M[1,1]*p.y + M[1,2]*p.z + M[1,3],
         M[2,0]*p.x + M[2,1]*p.y + M[2,2]*p.z + M[2,3],
    };
}
mul_dir_rm :: proc(M: rl.Matrix, v: rl.Vector3) -> rl.Vector3 {
    return rl.Vector3{
        M[0,0]*v.x + M[0,1]*v.y + M[0,2]*v.z,
        M[1,0]*v.x + M[1,1]*v.y + M[1,2]*v.z,
        M[2,0]*v.x + M[2,1]*v.y + M[2,2]*v.z,
    };
}
transform_point :: proc(M: rl.Matrix, p: rl.Vector3) -> rl.Vector3 {
    return rl.Vector3Transform(p, M);
}
deg2rad :: proc(x: f32) -> f32 { return x * PI / 180.0 }
clamp01 :: proc(x: f32) -> f32 { return math.clamp(x, 0.0, 1.0)}
mix     :: proc(a,b,t: f32) -> f32 { return a*(1.0 - t) + b*t}


// ---------- Standard Atmosphere (0–20 km, 2-layer) ----------
isa_properties :: proc(altitude_m, dT_K: f32) -> (T_K: f32, p_Pa: f32, rho: f32) {
    h := altitude_m
    if h < 0 { h = 0 }

    if h <= 11000.0 {
        // Troposphere with lapse rate
        T := T0 - L_LAPSE*h + dT_K
        exponent := GRAVITY / (L_LAPSE * R_AIR)
        p := P0 * math.pow_f32(T / (T0 + dT_K), cast(f32)exponent)
        rho_out := p / (R_AIR * T)
        return T, p, rho_out
    } else {
        // Isothermal layer (11–20 km)
        T_trop := T0 - L_LAPSE*11000.0 + dT_K
        exponent := GRAVITY / (L_LAPSE * R_AIR)
        p_11 := P0 * math.pow_f32(T_trop / (T0 + dT_K), cast(f32)exponent)

        T := T_trop
        p := p_11 * math.exp_f32( -GRAVITY*(h - 11000.0) / (R_AIR * T) )
        rho_out := p / (R_AIR * T)
        return T, p, rho_out
    }
}

// Sutherland viscosity (air)
sutherland_mu :: proc(T_K: f32) -> f32 {
    // μ = μ_ref * (T/T_ref)^(3/2) * (T_ref + S) / (T + S)
    tr := T_K / T_REF
    return MU_REF * math.pow(tr, 1.5) * (T_REF + S_SUTH) / (T_K + S_SUTH)
}

// Speed of sound
speed_of_sound :: proc(T_K: f32) -> f32 {
    return math.sqrt(GAMMA * R_AIR * T_K)
}

// Blend laminar/turbulent flat-plate skin friction coefficient Cf
skin_friction_Cf :: proc(Re: f64) -> f32 {
    if Re <= 0.0 { return 0.0 }
    // Laminar: Cf = 1.328 / sqrt(Re)
    Cf_lam := 1.328 / math.sqrt(Re)

    // Turbulent (Prandtl–Schlichting approx): Cf = 0.074 / Re^(1/5)
    Cf_turb := 0.074 / math.pow(Re, 0.2)

    // Blend across a decade or two around transition (~3e5–3e6)
    Re1, Re2 := 3.0e5, 3.0e6
    t := clamp01( cast(f32)(math.log10_f64(Re) - math.log10_f64(Re1)) / cast(f32)(math.log10_f64(Re2) - math.log10_f64(Re1)) )

    return mix(cast(f32)Cf_lam, cast(f32)Cf_turb, t)
}

// Main solve: properties, numbers, coefficients, forces
solve_aero :: proc(sim: SimInputs) -> SimState {
    st: SimState

    // Atmosphere + viscosity
    T, p, rho := isa_properties(sim.altitude_m, sim.delta_t_k)
    mu := sutherland_mu(T)
    a  := speed_of_sound(T)

    st.T_K   = T
    st.p_Pa  = p
    st.rho   = rho
    st.mu_Pa_s = mu
    st.a_ms  = a

    // Flow numbers
    V := sim.velocity_ms
    st.Mach = V / a
    st.Re   = (cast(f64)rho * cast(f64)V * cast(f64)sim.char_len_m) / cast(f64)mu
    st.q_Pa = 0.5 * rho * V * V

    // Lift coefficient with stall clamp
    alpha     := deg2rad(sim.alpha_deg)
    alpha0    := deg2rad(sim.alpha0_deg)
    alpha_st  := math.max(1e-4, deg2rad(sim.stall_deg)) // avoid div/0
    Cl_lin    := sim.Cl_alpha_per_rad * (alpha - alpha0)

    // Simple hard clamp at ~90% of linear stall lift
    Cl_max := 0.9 * sim.Cl_alpha_per_rad * alpha_st
    st.Cl  = math.clamp(Cl_lin, -Cl_max, Cl_max)

    // Induced drag (guard AR/e)
    Cdi: f32 = 0.0
    if sim.ar > 0.0 && sim.e_oswald > 0.0 {
        Cdi = (st.Cl*st.Cl) / (PI * sim.ar * sim.e_oswald)
    }

    // Skin-friction increment via wetted-area ratio
    Cf := skin_friction_Cf(st.Re)
    Cd_f := Cf * math.max(0.0, sim.S_wet_over_Sref)

    // Optional compressibility/wave drag (very rough).
    Cd_wave: f32 = 0.0
    Mcrit := sim.Mcrit
    if Mcrit <= 0.0 { Mcrit = 0.80 } // default if not supplied
    if sim.wave_drag_k > 0.0 && st.Mach > Mcrit {
        dm := st.Mach - Mcrit
        Cd_wave = sim.wave_drag_k * dm*dm
    }

    st.Cd = sim.cd0 + Cd_f + Cdi + Cd_wave

    // Pitching moment (about ref point): linear model
    st.Cm = sim.Cm_alpha_per_rad * (alpha - alpha0)

    // Forces
    qS := st.q_Pa * sim.S_ref_m2
    st.L_N = qS * st.Cl
    st.D_N = qS * st.Cd

    return st
}
