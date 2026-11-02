#include <metal_stdlib>
using namespace metal;

// Must match EyeWarpGPU in MetalWarper.swift. Positions are pixels, top-left origin.
struct EyeWarp {
    float2 iris;
    float2 displacement;
    float2 center;
    float2 axis;
    float2 halfSize;
    float irisRadius;
    float padding;
};

// 1 inside the eye opening, fading to 0 just past its edge. `stretch` grows the ellipse per axis.
static float openingMask(float2 p, constant EyeWarp &e, float2 stretch) {
    float2 d = p - e.center;
    float2 ay = float2(-e.axis.y, e.axis.x);
    float x = dot(d, e.axis) / (e.halfSize.x * stretch.x);
    float y = dot(d, ay) / (e.halfSize.y * stretch.y);
    return 1.0 - smoothstep(0.75, 1.1, length(float2(x, y)));
}

// Forward displacement field: where the content at p moves to is p + displacementAt(p).
static float2 displacementAt(float2 p, constant EyeWarp *eyes, uint count) {
    float2 total = float2(0.0);
    for (uint i = 0; i < count; i++) {
        constant EyeWarp &e = eyes[i];
        if (length(p - e.center) > e.halfSize.x * 3.0) continue;

        float2 ax = e.axis;
        float2 ay = float2(-ax.y, ax.x);
        float2 q = p - e.iris;
        float qx = dot(q, ax);
        float qy = dot(q, ay);

        // The whole iris shifts rigidly and the band around it (sclera, lid edges) stretches, so
        // nothing tears. Vision's six-point eye contour is too coarse to clip by: on real faces it
        // cuts through the iris, which held real moves to ~40% of the planned shift. So the weight
        // follows the iris itself and the contour only pins the eye corners. Shifting the lids
        // sideways along with it is barely visible, since lid lines run sideways anyway.
        float cornerPin = 1.0 - smoothstep(0.75, 1.05, fabs(dot(p - e.center, ax)) / e.halfSize.x);
        float irisWeight = (1.0 - smoothstep(1.0, 2.6, length(q) / e.irisRadius)) * cornerPin;

        // Looking up or down moves the lids too: the upper lid follows the iris closely, the lower
        // lid less, and the eye corners stay pinned so the eye itself does not slide on the face.
        float sx = e.halfSize.x * 0.8;
        float sy = e.halfSize.y * 2.0 + e.irisRadius;
        float upper = 1.0 - smoothstep(-0.5, 0.5, qy / e.irisRadius);
        float lidShare = mix(0.3, 0.75, upper);
        float lidWeight = lidShare * cornerPin
                        * exp(-(qx * qx / (2.0 * sx * sx) + qy * qy / (2.0 * sy * sy)))
                        * openingMask(p, e, float2(1.3, 3.2));
        float verticalWeight = irisWeight + (1.0 - irisWeight) * lidWeight;

        total += ax * (dot(e.displacement, ax) * irisWeight) + ay * (dot(e.displacement, ay) * verticalWeight);
    }
    return total;
}

kernel void warpEyes(texture2d<float, access::sample> source [[texture(0)]],
                     texture2d<float, access::write> destination [[texture(1)]],
                     constant EyeWarp *eyes [[buffer(0)]],
                     constant uint &count [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;
    constexpr sampler linearSampler(coord::pixel, address::clamp_to_edge, filter::linear);

    // Output pixel p shows the content that moved there: solve p = q + D(q) for q.
    float2 p = float2(gid) + 0.5;
    float2 q = p;
    for (int k = 0; k < 3; k++) {
        q = p - displacementAt(q, eyes, count);
    }
    destination.write(source.sample(linearSampler, q), gid);
}
