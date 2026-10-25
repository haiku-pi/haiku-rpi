// The smallest shader of #75 that V3DV miscompiled before mesa dee7e96cb04 (a vec4 phi copied
// through a vector mov, of which only .x was moved): Photocraft's Blend If pass reduced to the tex_c
// branch and blend_if_weight. photocraft-shader-repro --wgsl blend-if-min.wgsl: FAIL before, PASS after.

struct Chunk {
    origin: vec2<i32>,
    size: vec2<i32>,
};

struct Op {
    mode: i32,
    kind: i32,
    flags: u32,
    _pad0: u32,
    opacity: f32,
    mask_density: f32,
    mask_default: f32,
    fill: f32,       // layer Fill for fs_blend (psblend::composite_fill); 1 elsewhere
    tex_origin: vec2<i32>,
    tex_size: vec2<i32>,
    mask_origin: vec2<i32>,
    mask_size: vec2<i32>,
    color: vec4<f32>,
    p0: vec4<f32>,
    p1: vec4<f32>,
    p2: vec4<f32>,
    p3: vec4<f32>,
    map_origin: vec2<i32>,
    map_size: vec2<i32>,
    p4: vec4<f32>,
    // fs_layerbatch's third extra layer and the rest of its second (see `batch_layer`); zero
    // elsewhere. With them the record fills its 256-byte stride.
    q0: vec4<f32>,
    q1: vec4<f32>,
    q2: vec4<f32>,
    q3: vec4<f32>,
    q4: vec4<f32>,
};


@group(0) @binding(0) var<uniform> chunk: Chunk;
@group(0) @binding(1) var<uniform> op: Op;
@group(1) @binding(0) var tex_a: texture_2d<f32>;
@group(1) @binding(1) var tex_b: texture_2d<f32>;
@group(1) @binding(5) var tex_c: texture_2d<f32>;

struct VOut { @builtin(position) pos: vec4<f32> };

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> VOut {
    let uv = vec2(f32((vi << 1u) & 2u), f32(vi & 2u));
    return VOut(vec4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0));
}

fn bi_ramp(lo: f32, hi: f32, x: f32) -> f32 {
    if (hi <= lo) {
        return select(0.0, 1.0, x >= lo);
    }
    return clamp((x - lo) / (hi - lo), 0.0, 1.0);
}

fn bi_weight(e: u32, s: u32, v: f32) -> f32 {
    var f = array<vec4<f32>, 4>(op.p0, op.p1, op.p2, op.p3);
    let i = (e * 2u + s) * 2u;
    let black = f[i / 4u][i % 4u];
    let white = f[(i + 1u) / 4u][(i + 1u) % 4u];
    let b_lo = floor(black / 256.0);
    let b_hi = black - b_lo * 256.0;
    let w_lo = floor(white / 256.0);
    let w_hi = white - w_lo * 256.0;
    return bi_ramp(b_lo, b_hi, v) * bi_ramp(255.0 - w_hi, 255.0 - w_lo, 255.0 - v);
}

fn blend_if_weight(this_px: vec4<f32>, under: vec4<f32>) -> f32 {
    var k = 1.0;
    for (var s = 0u; s < 2u; s = s + 1u) {
        let px = select(this_px, under, s == 1u);
        if (px.a <= 0.0) {
            continue;
        }
        let raw = clamp(px.rgb, vec3(0.0), vec3(1.0)) * 255.0;
        let v = select(raw, round(raw), abs(raw - round(raw)) < vec3(1e-4));
        let gray = 0.299 * v.r + 0.587 * v.g + 0.114 * v.b;
        k = k * bi_weight(0u, s, gray) * bi_weight(1u, s, v.r) * bi_weight(2u, s, v.g) * bi_weight(3u, s, v.b);
        if (k <= 0.0) {
            return 0.0;
        }
    }
    return k;
}

@fragment
fn fs_lerp(in: VOut) -> @location(0) vec4<f32> {
    let p = vec2<i32>(floor(in.pos.xy));
    let a = textureLoad(tex_a, p, 0);
    let b = textureLoad(tex_b, p, 0);
    var this_px = b;
    if (op.p4.y < 0.5) {
        this_px = textureLoad(tex_c, p, 0);
    }
    let k = blend_if_weight(this_px, a);
    if (k >= 1.0) {
        return b;
    }
    let alpha = a.a + (b.a - a.a) * k;
    if (alpha <= 0.0) { return vec4(0.0); }
    return vec4(clamp((a.rgb * a.a + (b.rgb * b.a - a.rgb * a.a) * k) / alpha, vec3(0.0), vec3(1.0)), alpha);
}
