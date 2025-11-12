#+feature dynamic-literals

package helpers

import "core:bytes"
import "core:c"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:path/filepath"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

// ---------- lookup tables (built on first use) ----------
MOUSE_TABLE: map[string]rl.MouseButton   // string -> mouse button
KEY_TABLE:   map[string]rl.KeyboardKey   // string -> key code

// ---------- input binding data ----------

Key_Bind :: struct {
    key: rl.KeyboardKey, // the raylib key code
    action: string,      // sanitized action id (e.g. "cam_move_forward")
}

Mouse_Bind :: struct {
    button: rl.MouseButton, // the raylib mouse button
    action: string,         // sanitized action id
}

// quick reverse lookups for building UI, not strictly required here
Input_Bindings :: struct {
    by_action : map[string]rl.KeyboardKey,
    by_key    : map[rl.KeyboardKey]string,
}

// ---------- app config ----------

Fullscreen_Type :: enum { EXCLUSIVE, WINDOWED, BORDERLESS}

// all user-facing settings loaded/saved to INI
App :: struct {
    title: string,
    width: i32,
    height: i32,
    fullscreen: Fullscreen_Type,
    vsync: bool,
    fps_limit: i32,
    master_volume: f32,
    keybinds: [dynamic]Key_Bind,
    mousebinds: [dynamic]Mouse_Bind,
    mouse_sensitivity: f32,
}

// default values used on first launch or as merge base for INI
default_app :: proc() -> App {
    kb := make([dynamic]Key_Bind, 0, 12)
    mb := make([dynamic]Mouse_Bind, 0, 4)

    append(&kb, Key_Bind{.W, "cam_move_forward"})
    append(&kb, Key_Bind{.S, "cam_move_backward"})
    append(&kb, Key_Bind{.A, "cam_move_left"})
    append(&kb, Key_Bind{.D, "cam_move_right"})
    append(&kb, Key_Bind{.Q, "cam_move_down"})
    append(&kb, Key_Bind{.E, "cam_move_up"})
    append(&kb, Key_Bind{.LEFT_SHIFT,   "cam_speed"})
    append(&kb, Key_Bind{.LEFT_CONTROL, "cam_move_enable"})
    append(&kb, Key_Bind{.G, "render_wireframe"})
    append(&kb, Key_Bind{.N, "render_normals"})
    append(&kb, Key_Bind{.F, "cam_focus"})
    append(&mb, Mouse_Bind{.RIGHT, "cam_look"}) // orbit/pan/dolly

    return App{
        title = "Wingen",
        width = 1280,
        height = 720,
        fullscreen = .WINDOWED,
        vsync = true,
        master_volume = 0.8,
        keybinds = kb,
        mousebinds = mb,
    }
}

// ---------- logging ----------

LogLevel :: enum { INFO, WARN, ERROR, FATAL, PANIC }

// minimal console logger; keep zero-alloc friendly
Log :: proc(message: string, level: LogLevel = .INFO){
    switch level {
        case .INFO:  fmt.printf("INFO: %s\n", message)
        case .WARN:  fmt.printf("WARN: %s\n", message)
        case .ERROR: fmt.printf("ERROR: %s\n", message)
        case .FATAL: fmt.printf("FATAL: %s\n", message)
        case .PANIC: fmt.printf("PANIC: %s\n", message)
    }
}

// ---------- config file paths ----------

config_paths :: proc() -> (dir: string, file: string) {
    // "%LOCALAPPDATA%/Wingen/settings.ini" (or ./Wingen/settings.ini)
    lad := os.get_env("LOCALAPPDATA")
    if lad != "" {
        dir = filepath.join({lad, "Wingen"}, context.allocator)
    } else {
        dir = "Wingen"
    }
    file = filepath.join({dir, "settings.ini"}, context.allocator)
    return
}

ensure_dir_exists :: proc(dir: string) {
    // create directory if missing (no-op if present)
    if !os.exists(dir) {
        Log("Creating Config Directory", .WARN)
        os.make_directory(dir)
    }
}

file_exists :: proc(path: string) -> bool {
    // thin wrapper with trace; returns true if path exists
    if (os.exists(path)) {
        Log("File Exists", .INFO)
        return true
    } else {
        Log("File does not exist", .ERROR)
        return false
    }
}

