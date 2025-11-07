package wingen

import "core:mem"
import rl "vendor:raylib"
import "core:math"

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

Tri :: struct {
    v0,v1,v2: rl.Vector3
}

AeroProps :: struct {
    T:    f32,   // K
    p:    f32,   // Pa
    rho:  f32,   // kg/m^3
    a:    f32,   // m/s (speed of sound)
    mu:   f32,   // Pa*s (dynamic viscosity)
    q:    f32,   // Pa (dynamic pressure = 0.5*rho*V^2)
    M:    f32,   // Mach
    Re:   f32,   // Reynolds using characteristic length L
}

AeroInputs :: struct {
    // Geometry/scale
    S_ref: f32,      // m^2 reference area
    L_ref: f32,      // m   characteristic length (e.g., chord, diameter)
    // Polar params (you can tune from literature/tests)
    Cd0:    f32,
    AR:     f32,     // aspect ratio (if wing-like), else use k directly
    e:      f32,     // Oswald efficiency
    Cl_alpha: f32,   // per rad (≈ 2π for thin airfoil)
    Cm_alpha: f32,   // per rad (pitching about y/right axis)
    stall_deg: f32,  // soft clip angle in degrees
}

AeroOutputs :: struct {
    props:  AeroProps,
    alpha_deg: f32,
    beta_deg:  f32,
    A_frontal: f32,
    cp_world:  rl.Vector3,
    Cl, Cd, Cm: f32,
    Lift, Drag: f32, // N  (magnitudes along canonical Lift/Drag dirs)
    Pitch_Moment: f32, // N·m about body-y (approx)
}

// Simple polar: Cd = Cd0 + k Cl^2
induced_k :: proc(AR, e: f32) -> f32 {
    if AR <= 0 || e <= 0 { return 0.07 } // fallback
    return 1.0 / (math.PI * AR * e)
}

// ISA troposphere (0..11 km), with temperature offset dT_K
isa_troposphere :: proc(alt_m: f32, dT_K: f32) -> (T: f32, p: f32, rho: f32) {
    // constants
    T0  : f32 = 288.15
    p0  : f32 = 101325.0
    L   : f32 = 0.0065     // K/m
    g   : f32 = 9.80665
    R   : f32 = 287.05

    h := alt_m
    if h < 0 do h = 0
    if h > 11000 do h = 11000

    T = T0 - L*h + dT_K
    if T < 150.0 do T = 150.0
    exp := g/(R*L)
    p = p0 * math.pow(T/(T0 + dT_K), exp)
    rho = p/(R*T)
    return
}

// Sutherland's law for air
sutherland_mu :: proc(T_K: f32) -> f32 {
    // reference at 273.15 K: mu0 ≈ 1.716e-5 Pa*s, S ≈ 110.4 K
    mu0 : f32 = 1.716e-5
    T0  : f32 = 273.15
    S   : f32 = 110.4
    return mu0 * math.pow(T_K/T0, 1.5) * (T0 + S) / (T_K + S)
}

flow_props :: proc(alt_m, V, dT_K, char_len_m: f32) -> AeroProps {
    T, p, rho := isa_troposphere(alt_m, dT_K)
    a  := math.sqrt(1.4 * 287.05 * T)  // gamma=1.4
    mu := sutherland_mu(T)
    q  := 0.5 * rho * V * V
    M  := V / a
    Re := (rho * V * math.max(char_len_m, 1e-6)) / math.max(mu, 1e-12)
    return AeroProps{T, p, rho, a, mu, q, M, Re}
}

get_mesh_tris :: proc(m: ^rl.Mesh) -> []Tri {
    vcount := m.vertexCount
    tcount := m.triangleCount

    // vertices are xyz float triplets
    vs := mem.slice_ptr(m.vertices, cast(int)vcount*3)

    tris := make([]Tri, cast(int)tcount)
    if m.indices != nil {
        // 16-bit indices
        idx := mem.slice_ptr(m.indices, cast(int)tcount*3) // []u16
        for i in 0..<tcount {
            a := cast(int)idx[i*3+0]
            b := cast(int)idx[i*3+1]
            c := cast(int)idx[i*3+2]
            v0 := rl.Vector3{vs[a*3+0], vs[a*3+1], vs[a*3+2]}
            v1 := rl.Vector3{vs[b*3+0], vs[b*3+1], vs[b*3+2]}
            v2 := rl.Vector3{vs[c*3+0], vs[c*3+1], vs[c*3+2]}
            tris[i] = Tri{v0, v1, v2}
        }
        return tris
    }

    // assume vertices already form sequential triangles
    for i in 0..<tcount {
        base := cast(int)i*9
        v0 := rl.Vector3{vs[base+0], vs[base+1], vs[base+2]}
        v1 := rl.Vector3{vs[base+3], vs[base+4], vs[base+5]}
        v2 := rl.Vector3{vs[base+6], vs[base+7], vs[base+8]}
        tris[i] = Tri{v0, v1, v2}
    }
    return tris
}

