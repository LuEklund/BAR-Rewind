//! The .curves file: flat arrays of ChronoCam keyframes, written by bake, mmapped by the viewer.
//! Every entity is alive for born <= t < died and its value at t is the lerp of its keys.

const std = @import("std");

pub const magic = "BRC1".*;
pub const version = 8;
pub const alive_forever = std.math.maxInt(u32);

pub fn Key(comptime n: usize) type {
    return extern struct {
        t: u32,
        v: [n]f32,

        pub const len = n;
    };
}

/// pos xyz, front xyz, up xyz
pub const TransformKey = Key(9);
/// health, max health, build progress, active (on/off; 0 or 1)
pub const StatusKey = Key(4);
/// model-space piece matrix, 4 columns of xyz (the w row is always 0,0,0,1)
pub const PieceKey = Key(12);
/// pos xyz, velocity xyz
pub const ProjectileKey = Key(6);
/// What the unit's first weapon aims at: type (0 none, 1 unit, 2 ground, 3 projectile), then the
/// replay's unit id or the ground position. A step curve: sample the last key at or before t.
/// weapon target (type, unit id or ground xyz), then the builder's work: worker command, target
/// (unit id, or -(feature id + 1)), build power
pub const TargetKey = Key(7);

/// Recoil unit-script pose of a piece: Turn angles (x = pitch, y = yaw, z = roll, radians,
/// unwrapped so they lerp) and Move offsets from the piece's original offset
pub const PoseKey = Key(6);

pub const Span = extern struct { first: u32, count: u32 };

pub const Unit = extern struct {
    id: u32,
    def: u32,
    team: u32,
    born: u32,
    died: u32,
    transforms: Span,
    statuses: Span,
    targets: Span,
    tracks: Span,
};

pub const Track = extern struct {
    piece: u32,
    /// unit-script poses (Turn/Move values); model-space matrices follow from them and the
    /// piece hierarchy (poseMatrix)
    pose: Span,
};

pub const Feature = extern struct {
    id: u32,
    def: u32,
    born: u32,
    died: u32,
    pos: [3]f32,
    dir: [3]f32,
};

pub const Projectile = extern struct {
    id: u32,
    /// weapon def, or -2 for piece debris
    def: i32,
    team: i32,
    born: u32,
    died: u32,
    keys: Span,
    /// the unit that fired it (the replay's unit id), or -1
    owner: i32,
};

/// One heightmap point changing at frame t: its height after and before, so playback can apply
/// it in both directions. Sorted by t.
pub const TerrainKey = extern struct {
    t: u32,
    x: u16,
    z: u16,
    h: f32,
    prev: f32,
};

/// A builder's queued build orders from frame t until its next record: `items` in queue_items.
/// unit is the index into units.
pub const Queue = extern struct {
    unit: u32,
    t: u32,
    items: Span,
};

/// unit def, position, facing (0-3)
pub const QueueItem = extern struct {
    def: u32,
    x: f32,
    z: f32,
    facing: f32,
};

pub const Section = enum(u32) { meta, units, transforms, statuses, tracks, features, projectiles, projectile_keys, pose_keys, targets, terrain, queues, queue_items };
pub const section_count = @typeInfo(Section).@"enum".fields.len;

pub fn SectionType(comptime s: Section) type {
    return switch (s) {
        .meta => u8,
        .units => Unit,
        .transforms => TransformKey,
        .statuses => StatusKey,
        .tracks => Track,
        .features => Feature,
        .projectiles => Projectile,
        .projectile_keys => ProjectileKey,
        .pose_keys => PoseKey,
        .targets => TargetKey,
        .terrain => TerrainKey,
        .queues => Queue,
        .queue_items => QueueItem,
    };
}

pub const Header = extern struct {
    magic: [4]u8,
    version: u32,
    first_frame: u32,
    last_frame: u32,
    /// byte offset and element count per Section
    offsets: [section_count]u64,
    counts: [section_count]u64,
};