// ---------- tiny file I/O helpers ----------

load_text_file :: proc(path: string) -> string {
    // read whole file into a freshly allocated string
    Log(fmt.tprintf("Loading file %s", path), .INFO)
    bytes, ok := os.read_entire_file(path)
    if !ok { return "" }
    defer delete(bytes)
    return string(bytes)
}

save_text_file :: proc(path: string, text: string) -> bool {
    // write whole string to disk
    Log(fmt.tprintf("Saving file %s", path), .INFO)
    bytes := transmute([]u8) text
    return os.write_entire_file(path, bytes)
}

// ---------- INI parsing / merge ----------

parse_ini_into_app :: proc(app: ^App, src: string) {
    // merges INI contents into pre-seeded defaults
    section := "window"
    Log("Parsing INI file", .INFO)

    for line in strings.split_lines(src) {
        l := strip_comments(strings.trim_space(line))
        if l == "" { continue }

        // section header: [Section]
        if l[0] == '[' && l[len(l)-1] == ']' {
            Log(fmt.tprintf("Section: %s", strings.to_lower(strings.trim_space(l[1:len(l)-1]))), .INFO)
            section = strings.to_lower(strings.trim_space(l[1:len(l)-1]))
            continue
        }

        // key=value
        key, val := kv(l)
        key_l := strings.to_lower(key)

        when true {
            switch section{
                case "window":
                    Log("Parsing window section")
                    switch key_l {
                    case "title":
                        app.title = strings.clone(val)
                        Log(fmt.tprintf("%s", app.title))
                    case "width":
                        Log("Parsing Window Size")
                        if v, ok := parse_i32(val); ok { app.width = v }
                    case "height":
                        if v, ok := parse_i32(val); ok { app.height = v }
                    case "fullscreen":
                        Log("Parsing fullscreen setting")
                        if v, ok := fullscreen_from_string(val); ok { app.fullscreen = v }
                    case "vsync":
                        if v, ok := parse_bool(val); ok { app.vsync = v }
                    case "fps_limit":
                        if v, ok := parse_i32(val); ok { app.fps_limit = max(0, v) }
                    }
                case "audio":
                    Log("Parsing Audio Settings")
                    if key_l == "master_volume" {
                        if v, ok := parse_f32(val); ok { app.master_volume = clamp_f32(v, 0, 1) }
                    }
                case "input":
                    Log("Parsing Input Settings")
                    if key_l == "mouse_sensitivity" {
                        if v, ok := parse_f32(val); ok { app.mouse_sensitivity = max(0.01, v) }
                    }
                case "keybinds":
                    // keybinds: action = KEY_NAME / numeric code
                    code, ok := key_from_string(val)
                    if ok {
                        action := app_action_sanitize(key)
                        if action != "" { upsert_key_binding(&app.keybinds, action, code) }
                    }
                case "mousebinds":
                    // mousebinds: action = LEFT/RIGHT/MIDDLE/SIDE/EXTRA...
                    code, ok := mouse_from_string(val)
                    if ok {
                        action := app_action_sanitize(key)
                        if action != "" { upsert_mouse_binding(&app.mousebinds, action, code) }
                    }
                }
        }
    }
}

load_settings :: proc(app: ^App) {
    // seed defaults, then overlay INI if present (creates file if missing)
    Log("Loading Settings")
    dir, file := config_paths()
    ensure_dir_exists(dir)

    app^ = default_app() // start from defaults

    if file_exists(file) {
        text := load_text_file(file)
        parse_ini_into_app(app, text)
    } else {
        _ = save_settings(app)
    }
}