wind_world_from_yaw_pitch :: proc(speed, yaw_deg, pitch_deg: f32) -> rl.Vector3 {
    ψ := yaw_deg   * math.PI/180
    θ := pitch_deg * math.PI/180
    cx := math.cos(θ); sx := math.sin(θ)
    cy := math.cos(ψ); sy := math.sin(ψ)
    // unit dir the air is COMING FROM
    dir := rl.Vector3{ cx*cy, sx, cx*sy }
    dir = rl.Vector3Normalize(dir)
    return dir * speed
}

// flow_world is the air velocity relative to the body (m/s) IN WORLD.
// x_axis/y_axis/z_axis are unit body axes IN WORLD.
angles_and_dirs :: proc(flow_world, x_axis, y_axis, z_axis: rl.Vector3) -> (alpha, beta: f32,
    flow_dir, drag_dir, lift_dir, side_dir: rl.Vector3,
    Vx, Vy, Vz: f32)
{
    // Incoming unit flow direction
    flow_dir = rl.Vector3Normalize(-(flow_world))

    // Components of flow along body axes
    Vx = rl.Vector3DotProduct(flow_dir, x_axis) // along chord/forward
    Vy = rl.Vector3DotProduct(flow_dir, y_axis) // lateral (sideslip)
    Vz = rl.Vector3DotProduct(flow_dir, z_axis) // up

    // Aerodynamic angles (body axes convention)
    // alpha = angle in X–Z plane; beta = sideslip
    alpha = math.atan2(Vz, Vx);
    beta  = math.atan2(Vy, math.sqrt(Vx*Vx + Vz*Vz))

    // Canonical directions:
    drag_dir = flow_dir;

    // Lift is the flow-perpendicular direction in the (x,z) plane:
    //   lift_dir ∝  Vx*z_axis - Vz*x_axis
    lift_dir = rl.Vector3Normalize((z_axis * Vx) + (x_axis * -Vz))

    // Side force closes the RH triad:
    side_dir = rl.Vector3Normalize( rl.Vector3CrossProduct(drag_dir, lift_dir) )
    return
}


// returns triangle area (units^2), unit normal (follows v0→v1→v2 winding, RH rule), and centroid;
// for degenerate triangles area=0 and n=(0,0,0), all values in the same space/units as inputs.
tri_area_normal :: proc(t: Tri) -> (area: f32, n: rl.Vector3, centroid: rl.Vector3) {
    e1 := (t.v1 - t.v0)
    e2 := (t.v2 - t.v1)
    cr := rl.Vector3CrossProduct(e1, e2)

    area = 0.5 * rl.Vector3Length(cr)

    if area > 0 {
        // unit normal
        n = (cr * (1.0/(2.0*area)))
    } else {
        n = rl.Vector3{0, 0, 0}
    }

    sum := (t.v0 + (t.v1 + t.v2))
    centroid = (sum * (1.0/3.0))
    return
}

// surface area of mesh
surface_area :: proc(m: ^rl.Mesh, R: rl.Quaternion, scale: rl.Vector3) -> f32 {
    tris := get_mesh_tris(m)
    s :f32=0
    for t in tris {
        v0 := rl.Vector3RotateByQuaternion(t.v0, R) * scale
        v1 := rl.Vector3RotateByQuaternion(t.v1, R) * scale
        v2 := rl.Vector3RotateByQuaternion(t.v2, R) * scale
        area, _, _ := tri_area_normal(Tri{v0, v1, v2})
        s += area
    }
    return s
}

make_trs_rm :: proc(pos: rl.Vector3, rot: rl.Quaternion, scl: rl.Vector3) -> rl.Matrix {
    // rotation 3x3 from quaternion
    x2:=2*rot.x;  y2:=2*rot.y;  z2:=2*rot.z;
    xx:=rot.x*x2; yy:=rot.y*y2; zz:=rot.z*z2;
    xy:=rot.x*y2; xz:=rot.x*z2; yz:=rot.y*z2;
    wx:=rot.w*x2; wy:=rot.w*y2; wz:=rot.w*z2;

    R : rl.Matrix;
    R[0,0] = 1 - (yy + zz);  R[0,1] =     (xy - wz);  R[0,2] =     (xz + wy);  R[0,3] = pos.x;
    R[1,0] =     (xy + wz);  R[1,1] = 1 - (xx + zz);  R[1,2] =     (yz - wx);  R[1,3] = pos.y;
    R[2,0] =     (xz - wy);  R[2,1] =     (yz + wx);  R[2,2] = 1 - (xx + yy);  R[2,3] = pos.z;
    R[3,0] = 0;              R[3,1] = 0;              R[3,2] = 0;              R[3,3] = 1;

    // bake non-uniform scale into the 3x3
    R[0,0] *= scl.x; R[0,1] *= scl.y; R[0,2] *= scl.z;
    R[1,0] *= scl.x; R[1,1] *= scl.y; R[1,2] *= scl.z;
    R[2,0] *= scl.x; R[2,1] *= scl.y; R[2,2] *= scl.z;
    return R;
}