/// Read-only views into one .curves blob. Holds no memory of its own.
pub const File = struct {
    header: *const Header,
    meta: []const u8,
    units: []const Unit,
    transforms: []const TransformKey,
    statuses: []const StatusKey,
    tracks: []const Track,
    features: []const Feature,
    projectiles: []const Projectile,
    projectile_keys: []const ProjectileKey,
    pose_keys: []const PoseKey,
    targets: []const TargetKey,
    terrain: []const TerrainKey,
    queues: []const Queue,
    queue_items: []const QueueItem,

    pub fn view(bytes: []align(16) const u8) error{BadCurves}!File {
        if (bytes.len < @sizeOf(Header)) return error.BadCurves;
        const header: *const Header = @ptrCast(bytes.ptr);
        if (!std.mem.eql(u8, &header.magic, &magic) or header.version != version) return error.BadCurves;
        var file: File = undefined;
        file.header = header;
        inline for (@typeInfo(Section).@"enum".fields) |field| {
            const T = SectionType(@enumFromInt(field.value));
            const offset = header.offsets[field.value];
            const count = header.counts[field.value];
            if (offset + count * @sizeOf(T) > bytes.len) return error.BadCurves;
            const ptr: [*]const T = @ptrCast(@alignCast(bytes.ptr + offset));
            @field(file, field.name) = ptr[0..count];
        }
        return file;
    }
};

// evaluation -----------------------------------------------------------------------------------

pub fn lerpKey(comptime K: type, a: K, b: K, t: f32) [K.len]f32 {
    const span: f32 = @floatFromInt(b.t - a.t);
    const s = if (span == 0) 0 else std.math.clamp((t - @as(f32, @floatFromInt(a.t))) / span, 0, 1);
    var out: [K.len]f32 = undefined;
    for (&out, a.v, b.v) |*o, x, y| o.* = x + (y - x) * s;
    return out;
}

/// Value of a curve at frame t, clamped to its first and last key.
pub fn sample(comptime K: type, keys: []const K, t: f32) [K.len]f32 {
    std.debug.assert(keys.len > 0);
    // index of the first key strictly after t
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (@as(f32, @floatFromInt(keys[mid].t)) <= t) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return keys[0].v;
    if (lo == keys.len) return keys[keys.len - 1].v;
    return lerpKey(K, keys[lo - 1], keys[lo], t);
}

pub fn slice(comptime T: type, all: []const T, span: Span) []const T {
    return all[span.first..][0..span.count];
}

/// a * b for rigid 3x4 transforms stored as 4 columns of xyz (PieceKey layout).
pub fn mulRigid(a: [12]f32, b: [12]f32) [12]f32 {
    var out: [12]f32 = undefined;
    for (0..4) |c| for (0..3) |r| {
        var sum: f32 = if (c == 3) a[9 + r] else 0;
        for (0..3) |k| sum += a[k * 3 + r] * b[c * 3 + k];
        out[c * 3 + r] = sum;
    };
    return out;
}

/// Inverse of a rigid transform (rotation + translation): [R^T, -R^T t].
pub fn invertRigid(m: [12]f32) [12]f32 {
    var out: [12]f32 = undefined;
    for (0..3) |c| for (0..3) |r| {
        out[c * 3 + r] = m[r * 3 + c];
    };
    for (0..3) |r| out[9 + r] = -(out[r] * m[9] + out[3 + r] * m[10] + out[6 + r] * m[11]);
    return out;
}

test "rigid inverse round trip" {
    const c = @cos(@as(f32, 0.7));
    const s = @sin(@as(f32, 0.7));
    const m: [12]f32 = .{ c, 0, -s, 0, 1, 0, s, 0, c, 3, 4, 5 };
    const id = mulRigid(invertRigid(m), m);
    const expect: [12]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    for (id, expect) |x, y| try std.testing.expectApproxEqAbs(y, x, 1e-5);
}

/// Quaternion (x, y, z, w) of the rotation whose columns are (up x front, up, front), from a
/// TransformKey's front and up. Lerping front and up passes through zero on a half turn and the
/// unit flips; quaternions blend through every orientation. Degenerate input gives identity.
pub fn basisQuat(front: [3]f32, up: [3]f32) [4]f32 {
    const f = normalize(front) orelse return .{ 0, 0, 0, 1 };
    const r = normalize(cross(up, f)) orelse return .{ 0, 0, 0, 1 };
    const u = cross(f, r);
    // m[row][col], columns r, u, f
    const m = [3][3]f32{ .{ r[0], u[0], f[0] }, .{ r[1], u[1], f[1] }, .{ r[2], u[2], f[2] } };
    const trace = m[0][0] + m[1][1] + m[2][2];
    if (trace > 0) {
        const s = @sqrt(trace + 1) * 2;
        return .{ (m[2][1] - m[1][2]) / s, (m[0][2] - m[2][0]) / s, (m[1][0] - m[0][1]) / s, s / 4 };
    } else if (m[0][0] > m[1][1] and m[0][0] > m[2][2]) {
        const s = @sqrt(1 + m[0][0] - m[1][1] - m[2][2]) * 2;
        return .{ s / 4, (m[0][1] + m[1][0]) / s, (m[0][2] + m[2][0]) / s, (m[2][1] - m[1][2]) / s };
    } else if (m[1][1] > m[2][2]) {
        const s = @sqrt(1 + m[1][1] - m[0][0] - m[2][2]) * 2;
        return .{ (m[0][1] + m[1][0]) / s, s / 4, (m[1][2] + m[2][1]) / s, (m[0][2] - m[2][0]) / s };
    } else {
        const s = @sqrt(1 + m[2][2] - m[0][0] - m[1][1]) * 2;
        return .{ (m[0][2] + m[2][0]) / s, (m[1][2] + m[2][1]) / s, s / 4, (m[1][0] - m[0][1]) / s };
    }
}