save_settings :: proc(app: ^App) -> bool {
    // write current settings to INI (stable, human-editable)
    Log("Saving Settings")
    dir, file := config_paths()
    ensure_dir_exists(dir)

    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    strings.write_string(&b, "; Wingen settings\n")
    strings.write_string(&b, "; Auto-generated if missing\n\n")

    strings.write_string(&b, "[Window]\n")
    strings.write_string(&b, fmt.tprintf("width=%v\n",   app.width))
    strings.write_string(&b, fmt.tprintf("height=%v\n",  app.height))
    strings.write_string(&b, fmt.tprintf("fullscreen=%s\n", fullscreen_to_string(app.fullscreen)))
    strings.write_string(&b, fmt.tprintf("vsync=%v\n\n", app.vsync))

    strings.write_string(&b, "[Audio]\n")
    strings.write_string(&b, fmt.tprintf("master_volume=%v\n\n", app.master_volume))

    strings.write_string(&b, "[KeyBinds]\n")
    for kb in app.keybinds {
        act := app_action_sanitize(kb.action)
        if act == "" { continue }
        strings.write_string(&b, fmt.tprintf("%s=%s\n", act, key_to_string(kb.key)))
    }

    strings.write_string(&b, "\n[MouseBinds]\n")
    for mb in app.mousebinds {
        act := app_action_sanitize(mb.action)
        if act == "" { continue }
        strings.write_string(&b, fmt.tprintf("%s=%s\n", act, mouse_to_string(mb.button)))
    }

    out := strings.to_string(b)
    return save_text_file(file, out)
}

// ---------- tiny INI helpers ----------

strip_comments :: proc(s: string) -> string {
    // strip ';' or '#' and trim trailing space
    semi := strings.index_byte(s, ';')
    hash := strings.index_byte(s, '#')
    cut := -1
    if semi >= 0 { cut = semi }
    if hash >= 0 && (cut < 0 || hash < cut) { cut = hash }
    if cut >= 0 { return strings.trim_space(s[:cut]) }
    return s
}

kv :: proc(s: string) -> (key: string, val: string) {
    // split once on '=' and trim both sides
    i := strings.index_byte(s, '=')
    if i < 0 {
        return strings.trim_space(s), ""
    }
    key = strings.trim_space(s[:i])
    val = strings.trim_space(s[i+1:])
    return
}

// ---------- parsing primitives ----------

fullscreen_from_string :: proc(s: string) -> (Fullscreen_Type, bool) {
    // tolerant accepts: "exclusive", "fullscreen", "borderless", etc.
    t := strings.to_lower(strings.trim_space(s))
    switch t {
    case "exclusive", "true", "fullscreen": return .EXCLUSIVE, true
    case "windowed", "false", "window":     return .WINDOWED,  true
    case "borderless", "fake_fullscreen":   return .BORDERLESS,true
    }
    return .WINDOWED, false
}
fullscreen_to_string :: proc(f: Fullscreen_Type) -> string {
    switch f {
    case .EXCLUSIVE:  return "EXCLUSIVE"
    case .WINDOWED:   return "WINDOWED"
    case .BORDERLESS: return "BORDERLESS"
    }
    return "WINDOWED"
}

parse_bool :: proc(s: string) -> (bool, bool) {
    // returns (value, ok)
    t := strings.to_lower(s)
    if t == "true" || t == "1" || t == "yes" || t == "on"  { return true,  true }
    if t == "false"|| t == "0" || t == "no"  || t == "off" { return false, true }
    return false, false
}

parse_i32 :: proc(s: string) -> (i32, bool) {
    if v, ok := strconv.parse_i64(s); ok {
        return i32(v), true
    }
    return 0, false
}

parse_f32 :: proc(s: string) -> (f32, bool) {
    if v, ok := strconv.parse_f64(s); ok {
        return f32(v), true
    }
    return 0.0, false
}

clamp_f32 :: proc(x, lo, hi: f32) -> f32 {
    // saturate x to [lo, hi]
    if x < lo { return lo }
    if x > hi { return hi }
    return x
}

// ---------- string <-> enum for keys/buttons ----------

