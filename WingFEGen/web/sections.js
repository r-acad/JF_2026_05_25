/* Physical PBARL cross-sections. All coordinates and offsets use model metres.
 * The local x axis joins the end grids; local y is the projected CBAR
 * orientation vector, and local z completes the right-handed frame.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingSections = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const sub = (a, b) => a.map((v, i) => v - b[i]);
  const dot = (a, b) => a.reduce((s, v, i) => s + v * b[i], 0);
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  function unit(a) {
    const n = Math.hypot(...a);
    if (!(n > 1e-14)) throw new Error("Degenerate CBAR frame in section display");
    return a.map((v) => v / n);
  }
  const point = (positions, node) => Array.from(positions.subarray(3 * node, 3 * node + 3));
  function frame(a, b, orientation, referenceX) {
    const axis = sub(b, a);
    // A displayed, magnified shape can bring the two ends together. The
    // original frame still defines the cross-section at this instant; this
    // does not alter the FE coordinates or relax the undeformed-bar check.
    const x = unit(referenceX && Math.hypot(...axis) <= 1e-14 ? referenceX : axis);
    let projected = orientation.map((v, i) => v - dot(orientation, x) * x[i]);
    // An exaggerated deformation can turn the bar parallel to its reference
    // orientation. Choose the least parallel global direction in this limit.
    if (Math.hypot(...projected) < 1e-10 * Math.max(1, Math.hypot(...orientation))) {
      const k = x.reduce((best, v, i) => Math.abs(v) < Math.abs(x[best]) ? i : best, 0);
      const fallback = [0, 0, 0]; fallback[k] = 1;
      projected = fallback.map((v, i) => v - dot(fallback, x) * x[i]);
    }
    const y = unit(projected), z = unit(cross(x, y));
    return { x, y, z };
  }

  /** Finite rotation of the displayed section from its nodal rotation vector. */
  function rotate(vector, rotation, scale) {
    const magnitude = Math.hypot(...rotation);
    const angle = magnitude * scale;
    if (Math.abs(angle) < 1e-14) return vector;
    // Eigenvectors may contain arbitrarily small, nonzero rotations. A large
    // display scale makes their angle visible, but the geometry-length
    // tolerance in unit() must not reject their rotation axis.
    if (!Number.isFinite(angle) || !Number.isFinite(magnitude)) throw new Error("Non-finite CBAR rotation in section display");
    const axis = rotation.map(v => v / magnitude), c = Math.cos(angle), s = Math.sin(angle);
    const normal = cross(axis, vector), axial = dot(axis, vector);
    return vector.map((v, i) => c * v + s * normal[i] + (1 - c) * axial * axis[i]);
  }

  /** Ear clipping covers the concave T section without filling its recesses. */
  function triangulate(polygon) {
    const signed = polygon.reduce((sum, a, i) => {
      const b = polygon[(i + 1) % polygon.length]; return sum + a[0] * b[1] - b[0] * a[1];
    }, 0);
    const order = Array.from({ length: polygon.length }, (_, i) => i);
    if (signed < 0) order.reverse();
    const size = Math.max(...polygon.flat().map(Math.abs), 1e-8);
    const epsilon = size * size * 1e-12;
    const turn = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    const inside = (p, a, b, c) => turn(a, b, p) >= -epsilon && turn(b, c, p) >= -epsilon && turn(c, a, p) >= -epsilon;
    const triangles = [], remaining = order.slice();
    while (remaining.length > 3) {
      let clipped = false;
      for (let i = 0; i < remaining.length; i++) {
        const prev = remaining[(i + remaining.length - 1) % remaining.length];
        const current = remaining[i], next = remaining[(i + 1) % remaining.length];
        const a = polygon[prev], b = polygon[current], c = polygon[next];
        if (turn(a, b, c) <= epsilon) continue;
        if (remaining.some((k) => k !== prev && k !== current && k !== next && inside(polygon[k], a, b, c))) continue;
        triangles.push([prev, current, next]); remaining.splice(i, 1); clipped = true; break;
      }
      if (!clipped) throw new Error("Invalid or degenerate bar section polygon");
    }
    triangles.push(remaining);
    return { triangles, order };
  }

  function geometry(positions, conn, orientations, section) {
    const polygon = section.polygon_yz_m;
    if (!Array.isArray(polygon) || polygon.length < 3) throw new Error("Missing physical bar section polygon");
    const { triangles, order } = triangulate(polygon);
    const template = [];
    const triangle = (end, a, b, c) => template.push([end, a], [end, b], [end, c]);
    for (const [a, b, c] of triangles) { triangle(0, c, b, a); triangle(1, a, b, c); }
    for (let i = 0; i < order.length; i++) {
      const a = order[i], b = order[(i + 1) % order.length];
      template.push([0, a], [0, b], [1, b], [0, a], [1, b], [1, a]);
    }
    const count = conn.length / 2, nv = count * template.length;
    const result = {
      positions: new Float32Array(3 * nv), indices: Int32Array.from({ length: nv }, (_, i) => i),
      vertexElements: new Int32Array(nv), faceElements: new Int32Array(nv / 3),
      conn, orientations, section, template, verticesPerElement: template.length,
      referenceX: new Float32Array(3 * count), referenceY: new Float32Array(3 * count),
    };
    for (let e = 0; e < count; e++) {
      const reference = frame(point(positions, conn[2 * e]), point(positions, conn[2 * e + 1]), point(orientations, e));
      result.referenceX.set(reference.x, 3 * e);
      result.referenceY.set(reference.y, 3 * e);
      result.vertexElements.fill(e, e * template.length, (e + 1) * template.length);
      result.faceElements.fill(e, e * template.length / 3, (e + 1) * template.length / 3);
    }
    update(result, positions);
    return result;
  }

  function update(geometry, positions, rotations, rotationScale = 1) {
    const { conn, orientations, section, template } = geometry;
    const offsetY = section.offset_y_m || 0, offsetZ = section.offset_z_m || 0;
    for (let e = 0; e < conn.length / 2; e++) {
      const a = point(positions, conn[2 * e]), b = point(positions, conn[2 * e + 1]);
      const referenceX = point(geometry.referenceX, e);
      const endFrames = rotations && rotationScale !== 0 ? [0, 1].map((end) => frame(a, b,
        rotate(point(geometry.referenceY, e), point(rotations, conn[2 * e + end]), rotationScale), referenceX)) :
        [frame(a, b, point(orientations, e), referenceX)];
      template.forEach(([end, index], v) => {
        const origin = end ? b : a, yz = section.polygon_yz_m[index];
        const { y, z } = endFrames[end] || endFrames[0];
        for (let c = 0; c < 3; c++) geometry.positions[3 * (e * template.length + v) + c] =
          origin[c] + (yz[0] + offsetY) * y[c] + (yz[1] + offsetZ) * z[c];
      });
    }
    return geometry.positions;
  }

  function createMesh(BABYLON, options) {
    const { name, scene, positions, conn, orientations, section } = options;
    const data = geometry(positions, conn, orientations, section);
    const mesh = new BABYLON.Mesh(name, scene), vertexData = new BABYLON.VertexData();
    vertexData.positions = data.positions; vertexData.indices = data.indices;
    data.normals = new Float32Array(data.positions.length);
    vertexData.normals = data.normals;
    BABYLON.VertexData.ComputeNormals(data.positions, data.indices, data.normals, { useRightHandedSystem: true });
    vertexData.colors = new Float32Array(data.vertexElements.length * 4).fill(1);
    vertexData.applyToMesh(mesh, true);
    mesh.sectionGeometry = data;
    mesh.barRepresentation = "sections";
    return mesh;
  }

  function updateMesh(BABYLON, mesh, positions, rotations, rotationScale = 1) {
    const data = mesh.sectionGeometry;
    update(data, positions, rotations, rotationScale);
    mesh.updateVerticesData(BABYLON.VertexBuffer.PositionKind, data.positions, true, false);
    BABYLON.VertexData.ComputeNormals(data.positions, data.indices, data.normals, { useRightHandedSystem: true });
    mesh.updateVerticesData(BABYLON.VertexBuffer.NormalKind, data.normals);
  }
  return { frame, rotate, triangulate, geometry, update, createMesh, updateMesh };
});