/// Front and up of quaternion `q` (columns 3 and 2 of its rotation): what replay_player.lua decodes.
pub fn quatFrontUp(q: [4]f32) [2][3]f32 {
    const x, const y, const z, const w = q;
    return .{
        .{ 2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y) },
        .{ 2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w) },
    };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn normalize(v: [3]f32) ?[3]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len < 1e-6) return null;
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

test "basisQuat round trips front and up, half turns included" {
    const cases = [_][2][3]f32{
        .{ .{ 0, 0, 1 }, .{ 0, 1, 0 } },
        .{ .{ 0, 0, -1 }, .{ 0, 1, 0 } },
        .{ .{ -1, 0, 0 }, .{ 0, 1, 0 } },
        .{ .{ 0.6, 0.0, -0.8 }, .{ 0, 0.8, 0.6 } }, // pitched
        .{ .{ 0.1, -0.2, -0.97 }, .{ 0.3, 0.9, -0.1 } }, // not orthogonal: up gets corrected
    };
    for (cases) |c| {
        const fu = quatFrontUp(basisQuat(c[0], c[1]));
        const f = normalize(c[0]).?;
        for (fu[0], f) |a, b| try std.testing.expectApproxEqAbs(b, a, 1e-4);
        // up stays in the plane of front and the given up, on its side
        const d = fu[1][0] * c[1][0] + fu[1][1] * c[1][1] + fu[1][2] * c[1][2];
        try std.testing.expect(d > 0);
        try std.testing.expectApproxEqAbs(@as(f32, 0), fu[1][0] * f[0] + fu[1][1] * f[1] + fu[1][2] * f[2], 1e-4);
    }
}

/// Turn angles (pitch, yaw, roll) whose composition in Recoil
/// (RotateY(yaw) * RotateX(pitch) * RotateZ(roll), each rotating by the negated angle) gives the
/// rotation part of `m`. Standard YXZ decomposition of R = Ry(-yaw) Rx(-pitch) Rz(-roll).
pub fn recoilAngles(m: [12]f32) [3]f32 {
    // R[i][j] = m[3 * j + i]
    const r02 = m[6];
    const r22 = m[8];
    const r10 = m[1];
    const r11 = m[4];
    const r12 = m[7];
    const a = std.math.atan2(r02, r22);
    const b = std.math.asin(std.math.clamp(-r12, -1, 1));
    const c = std.math.atan2(r10, r11);
    return .{ -b, -a, -c };
}

test "recoil angles reproduce the rotation" {
    // R = Ry(a) Rx(b) Rz(c), column-major 3x3 then padded to 12
    const a: f32 = 0.4;
    const b: f32 = -0.3;
    const c: f32 = 1.1;
    const ry = [3][3]f32{ .{ @cos(a), 0, @sin(a) }, .{ 0, 1, 0 }, .{ -@sin(a), 0, @cos(a) } };
    const rx = [3][3]f32{ .{ 1, 0, 0 }, .{ 0, @cos(b), -@sin(b) }, .{ 0, @sin(b), @cos(b) } };
    const rz = [3][3]f32{ .{ @cos(c), -@sin(c), 0 }, .{ @sin(c), @cos(c), 0 }, .{ 0, 0, 1 } };
    var ryx: [3][3]f32 = undefined;
    var r: [3][3]f32 = undefined;
    for (0..3) |i| for (0..3) |j| {
        ryx[i][j] = 0;
        for (0..3) |k| ryx[i][j] += ry[i][k] * rx[k][j];
    };
    for (0..3) |i| for (0..3) |j| {
        r[i][j] = 0;
        for (0..3) |k| r[i][j] += ryx[i][k] * rz[k][j];
    };
    var m: [12]f32 = @splat(0);
    for (0..3) |i| for (0..3) |j| {
        m[3 * j + i] = r[i][j];
    };
    const got = recoilAngles(m);
    try std.testing.expectApproxEqAbs(-b, got[0], 1e-5);
    try std.testing.expectApproxEqAbs(-a, got[1], 1e-5);
    try std.testing.expectApproxEqAbs(-c, got[2], 1e-5);
}