key_from_string :: proc(s: string) -> (rl.KeyboardKey, bool) {
    // accepts symbolic names ("A", "LEFT_SHIFT", "F5") or numeric codes
    ensure_key_table()

    u := strings.to_upper(strings.trim_space(s))

    if code_i64, ok := strconv.parse_i64(u); ok {
        return rl.KeyboardKey(i32(code_i64)), true
    }
    if strings.has_prefix(u, "KEY_") {
        u = u[4:]
    }

    // single letter/digit shorthands
    if len(u) == 1 {
        c := u[0]
        if c >= 'A' && c <= 'Z' {
            base := i32(rl.KeyboardKey.A)
            return rl.KeyboardKey(base + i32(c - 'A')), true
        }
        if c >= '0' && c <= '9' {
            base := i32(rl.KeyboardKey.ZERO)
            return rl.KeyboardKey(base + i32(c - '0')), true
        }
    }

    if k, ok := KEY_TABLE[u]; ok {
        return k, true
    }

    // F1..F12
    if strings.has_prefix(u, "F") && len(u) <= 3 {
        if n_i64, ok := strconv.parse_i64(u[1:]); ok {
            n := i32(n_i64)
            if n >= 1 && n <= 12 {
                base := i32(rl.KeyboardKey.F1)
                return rl.KeyboardKey(base + (n - 1)), true
            }
        }
    }
    return rl.KeyboardKey(0), false
}

key_to_string :: proc(k: rl.KeyboardKey) -> string {
    // produce stable, human-readable names for INI writes
    ensure_key_table()

    for name, code in KEY_TABLE {
        if code == k { return name }
    }
    if k >= rl.KeyboardKey.A && k <= rl.KeyboardKey.Z {
        return fmt.tprintf("%c", u8(i32('A') + (i32(k) - i32(rl.KeyboardKey.A))))
    }
    if k >= rl.KeyboardKey.ZERO && k <= rl.KeyboardKey.NINE {
        return fmt.tprintf("%v", i32(k) - i32(rl.KeyboardKey.ZERO))
    }
    if k >= rl.KeyboardKey.F1 && k <= rl.KeyboardKey.F12 {
        return fmt.tprintf("F%v", 1 + (i32(k) - i32(rl.KeyboardKey.F1)))
    }
    return fmt.tprintf("%v", i32(k))
}

mouse_from_string :: proc(s: string) -> (rl.MouseButton, bool) {
    // accepts LEFT/RIGHT/MIDDLE/SIDE/EXTRA/..., aliases (MB1/BUTTON1), or numbers
    ensure_mouse_table()

    u := strings.to_upper(strings.trim_space(s))
    if u == "" { return rl.MouseButton(0), false }

    if strings.has_prefix(u, "MOUSE_") {
        u = u[6:]
    }

    if code_i64, ok := strconv.parse_i64(u); ok {
        return rl.MouseButton(i32(code_i64)), true
    }

    if len(u) == 2 && u[0] == 'M' && (u[1] >= '1' && u[1] <= '5') {
        switch u[1] {
        case '1': return .LEFT,   true
        case '2': return .RIGHT,  true
        case '3': return .MIDDLE, true
        case '4': return .SIDE,   true
        case '5': return .EXTRA,  true
        }
    }

    if b, ok := MOUSE_TABLE[u]; ok {
        return b, true
    }

    return rl.MouseButton(0), false
}

mouse_to_string :: proc(m: rl.MouseButton) -> string {
    // stable names for writing; fallback to numeric
    ensure_mouse_table()
    switch m {
    case .LEFT:    return "LEFT"
    case .RIGHT:   return "RIGHT"
    case .MIDDLE:  return "MIDDLE"
    case .SIDE:    return "SIDE"
    case .EXTRA:   return "EXTRA"
    case .FORWARD: return "FORWARD"
    case .BACK:    return "BACK"
    }
    return fmt.tprintf("%v", i32(m))
}

// ---------- action lookups and polling ----------

find_key_for_action :: proc(binds: [dynamic]Key_Bind, action: string) -> (rl.KeyboardKey, bool) {
    for b in binds {
        if strings.equal_fold(b.action, action) {
            return b.key, true
        }
    }
    return rl.KeyboardKey(0), false
}

find_mouse_for_action :: proc(binds: [dynamic]Mouse_Bind, action: string) -> (rl.MouseButton, bool) {
    for b in binds {
        if strings.equal_fold(b.action, action) {
            return b.button, true
        }
    }
    return rl.MouseButton(0), false
}

mouse_action_down    :: proc(binds: [dynamic]Mouse_Bind, action: string) -> bool {
    if btn, ok := find_mouse_for_action(binds, action); ok { return rl.IsMouseButtonDown(btn) }
    return false
}
mouse_action_pressed :: proc(binds: [dynamic]Mouse_Bind, action: string) -> bool {
    if btn, ok := find_mouse_for_action(binds, action); ok { return rl.IsMouseButtonPressed(btn) }
    return false
}
mouse_action_released :: proc(binds: [dynamic]Mouse_Bind, action: string) -> bool {
    if b, ok := find_mouse_for_action(binds, action); ok { return rl.IsMouseButtonReleased(b) }
    return false
}

