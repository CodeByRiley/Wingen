#version 330

uniform mat4 mvp;
uniform mat4 matModel;

// Directional light in WORLD space (direction *toward* ground), normalized
uniform vec3 lightDirWS;

// Y of the receiver plane (0 = XZ plane at origin)
uniform float planeY;
// small push along light to avoid z-fighting (e.g. 0.002)
uniform float bias;

// Attributes expected by raylib:
in vec3 vertexPosition;

void main() {
    // model -> world
    vec4 worldPos = matModel * vec4(vertexPosition, 1.0);

    // Project along light onto plane y = planeY
    // Solve worldPos.y + t*L.y = planeY  => t = (planeY - worldPos.y) / L.y
    // Guard near-horizontal lights:
    float Ly = abs(lightDirWS.y) < 1e-5 ? 1e-5 : lightDirWS.y;
    float t  = (planeY - worldPos.y) / Ly;

    vec3 projected = worldPos.xyz + lightDirWS * t + lightDirWS * bias;

    gl_Position = mvp * vec4(projected, 1.0);
}
