#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Ported from design/first-ui-flame.html: a gas burner seen from above, a
// dark iron cap inside a ring of living fire.
uniform vec2 uCenter;
uniform float uScale;
uniform float uTime;
uniform float uAmp;
uniform float uListen;
uniform float uWarm;
uniform float uUrgent;

out vec4 fragColor;

// A hash that stays exact in 32-bit floats, so neighbouring noise cells agree
// on GPUs that reorder float maths.
float mod289(float x) { return x - floor(x * (1. / 289.)) * 289.; }

float permute(float x) { return mod289((x * 34. + 1.) * x); }

float h(vec3 p) {
  p -= floor(p * (1. / 289.)) * 289.;
  return permute(permute(permute(p.x) + p.y) + p.z) * (1. / 289.);
}

float n(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3. - 2. * f);
  return mix(
    mix(mix(h(i), h(i + vec3(1, 0, 0)), f.x),
        mix(h(i + vec3(0, 1, 0)), h(i + vec3(1, 1, 0)), f.x), f.y),
    mix(mix(h(i + vec3(0, 0, 1)), h(i + vec3(1, 0, 1)), f.x),
        mix(h(i + vec3(0, 1, 1)), h(i + vec3(1, 1, 1)), f.x), f.y),
    f.z);
}

float fbm(vec3 p) {
  float s = 0.;
  float a = .5;
  for (int i = 0; i < 5; i++) {
    s += a * n(p);
    p *= 2.03;
    a *= .5;
  }
  return s;
}

void main() {
  vec2 uv = (FlutterFragCoord().xy - uCenter) / uScale;
  uv.y = -uv.y;
  float r = length(uv);
  float a = atan(uv.y, uv.x);
  float R = .25;
  float rot = uTime * .02;
  vec2 dA = vec2(cos(a + rot), sin(a + rot));
  float d = r - R;

  vec3 cD = vec3(.02, .035, .17);
  vec3 cM = vec3(.09, .28, .85);
  vec3 cH = vec3(.62, .84, 1.);
  cD = mix(cD, vec3(.17, .07, .01), uWarm);
  cM = mix(cM, vec3(1., .48, .06), uWarm);
  cH = mix(cH, vec3(1., .78, .42), uWarm);
  cD = mix(cD, vec3(.2, .01, .01), uUrgent);
  cM = mix(cM, vec3(.95, .08, .05), uUrgent);
  cH = mix(cH, vec3(1., .55, .48), uUrgent);

  float rimLine = exp(-abs(d + .002) * 170.) * (.75 + .4 * uAmp + .3 * uListen);
  float core = 1. - smoothstep(R - .016, R - .006, r);

  vec3 col = vec3(0.);
  if (core < 1.) {
    float len = .075 + .05 * uAmp + .015 * uListen;
    float tb = fbm(vec3(dA * 2.2, d * 8. - uTime * .45));
    float tb2 = fbm(vec3(dA * 4.5, d * 13. - uTime * .8) + 1.5 * tb);
    float jets = .84 + .16 * pow(abs(cos(a * 18.)), 3.);
    float fall = exp(-max(d, 0.) / (len * (.45 + 1.1 * tb2))) *
                 smoothstep(-.012, .003, d);
    float I = fall * jets * (.55 + .75 * tb2) * (1. + .2 * uListen + .45 * uAmp);
    I += rimLine * .7;
    col = cD * smoothstep(0., .25, I) + cM * smoothstep(.12, .75, I) +
          cH * smoothstep(.65, 1.4, I);
  }

  float grain = .82 + .36 * n(vec3(dA * 38., r * 4.));
  vec3 metal = vec3(.016, .018, .024) * grain;
  metal += cM * .45 * exp(-(R - r) * 28.) * (.35 + .25 * uAmp);
  vec3 Lg = normalize(vec3(-.4, .55, .75));
  vec2 cq = uv / R;
  vec3 cn = normalize(vec3(cq * .35, 1.));
  metal += pow(max(dot(reflect(-Lg, cn), vec3(0, 0, 1)), 0.), 60.) * .05;
  col = mix(col, metal, core) + cH * rimLine * .25 * core;

  col += cM * .48 * exp(-max(d, 0.) * 5.5) * (.10 + .14 * uAmp + .08 * uListen) *
         (1. - core);
  col = 1. - exp(-col * 1.5);
  fragColor = vec4(col, 1.);
}
