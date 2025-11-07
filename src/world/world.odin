package world

import "core:strings"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

// ---------- Data ----------

ModelPart :: struct {
    mesh_index     : i32, // index into owner.meshes
    material_index : i32, // index into owner.materials
}

EntityParts :: struct {
    id        : i32,
    name      : string,
    owner     : rl.Model,          // GPU owner (UnloadModel when removing)
    parts     : [dynamic]ModelPart,
    has_model : bool,

    // transform knobs
    offset    : rl.Vector3,
    yaw_deg   : f32,
    scale     : f32,
}

World :: struct {
    entities : [dynamic]EntityParts,
}



// ---------- Lifecycle ----------
make_world :: proc() -> World {
    return World{}
}

clear_world :: proc(w: ^World) {
    for i in 0..<len(w^.entities) {
        if w^.entities[i].has_model {
            rl.UnloadModel(w^.entities[i].owner)
            w^.entities[i].has_model = false
        }
    }
    w^.entities = nil
}

// ---------- Bounds / focus helpers ----------
get_entity_bounds :: proc(e: ^EntityParts) -> (bmin, bmax: rl.Vector3, ok: bool) {
    if !e^.has_model || e^.owner.meshCount == 0 do return {}, {}, false

    bb   := rl.GetMeshBoundingBox(e^.owner.meshes[0])
    minv := bb.min
    maxv := bb.max

    for i in 1..<e^.owner.meshCount {
        bb = rl.GetMeshBoundingBox(e^.owner.meshes[i])
        if bb.min.x < minv.x do minv.x = bb.min.x
        if bb.min.y < minv.y do minv.y = bb.min.y
        if bb.min.z < minv.z do minv.z = bb.min.z
        if bb.max.x > maxv.x do maxv.x = bb.max.x
        if bb.max.y > maxv.y do maxv.y = bb.max.y
        if bb.max.z > maxv.z do maxv.z = bb.max.z
    }

    s := e^.scale
    minv = rl.Vector3{ minv.x*s + e^.offset.x, minv.y*s + e^.offset.y, minv.z*s + e^.offset.z }
    maxv = rl.Vector3{ maxv.x*s + e^.offset.x, maxv.y*s + e^.offset.y, maxv.z*s + e^.offset.z }
    return minv, maxv, true
}

// ---------- Loading / removal ----------
add_parts_from_file :: proc(w: ^World, path: string, name := "Model") -> int {
    cpath := strings.clone_to_cstring(path)
    mdl   := rl.LoadModel(cpath)
    if mdl.meshCount <= 0 do return -1

    // ---- create the entity -------------------------------------------------
    e := EntityParts{
        id        = cast(i32)len(w^.entities),
        name      = strings.clone(name),
        owner     = mdl,
        has_model = true,
        offset    = rl.Vector3{0,0,0},
        yaw_deg   = 0,
        scale     = 1,
    }

    // ---- fill parts --------------------------------------------------------
    e.parts = make([dynamic]ModelPart, 0, mdl.meshCount)
    for i in 0..<mdl.meshCount {
        append(&e.parts, ModelPart{
            mesh_index     = i,
            material_index = mdl.meshMaterial[i],
        })
    }

    for i in 0..<mdl.meshCount {
        rl.GenMeshTangents(&e.owner.meshes[i])
        rl.UploadMesh(&e.owner.meshes[i], false)
    }

    // ---- store entity -------------------------------------------------------
    append(&w^.entities, e)
    return len(w^.entities) - 1
}

remove_entity :: proc(w: ^World, id: int) {
    ents := &w^.entities
    n := len(ents^)
    if id < 0 || id >= n do return

    // Release resources for the entity being removed
    if ents^[id].has_model {
        rl.UnloadModel(ents^[id].owner)
        ents^[id].has_model = false
    }

    // Move last into the gap (unless already last)
    last := n - 1
    if id != last {
        ents^[id] = ents^[last]
    }

    // Shrink by one
    _ = pop(ents)
}


// ---------- Drawing ----------
draw_entity_parts :: proc(e: ^EntityParts) {
    if !e^.has_model do return

    rlgl.DisableBackfaceCulling()
    rlgl.PushMatrix()
    rlgl.Translatef(e^.offset.x, e^.offset.y, e^.offset.z)
    rlgl.Rotatef(e^.yaw_deg, 0, 1, 0)
    rlgl.Scalef(e^.scale, e^.scale, e^.scale)

    for p in e^.parts {
        m  := e^.owner.meshes[p.mesh_index]
        mt := e^.owner.materials[p.material_index]
        rl.DrawMesh(m, mt, rl.Matrix(1))
    }
    rlgl.PopMatrix()
    rlgl.EnableBackfaceCulling()
}

draw :: proc(w: ^World) {
    for i in 0..<len(w^.entities) {
        draw_entity_parts(&w^.entities[i])
    }
}

fix_winding :: proc(m: ^rl.Model) {
    for i in 0..<m.meshCount {
        mesh := &m.meshes[i]
        // assume triangles
        for t in 0..<int(mesh.triangleCount) {
            i0 := mesh.indices[3*t+0]
            i1 := mesh.indices[3*t+1]
            i2 := mesh.indices[3*t+2]
            // swap i1/i2 to invert winding
            mesh.indices[3*t+1] = i2
            mesh.indices[3*t+2] = i1
        }
        rl.UploadMesh(mesh, false) // re-upload to GPU
    }
}
