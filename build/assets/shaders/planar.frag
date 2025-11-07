#version 330
out vec4 finalColor;

uniform float opacity; // 0..1

void main() {
    finalColor = vec4(0.0, 0.0, 0.0, opacity);
}