key_action_down    :: proc(binds: [dynamic]Key_Bind, action: string) -> bool {
    if k, ok := find_key_for_action(binds, action); ok { return rl.IsKeyDown(k) }
    return false
}
key_action_pressed :: proc(binds: [dynamic]Key_Bind, action: string) -> bool {
    if k, ok := find_key_for_action(binds, action); ok { return rl.IsKeyPressed(k) }
    return false
}
key_action_released :: proc(binds: [dynamic]Key_Bind, action: string) -> bool {
    if k, ok := find_key_for_action(binds, action); ok { return rl.IsKeyReleased(k) }
    return false
}

// ---------- table builders (idempotent) ----------

ensure_mouse_table :: proc() {
    if MOUSE_TABLE != nil do return
    Log("Creating mouse table")
    MOUSE_TABLE = make(map[string]rl.MouseButton, context.allocator)

    // canonical names we WRITE
    MOUSE_TABLE["LEFT"]    = .LEFT
    MOUSE_TABLE["RIGHT"]   = .RIGHT
    MOUSE_TABLE["MIDDLE"]  = .MIDDLE
    MOUSE_TABLE["SIDE"]    = .SIDE     // button 4
    MOUSE_TABLE["EXTRA"]   = .EXTRA    // button 5
    MOUSE_TABLE["FORWARD"] = .FORWARD
    MOUSE_TABLE["BACK"]    = .BACK

    // common aliases we ACCEPT
    MOUSE_TABLE["BUTTON1"] = .LEFT
    MOUSE_TABLE["BUTTON2"] = .RIGHT
    MOUSE_TABLE["BUTTON3"] = .MIDDLE
    MOUSE_TABLE["BUTTON4"] = .SIDE
    MOUSE_TABLE["BUTTON5"] = .EXTRA

    MOUSE_TABLE["MB1"] = .LEFT
    MOUSE_TABLE["MB2"] = .RIGHT
    MOUSE_TABLE["MB3"] = .MIDDLE
    MOUSE_TABLE["MB4"] = .SIDE
    MOUSE_TABLE["MB5"] = .EXTRA
}

