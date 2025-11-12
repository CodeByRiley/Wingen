package helpers

import rl "vendor:raylib"
import math "core:math"

v3        :: proc(x, y, z: f32) -> rl.Vector3 { return rl.Vector3{x, y, z} }
v3_add    :: proc(a, b: rl.Vector3) -> rl.Vector3 { return rl.Vector3{a.x+b.x, a.y+b.y, a.z+b.z} }
v3_sub    :: proc(a, b: rl.Vector3) -> rl.Vector3 { return rl.Vector3{a.x-b.x, a.y-b.y, a.z-b.z} }
v3_scale  :: proc(a: rl.Vector3, s: f32) -> rl.Vector3 { return rl.Vector3{a.x*s, a.y*s, a.z*s} }
v3_dot    :: proc(a, b: rl.Vector3) -> f32 { return a.x*b.x + a.y*b.y + a.z*b.z }
v3_cross  :: proc(a, b: rl.Vector3) -> rl.Vector3 {
    return rl.Vector3{ a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x }
}
v3_len    :: proc(a: rl.Vector3) -> f32 { return math.sqrt(v3_dot(a,a)) }
v3_norm   :: proc(a: rl.Vector3) -> rl.Vector3 {
    l := v3_len(a); if l <= 0.000001 { return rl.Vector3{0,0,0} }
    return v3_scale(a, 1.0/l)
}

get_vertices_v3 :: proc(mesh: ^rl.Mesh, i: int) -> rl.Vector3 {
    return rl.Vector3{
        mesh.vertices[i*3+0],
        mesh.vertices[i*3+1],
        mesh.vertices[i*3+2],
    };
}

f2u8_unorm :: proc(v: f32) -> u8 {
    vv := math.clamp(v, 0.0, 1.0)
    return cast(u8)(vv*255.0 + 0.5) // round-to-nearest
}
