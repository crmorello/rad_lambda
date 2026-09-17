# Typed radar bytes — client handoff

The radar producer now folds precipitation **type** into every radar byte
(rad_lambda `9b66c0a`). Until now every radar byte was 1..88 — plain dBZ — so
nothing downstream has ever been exercised above 88.

**It is not live yet.** The commit is unpushed and the radar function still runs
a pre-typing image, so every byte in the bucket today is still 1..88. The client
can therefore ship **first**, with no risk and no feature flag: band support
renders untyped frames identically, because 1..88 *is* the rain band. Ship the
client, then we deploy the producer.

## The contract

From `radcore/src/recon.zig:28-43`. This is radcore's, not ours, and not up for
negotiation:

```
rain   bytes 1..88     dBZ = byte
mixed  bytes 90..168   dBZ = byte - 80
snow   bytes 170..254  dBZ = byte - 160
89, 169, 255  separators — never emitted, treat as invalid
0             no data
```

The bands are **not** symmetric: mixed and snow start at 10 dBZ, and snow runs
to 94. Anything that assumes `byte == dBZ` is wrong for typed pixels.

## Already correct — please don't redo it

Most of this work is already done, and it is genuinely correct. Verified line by
line against `recon.zig`:

| | Status |
|---|---|
| `band_of` / `band_dbz` / `band_byte` — `shaders/radar.wgsl:182-205` | **byte-identical** to `recon.zig` |
| `accum_add` / `accum_result` — `radar.wgsl:235-299` | identical: same epsilons, same dominant-type argmax |
| Separator rejection on the accumulation path — `radar.wgsl:240-247` | present |
| Frame tween `combine` — `radar.wgsl:319-331` | type-aware; snaps at `t=0.5`, never blends through mixed |
| Hardware bilinear (mode 5) — `radar.wgsl:430-438` | gated on all four taps sharing a band |
| Palette → continuous under CNN/NWS | correct in **both** clients (`MapLibreRadar.swift:461`, `web/app.js:1284` and `:1435`); matches `radcore/src/tile.zig:91` |
| Product metadata over the C ABI | `interp` is read in both (`RadCoreBridge.swift:365`, `web/radcore.js:118`) |
| Value readout | `zc_product_describe` in both (`ContentView.swift:281`, `web/app.js:1348`) — no local byte→dBZ maths anywhere in either client |
| `RadarProduct.swift` | **not** a stale copy of the registry; already a thin view over it |
| Generated `RadarWGSL.metal` / `web/radar_wgsl.js` | currently in sync with the `.wgsl` |

Tap-to-inspect will print `"30 dBZ (snow)"` for free once the core is rebuilt —
both clients already route through `describe`.

## Must fix before typed frames go live

### 1. `base_alpha` saturates for every mixed and snow byte

`radar.wgsl:603-605`:

```wgsl
fn base_alpha(data_value: f32) -> f32 {
    return smoothstep(u.alpha_range.x, u.alpha_range.y, data_value);
}
```

`data_value` is the **raw** normalized byte, and radar's registry range is
`alpha_lo = 0.0, alpha_hi = 0.125` (`radcore/src/products.zig:102-103`) — i.e.
bytes 0..32. Mixed starts at byte 90 (0.353) and snow at byte 170 (0.667), so
both pin alpha to **1.0**. Light 10 dBZ snow renders exactly as opaque as
88 dBZ rain, losing the feathered low-intensity edge that rain keeps.

Fix: smoothstep the **decoded dBZ**, not the raw byte. `band_of` and `band_dbz`
are already right there in the shader.

**This one is shared — it has to land in lockstep with us.**
`radcore/src/tile.zig:115` does the identical thing, so server-rendered tiles
have the same defect. If only one side changes, tiles and on-device stop
matching. Co-ordinate before you merge.

### 2. `tap_blend` blends raw bytes across frames, class-blind

`radar.wgsl:160-163`:

```wgsl
fn tap_blend(uv: vec2<f32>, ts: vec2<f32>, info_curr: AtlasInfo, info_next: AtlasInfo) -> f32 {
    return mix(tap(curr_index, curr_atlas, uv, ts, info_curr),
               tap(next_index, next_atlas, uv, ts, info_next), u.frame_blend);
}
```

No `band_of` guard. Rain 88 in frame N against snow 190 in N+1 gives ~139 at
`frame_blend = 0.5` — mixed precip at 59 dBZ, invented out of nothing. It also
returns 0 for nodata, which then reads as "0 dBZ" rather than absent.

The *main* tween path is safe — `combine` already guards it. These are the
effect probes that bypass it: `effect_halftone` (`:700-704`), `effect_cores`
(`:754`), and `effect_normal`'s depth probe (`:622`, single-frame so nodata
only).

### 3. Effects treat the byte as a scalar magnitude

All four were tuned against a rain-only histogram and are wrong above 88:

- `effect_evolution` (`:639-657`) — `(v_next - v_curr) * 6.0`. Rain 50 → snow
  200 reads as a massive intensification when it is actually a phase change.
- `effect_terraced` (`:663-665`) — `data_value / 0.03`. Eight terraces sized for
  the rain run, then ~26 more of pure type offset above it.
- `effect_topo` (`:783-786`) — 0.016 contour interval, tuned to a measured
  rain-only p50/p99. Snow bytes contour the *offset*, drawing ~50 spurious
  isolines.