ensure_key_table :: proc() {
    if KEY_TABLE != nil do return
    Log("Creating key table", .INFO)
    KEY_TABLE = make(map[string]rl.KeyboardKey, context.allocator)

    // --- Common keys ---
    KEY_TABLE["SPACE"]         = .SPACE
    KEY_TABLE["TAB"]           = .TAB
    KEY_TABLE["ENTER"]         = .ENTER
    KEY_TABLE["ESC"]           = .ESCAPE
    KEY_TABLE["ESCAPE"]        = .ESCAPE

    // Modifiers
    KEY_TABLE["LSHIFT"]        = .LEFT_SHIFT
    KEY_TABLE["LEFT_SHIFT"]    = .LEFT_SHIFT
    KEY_TABLE["RSHIFT"]        = .RIGHT_SHIFT
    KEY_TABLE["LEFT_CONTROL"]  = .LEFT_CONTROL
    KEY_TABLE["RIGHT_CONTROL"] = .RIGHT_CONTROL
    KEY_TABLE["LEFT_ALT"]      = .LEFT_ALT
    KEY_TABLE["RIGHT_ALT"]     = .RIGHT_ALT
    KEY_TABLE["LEFT_SUPER"]    = .LEFT_SUPER
    KEY_TABLE["RIGHT_SUPER"]   = .RIGHT_SUPER

    // Arrows
    KEY_TABLE["UP"]            = .UP
    KEY_TABLE["DOWN"]          = .DOWN
    KEY_TABLE["LEFT"]          = .LEFT
    KEY_TABLE["RIGHT"]         = .RIGHT

    // Punctuation/examples
    KEY_TABLE["MINUS"]         = .MINUS
    KEY_TABLE["EQUAL"]         = .EQUAL
    KEY_TABLE["LEFT_BRACKET"]  = .LEFT_BRACKET
    KEY_TABLE["RIGHT_BRACKET"] = .RIGHT_BRACKET
    KEY_TABLE["BACKSLASH"]     = .BACKSLASH
    KEY_TABLE["SEMICOLON"]     = .SEMICOLON
    KEY_TABLE["APOSTROPHE"]    = .APOSTROPHE
    KEY_TABLE["GRAVE"]         = .GRAVE
    KEY_TABLE["COMMA"]         = .COMMA
    KEY_TABLE["PERIOD"]        = .PERIOD
    KEY_TABLE["SLASH"]         = .SLASH

    // Digits top row
    KEY_TABLE["0"]             = .ZERO
    KEY_TABLE["1"]             = .ONE
    KEY_TABLE["2"]             = .TWO
    KEY_TABLE["3"]             = .THREE
    KEY_TABLE["4"]             = .FOUR
    KEY_TABLE["5"]             = .FIVE
    KEY_TABLE["6"]             = .SIX
    KEY_TABLE["7"]             = .SEVEN
    KEY_TABLE["8"]             = .EIGHT
    KEY_TABLE["9"]             = .NINE

    // Keypad
    KEY_TABLE["KP_0"]          = .KP_0
    KEY_TABLE["KP_1"]          = .KP_1
    KEY_TABLE["KP_2"]          = .KP_2
    KEY_TABLE["KP_3"]          = .KP_3
    KEY_TABLE["KP_4"]          = .KP_4
    KEY_TABLE["KP_5"]          = .KP_5
    KEY_TABLE["KP_6"]          = .KP_6
    KEY_TABLE["KP_7"]          = .KP_7
    KEY_TABLE["KP_8"]          = .KP_8
    KEY_TABLE["KP_9"]          = .KP_9
    KEY_TABLE["KP_ADD"]        = .KP_ADD
    KEY_TABLE["KP_SUBTRACT"]   = .KP_SUBTRACT
    KEY_TABLE["KP_MULTIPLY"]   = .KP_MULTIPLY
    KEY_TABLE["KP_DIVIDE"]     = .KP_DIVIDE
    KEY_TABLE["KP_DECIMAL"]    = .KP_DECIMAL

    // Function keys
    for i in 1..=12 {
        KEY_TABLE[fmt.tprintf("F%v", i)] = rl.KeyboardKey(rl.KeyboardKey.F1) + rl.KeyboardKey(i-1)
    }
}

// ---------- misc helpers ----------

// sanitize action names to [a-z0-9_]
app_action_sanitize :: proc(t: string) -> string {
    s := strings.to_lower(t)
    b := strings.builder_make()
    defer strings.builder_destroy(&b)

    for ch in s {
        if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' {
            strings.write_byte(&b, u8(ch))
        } else if ch == ' ' || ch == '-' {
            strings.write_byte(&b, u8('_'))
        }
    }
    return strings.to_string(b)
}

// insert or update a key binding by action id
upsert_key_binding :: proc(binds: ^[dynamic]Key_Bind, action: string, key: rl.KeyboardKey) {
    for i in 0..<len(binds^) {
        if strings.equal_fold(binds^[i].action, action) {
            binds^[i].key = key
            return
        }
    }
    append(binds, Key_Bind{ key = key, action = action })
}

// insert or update a mouse binding by action id
upsert_mouse_binding :: proc(binds: ^[dynamic]Mouse_Bind, action: string, button: rl.MouseButton) {
    for i in 0..<len(binds^) {
        if strings.equal_fold(binds^[i].action, action) {
            binds^[i].button = button
            return
        }
    }
    append(binds, Mouse_Bind{ button = button, action = action })
}

// get file name without directories and without extension
file_stem_from_path :: proc(path: string) -> string {
    sep1 := strings.last_index(path, "/")
    sep2 := strings.last_index(path, "\\")
    start := 0
    if sep1 >= 0 do start = sep1 + 1
    if sep2 >= 0 && sep2+1 > start do start = sep2 + 1

    name := path[start:len(path)]

    // strip extension if present (only the last '.' after the last separator)
    if dot := strings.last_index(name, "."); dot >= 0 {
        name = name[:dot]
    }
    return name
}