// Projected area and CP **in world space**
projected_area_and_pressure_center_world :: proc(
    m: ^rl.Mesh, M_model_to_world: rl.Matrix, vhat_world: rl.Vector3
) -> (A: f32, pc_world: rl.Vector3) {
    tris := get_mesh_tris(m)
    A = 0; pc_world = rl.Vector3{0,0,0}
    vhat := rl.Vector3Normalize(vhat_world)
    minus_v := -(vhat)

    sumw: f32 = 0
    for t in tris {
        // Transform vertices to world
        p0 := mul_point_rm(M_model_to_world, t.v0)
        p1 := mul_point_rm(M_model_to_world, t.v1)
        p2 := mul_point_rm(M_model_to_world, t.v2)

        e1 := p1 - p0
        e2 := p2 - p0
        cr := rl.Vector3CrossProduct(e1, e2)
        a  := 0.5 * rl.Vector3Length(cr)
        if a <= 0 do continue

        n := rl.Vector3Normalize(cr); // triangle world normal (facing = RH winding)
        cosθ := rl.Vector3DotProduct(n, minus_v)
        if cosθ <= 0 do continue     // backface to the flow → contributes 0

        w := a * cosθ                // projected area contribution
        A += w
        c := (p0 + (p1 + p2)) * (1.0/3.0)
        pc_world = pc_world + (c * w)
        sumw += w
    }
    if sumw > 0 do pc_world = pc_world * (1.0/sumw)
    return
}

// Closed-mesh volume. Uses signed tetra volumes w.r.t origin; for decent results, recenter vertices around model origin.
approx_mesh_vol :: proc(m: ^rl.Mesh, R: rl.Quaternion, scale: rl.Vector3) -> f32 {
    tris := get_mesh_tris(m)
    V := f32(0)
    for t in tris {
        v0 := (rl.Vector3RotateByQuaternion(t.v0, R) * scale)
        v1 := (rl.Vector3RotateByQuaternion(t.v1, R) * scale)
        v2 := (rl.Vector3RotateByQuaternion(t.v2, R) * scale)
        // volume of tetra (0,v0,v1,v2)
        V += rl.Vector3DotProduct(v0, rl.Vector3CrossProduct(v1, v2)) / 6.0
    }
    return math.abs(V) // magnitude; sign depends on winding
}

// Body axes (world) from row-major transform
axes_from_row_major :: proc(M: rl.Matrix) -> (x,y,z: rl.Vector3) {
    x = mul_dir_rm(M, rl.Vector3{1,0,0}); x = rl.Vector3Normalize(x);
    y = mul_dir_rm(M, rl.Vector3{0,1,0}); y = rl.Vector3Normalize(y);
    z = mul_dir_rm(M, rl.Vector3{0,0,1}); z = rl.Vector3Normalize(z);
    return;
}


// Soft-limit alpha to stall, preserving sign
soft_clip_alpha :: proc(alpha: f32, stall_rad: f32) -> f32 {
    a := alpha
    s := stall_rad
    if s <= 0 { return a }
    // smoothstep-ish clamp
    if math.abs(a) <= s { return a }
    return s * math.tanh(a/s)
}

compute_aero_from_inputs :: proc(
    flow: AeroProps,
    alpha_rad, beta_rad: f32,
    S_ref: f32,
    inp: ^AeroInputs,
    cp_lever_world: rl.Vector3, // lever arm for pitching moment
    lift_dir_world, drag_dir_world: rl.Vector3,
) -> AeroOutputs {
    a_eff := soft_clip_alpha(alpha_rad, math.to_radians_f32(inp.stall_deg))
    Cl := inp.Cl_alpha * a_eff
    k  := induced_k(inp.AR, inp.e)
    Cd := inp.Cd0 + k * Cl*Cl
    Cm := inp.Cm_alpha * a_eff

    qS := flow.q * S_ref
    L  := qS * Cl
    D  := qS * Cd

    // lift ⟂ flow, drag = -flow_hat)
    Lift_v := (rl.Vector3Normalize(lift_dir_world) * L)
    Drag_v := (rl.Vector3Normalize(drag_dir_world) * D)

    // Approx pitch moment about CP lever (body-y). Just report scalar here.
    Pitch_M := Cm * qS * inp.L_ref

    return AeroOutputs{
        props = flow,
        alpha_deg = math.to_degrees_f32(alpha_rad),
        beta_deg  = math.to_degrees_f32(beta_rad),
        Cl=Cl, Cd=Cd, Cm=Cm,
        Lift=L, Drag=D,
        Pitch_Moment=Pitch_M,
    }
}
