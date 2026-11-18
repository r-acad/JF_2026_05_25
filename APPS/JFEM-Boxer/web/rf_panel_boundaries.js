/* Exterior boundaries of the authored skin/stringer element groups. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WingRFPanelBoundaries = api;
})(globalThis, function () {
  'use strict';

  function collect({panels = [], plainPanels = [], elements, allowed = null, visible = () => true, splitProperties = false}) {
    const groups = [], assigned = new Set();
    const skinIds = panel => [...new Set([
      ...(panel.shell_eids || panel.skin_eids || []), ...(panel.stringer_flange_eids || [])
    ].map(Number))];

    function add(panel, ids, kind) {
      const faces = ids.filter(id => {
        const element = elements.get(id);
        return element && ['quad', 'tria'].includes(element.group.kind) && visible(element);
      });
      let selected = allowed ? faces.filter(id => allowed.has(id)) : faces;
      // A failing beam can remain visible while its associated skin passes.
      // Its skin frame still identifies the compression group being sized.
      const stringerVisible = allowed && (panel.stringer_eids || []).some(id => {
        const element = elements.get(Number(id));
        return element && allowed.has(Number(id)) && visible(element);
      });
      const stringerOnly = !selected.length && !!stringerVisible;
      if (stringerOnly) selected = faces;
      if (!selected.length) return;

      const edges = new Map();
      for (const eid of selected) {
        const nodes = elements.get(eid).nodes;
        for (let i = 0; i < nodes.length; i++) {
          const a = nodes[i], b = nodes[(i + 1) % nodes.length];
          if (a === b) continue;
          const edgeKey = a < b ? a + ':' + b : b + ':' + a;
          const key = splitProperties ? edgeKey + '@' + elements.get(eid).group.pid : edgeKey;
          const edge = edges.get(key);
          if (edge) edge.count++;
          else edges.set(key, {a, b, eid, count: 1});
        }
      }
      const segments = [...edges.values()].filter(edge => edge.count === 1)
        .map(({a, b, eid}) => ({a, b, eid}));
      if (segments.length) groups.push({
        key: panel.key, panelId: panel.id ?? panel.panel_id ?? null,
        label: panel.label || panel.key, kind, elementIds: selected, stringerOnly, segments
      });
    }

    for (const panel of panels) {
      const ids = skinIds(panel);
      for (const id of ids) assigned.add(id);
      add(panel, ids, 'compression_panel');
    }
    for (const plate of plainPanels) {
      const ids = (plate.member_element_ids || []).map(Number).filter(id => !assigned.has(id));
      if (ids.length) add(plate, ids, 'plain_skin');
    }
    return groups;
  }

  function positions(group, {elements, nodes, explosion, thickness = false}) {
    const output = [];
    for (const edge of group.segments) {
      const element = elements.get(edge.eid), indices = element.nodes;
      const at = node => [nodes[3 * node], nodes[3 * node + 1], nodes[3 * node + 2]];
      const properties = element.group.properties || {}, t = properties.thickness_m;
      let offsets = [0], normal = [0, 0, 0];
      if (thickness && t > 0 && Number.isFinite(t) && properties.thickness_display_supported !== false) {
        const bottom = Number.isFinite(properties.z_bottom_m) ? properties.z_bottom_m :
          Number.isFinite(properties.z0_m) ? properties.z0_m : -t / 2;
        const top = Number.isFinite(properties.z_top_m) ? properties.z_top_m : bottom + t;
        const p = at(indices[0]), q = at(indices[1]), r = at(indices[2]);
        const u = (indices.length === 4 ? r : q).map((value, i) => value - p[i]);
        const v = indices.length === 4 ? at(indices[3]).map((value, i) => value - q[i]) : r.map((value, i) => value - p[i]);
        normal = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
        const length = Math.hypot(...normal);
        if (length > 1e-20 && Number.isFinite(bottom) && Number.isFinite(top)) {
          normal = normal.map(value => value / length);
          offsets = [bottom, top];
        }
      }
      for (const offset of offsets) for (const node of [edge.a, edge.b]) {
        const point = at(node).map((value, axis) => value + offset * normal[axis]);
        output.push(...(explosion?.active ? explosion.point(edge.eid, point) : point));
      }
    }
    return Float32Array.from(output);
  }

  return {collect, positions};
});