/// Piece-space transform (PieceKey layout) from a pose and the piece's original offset: the
/// inverse of recoilAngles + move, i.e. what Recoil composes as T(offset + move) * R(angles).
pub fn poseMatrix(pose: [6]f32, offset: [3]f32) [12]f32 {
    const a = -pose[1];
    const b = -pose[0];
    const c = -pose[2];
    const ca, const sa = .{ @cos(a), @sin(a) };
    const cb, const sb = .{ @cos(b), @sin(b) };
    const cc, const sc = .{ @cos(c), @sin(c) };
    // R = Ry(a) Rx(b) Rz(c), column-major
    return .{
        ca * cc + sa * sb * sc,  cb * sc, -sa * cc + ca * sb * sc,
        -ca * sc + sa * sb * cc, cb * cc, sa * sc + ca * sb * cc,
        sa * cb,                 -sb,     ca * cb,
        offset[0] + pose[3],     offset[1] + pose[4], offset[2] + pose[5],
    };
}

test "poseMatrix inverts recoilAngles" {
    const pose: [6]f32 = .{ 0.3, -1.2, 0.7, 1, 2, 3 };
    const m = poseMatrix(pose, .{ 10, 20, 30 });
    const back = recoilAngles(m);
    for (back, pose[0..3]) |x, y| try std.testing.expectApproxEqAbs(y, x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 11), m[9], 1e-5);
}

// simplification -------------------------------------------------------------------------------

/// Weighted max-component distance: the error metric for one key against a curve value.
pub fn keyError(comptime n: usize, a: [n]f32, b: [n]f32, scale: [n]f32) f32 {
    var worst: f32 = 0;
    for (a, b, scale) |x, y, s| worst = @max(worst, @abs(x - y) * s);
    return worst;
}

/// Douglas-Peucker over time: marks in `keep` the fewest keys whose linear interpolation stays
/// within `tolerance` of every input key. `stack` needs keys.len entries.
pub fn simplify(comptime K: type, keys: []const K, scale: [K.len]f32, tolerance: f32, keep: []bool, stack: [][2]u32) void {
    std.debug.assert(keep.len == keys.len and stack.len >= keys.len);
    @memset(keep, false);
    if (keys.len == 0) return;
    keep[0] = true;
    keep[keys.len - 1] = true;
    if (keys.len < 3) return;

    var top: usize = 0;
    stack[top] = .{ 0, @intCast(keys.len - 1) };
    top += 1;
    while (top > 0) {
        top -= 1;
        const a, const b = stack[top];
        var worst: f32 = 0;
        var worst_index: u32 = 0;
        var i = a + 1;
        while (i < b) : (i += 1) {
            const value = lerpKey(K, keys[a], keys[b], @floatFromInt(keys[i].t));
            const e = keyError(K.len, value, keys[i].v, scale);
            if (e > worst) {
                worst = e;
                worst_index = i;
            }
        }
        if (worst <= tolerance) continue;
        keep[worst_index] = true;
        stack[top] = .{ a, worst_index };
        stack[top + 1] = .{ worst_index, b };
        top += 2;
    }
}

test "simplify keeps a straight line to its ends and restores the corner" {
    const K = Key(1);
    var keys: [21]K = undefined;
    for (&keys, 0..) |*k, i| {
        const x: f32 = @floatFromInt(i);
        k.* = .{ .t = @intCast(i * 3), .v = .{if (i <= 10) x else 20 - x} };
    }
    var keep: [keys.len]bool = undefined;
    var stack: [keys.len][2]u32 = undefined;
    simplify(K, &keys, .{1}, 0.01, &keep, &stack);
    var kept: usize = 0;
    for (keep) |k| kept += @intFromBool(k);
    try std.testing.expectEqual(3, kept);
    try std.testing.expect(keep[0] and keep[10] and keep[20]);

    const out = [_]K{ keys[0], keys[10], keys[20] };
    for (keys) |k| try std.testing.expectApproxEqAbs(k.v[0], sample(K, &out, @floatFromInt(k.t))[0], 1e-4);
    try std.testing.expectEqual(0, sample(K, &out, -5)[0]);
    try std.testing.expectEqual(0, sample(K, &out, 1000)[0]);
}