- `effect_cores` (`:757-762`) — `core_thresh = 0.14` (byte ~36). Every mixed and
  snow byte is now unconditionally "a storm core".

Each needs to run on decoded dBZ. `cores` and `evolution` arguably want a
type-change concept rather than a magnitude delta — your call.

**If any of these are experimental rather than shipped, tell us and we will drop
them down the list.** We could not tell from the outside.

## Worth fixing, not blocking

### 4. Cubic kernel weights diverge from `recon.zig`

`recon_cubic2x2` (`radar.wgsl:536-549`) is a reduced 2×2 / 4-tap; radcore's
`recon.catmullRom` (`recon.zig:143-167`) is a full 4×4 / 16-tap
Mitchell–Netravali. This is pre-existing and the shader comment acknowledges it,
but typing gives it a **new** consequence: the wider kernel sees more
neighbourhood, so its `bw[]` argmax can pick a *different dominant precip type*
at a rain/snow seam. A server tile and the on-device render of the same pixel
can now disagree on type, not just on smoothing.

`recon.zig`'s header asks for "same weights, same band rules". The rules match;
the weights do not.

Related: `tile.zig:104-107` uses a class-aware box filter when minifying; the
shader has no box path and falls back to `recon_tent`.

### 5. There is no legend

Repo-wide the only hit is a TODO (`raydare/docs/obs-product.md:241`). Three
colour families now need explaining to users.

One blocker to know about: `zc_product_value` is unused in Swift and **not bound
at all** in JS, so a data-driven legend currently has no API to build from. It
needs that binding, or a new call returning band boundaries and labels.

### 6. Smaller items

- `MapLibreRadar.swift:928` builds `RenderKey` from the *unswitched*
  `playback.sampleClass` rather than the palette-derived value actually sent to
  the GPU. Latent only — `colorMode` is also in the key.
- `web/radcore.js:99-100` hand-mirrors the `ZCProductInfo` field offsets. If a
  field is ever inserted before `interp`, JS reads garbage rather than failing.
  Swift is immune (it imports the real header).
- `scripts/lod_measure.py:28-33` folds separators into the wrong bands
  (`89` → rain, `169` → mixed, `255` → snow) and its hazard test (`:59`,
  `HAZ = 50` applied only where `band == rain`) will under-report on exactly the
  winter frames this change is about.

## Regenerating the shader — both targets, together

```
shaders/radar.wgsl
  -> raydare/RadarWGSL.metal   (Swift / Metal)
  -> web/radar_wgsl.js         (web / WebGL2)
```

`scripts/gen-shaders.sh` → `tools/shadergen` (Rust + naga). **It is not wired
into the Xcode build** — it is a manual step, and both outputs are committed.
Regenerate and commit both or native and web silently diverge. There is no CI
check that the generated files match the source; adding one is cheap and would
have caught nothing today, but will eventually.

## On our side — fixed, and one belt-and-braces item

**Snow at 40–49 dBZ rendered opaque black — fixed in radcore `2158672`.**
Default-ramp entries 200–209 were `#000000` inside the snow band. The black
pixels were genuinely in `radcore/tools/ramps/color_scale.png`, so the fix was
there: the snow band (bytes 170–240) is now one smooth gradient from
`#00e0ff` to `#00195c`, with rain, mixed, the 89/169/255 separators and the
241–254 saturation plateau all byte-identical to before.

**Pull radcore before you start.** This lands in the shared table, so it fixes
native, web and the tile server together — there is nothing to do on your side
and nothing to work around. One thing to expect: snow colours shift across the
whole band, not only the old gap (worst case +23 green at byte 199, −47 blue
near byte 220), so any screenshot baselines covering snow need regenerating.

Also ours: `products.zig` `value()` / `describe()` have no separator case, so a
stray 89/169/255 prints nonsense (`169` → `"89 dBZ (mixed)"`). The producer
never emits them, so this is belt-and-braces.

Pre-existing and unrelated to typing, but worth knowing: ramp entry 0 is opaque
dark green (`#006400`). Byte 0 is "no data" and is meant to be excluded by the
alpha rule, not by the ramp — don't start trusting ramp alpha for nodata.

**Excluded deliberately:** the Z-R accumulation path weights the raw byte
squared (`radcore/src/core.zig:1283-1299`), so 40 dBZ snow would count ~25× the
same rain. We are not fixing that now.

## Verification

- **Build a synthetic frame first.** A deliberate rain / mixed / snow patchwork
  including the band edges (1, 88, 90, 168, 170, 254) and a hard rain↔snow seam.
  Confirm: three distinct colour families; no magenta at the seam; low-dBZ snow
  fades in like low-dBZ rain (that is fix 1); tap-to-inspect reports `"… (snow)"`.
- **Tween.** Step across two frames where a cell flips rain→snow. It should snap
  rather than slide through mixed — and once fix 2 lands, halftone and cores
  should agree with the base layer.
- **Palette.** Switch to CNN and confirm bytes are read as continuous dBZ.
- **Cross-check against tiles.** Same stamp, same z/x/y, on-device versus the
  tile endpoint. They should agree; divergence 4 is the known reason they might
  not.
- After regenerating, confirm the band constants still round-trip into both
  outputs: `89.0 / 169.0 / 254.5 / 80.0 / 9.0 / 6.0`.
