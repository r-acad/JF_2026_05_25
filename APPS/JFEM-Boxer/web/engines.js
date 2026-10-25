(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WingEngines = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const KEY = 'engines.items';
  const defaults = { name: 'Engine 1', enabled: true, x: 0, y: 1, z: -1,
    mass: 1000, length: 3, E: 70e9, G: 26e9, A: 0.01, I1: 1e-4, I2: 1e-4, J: 2e-4,
    front_rib: 2, aft_rib: 2, aft_xc: 0.55 };
  const HELP = [
    'The engine is a flexible beam aligned with BASIC X, the line-of-flight direction, with two CBAR elements meeting at the centre of gravity. Its midpoint and centre of gravity share the entered BASIC X, Y and Z coordinates in metres. The endpoints are X minus half the length and X plus half the length. These coordinates are independent of the wing planform; they do not move automatically when the wing changes. A newly added engine starts with example values; replace its location, mass, length and stiffness data with the actual installation data.',
    'The engine mass is concentrated once at the centre of gravity. The two elastic beam elements are massless. The CG inertia uses a uniform slender-line estimate: Iyy = Izz = mass times length squared / 12 and Ixx = 0. This inertia estimate does not distribute the mass over the beam elements and does not represent axial spin inertia. Engine mass is independent of the elastic beam area and material density.',
    'Young\'s modulus E and shear modulus G are entered in GPa and saved in Pa. Area A is in square metres; bending inertias I1 and I2 and torsional constant J are in m to the fourth power. Both CBAR halves point along BASIC +X, with local Y along BASIC Y and local Z along BASIC Z. I1 is about Z (bending in XY); I2 is about Y (bending in XZ). These values define the finite axial, bending and torsional stiffnesses EA, EI1, EI2 and GJ. The defaults are illustrative rather than measured engine properties. Both halves share these values; their central node can translate and rotate elastically relative to the mounts.',
    'The front attachment uses the selected physical wing-box rib at its front spar. The aft attachment uses its selected rib and the specified x/c fraction of the complete local aerodynamic chord. Choose a distinct aft location inside the structural box. Both attachments may use the same rib. RBE3 interpolation recovers each mount from a surrounding wing patch. Rigid arms join the mounts to the corresponding engine-beam endpoints, leaving the CG free to respond through the elastic beam. This transfers engine inertia without rigidifying either wing patch. No separate elastic pylon-shell structure is defined.',
    'Rib choices follow the numbered physical ribs shown in the current FEM. After changing the wing or rib layout, Create FEM refreshes those choices; existing engine definitions are preserved for review. Selecting a different rib changes its attachment location, while the engine centre stays at its entered coordinates.',
    'Enabled engines contribute mass and inertia to the FE model. Their inertial loads use each load case\'s acceleration when structural inertia is enabled. Disable an engine to omit it from the FEM without deleting its definition. Engine definitions are saved with the Study. Create FEM and rerun the analysis after making changes.'
  ];

  function normalize(value) {
    if (!Array.isArray(value) || value.length > 100) throw Error('Define at most 100 engines.');
    const names = new Set();
    return value.map((raw, index) => {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw) || Object.keys(raw).some(key => !(key in defaults)))
        throw Error('Engine ' + (index + 1) + ': unknown engine setting.');
      const row = { ...defaults, ...raw };
      if (typeof row.name !== 'string' || !row.name.trim() || [...row.name].length > 80) throw Error('Engine ' + (index + 1) + ': enter a name of 1 to 80 characters.');
      row.name = row.name.trim();
      if (names.has(row.name)) throw Error('Engine names must be distinct: ' + row.name + '.');
      names.add(row.name);
      if (typeof row.enabled !== 'boolean') throw Error(row.name + ': Include in FEM must be on or off.');
      for (const key of ['x', 'y', 'z', 'mass', 'length', 'aft_xc', 'E', 'G', 'A', 'I1', 'I2', 'J'])
        if (typeof row[key] !== 'number' || !Number.isFinite(row[key])) throw Error(row.name + ': enter a finite ' + key + ' value.');
      if (!(row.mass > 0) || !(row.length > 0)) throw Error(row.name + ': engine mass and length must be positive.');
      for (const key of ['E', 'G', 'A', 'I1', 'I2', 'J'])
        if (!(row[key] > 0)) throw Error(row.name + ': beam ' + key + ' must be positive.');
      if (row.aft_xc < 0 || row.aft_xc > 1) throw Error(row.name + ': aft attachment x/c must be between 0 and 1.');
      for (const key of ['front_rib', 'aft_rib'])
        if (!Number.isInteger(row[key]) || row[key] < 1) throw Error(row.name + ': select a positive, whole attachment rib number.');
      return row;
    });
  }

  function canonical(value) {
    return value.map(raw => {
      const row = { ...defaults, ...raw };
      if (typeof row.name === 'string') row.name = row.name.trim();
      return Object.keys(row).sort().map(key => [key, row[key]]);
    });
  }

  function install(host, { onEdit = () => {}, onHelp, readRibs = () => [], isLocked = () => false, createFEM } = {}) {
    const doc = host.ownerDocument, stored = doc.getElementById('p-' + KEY);
    if (!stored) return null;
    const heading = host.querySelector('.parameter-heading h2');
    if (heading) heading.textContent = 'Engine / pylon';
    const make = (tag, cls, text) => {
      const node = doc.createElement(tag);
      if (cls) node.className = cls;
      if (text !== undefined) node.textContent = text;
      return node;
    };
    const editor = make('section', 'engine-editor'), intro = make('p', 'group-note',
      'Define the engine mass, location and flexible beam stiffness, with front and aft attachments to the wing box.'),
      help = make('button', 'mini', '?'), pickerLabel = make('label', 'engine-picker', 'Engine to edit'),
      picker = make('select'), add = make('button', 'mini primary', '+ Add engine'),
      error = make('p', 'engine-error'), status = make('p', 'pick-note'), list = make('div', 'engine-list'),
      footer = make('div', 'engine-actions'), create = make('button', 'mini primary', 'Create FEM');
    editor.id = 'engine-editor'; picker.id = 'engine-edit'; add.id = 'engine-add'; create.id = 'engine-create-fem';
    help.type = add.type = create.type = 'button';
    help.setAttribute('aria-label', 'Help: engine and pylon idealisation'); help.title = HELP.join('\n\n');
    help.onclick = () => onHelp?.({ title: 'Engine and pylon idealisation', paragraphs: HELP });
    picker.setAttribute('aria-label', 'Engine to edit'); picker.dataset.parameterLockExempt = 'true';
    create.dataset.parameterLockExempt = 'true'; create.title = 'Rebuild the complete finite element model with the current engine definitions.';
    error.setAttribute('role', 'alert'); error.hidden = true; status.setAttribute('role', 'status');
    const headingHelp = host.querySelector('.parameter-heading .help-icon');
    if (headingHelp) { headingHelp.title = help.title; headingHelp.onclick = help.onclick; }
    else intro.append(' ', help);
    pickerLabel.append(picker); footer.append(create);
    editor.append(intro, pickerLabel, add, status, error, list, footer); host.append(editor);
    let rows = [], selected = null, initialError = '', destroyed = false;
    const numeric = input => input.value.trim() === '' ? null : Number(input.value);
    const fromDisplay = (key, input) => { const value = numeric(input); return value === null ? null : ['E', 'G'].includes(key) ? Number((value * 1e9).toPrecision(15)) : value; };
    function drafts() {
      return rows.map(row => Object.fromEntries(Object.entries(row.inputs).map(([key, input]) =>
        [key, typeof defaults[key] === 'boolean' ? input.checked : typeof defaults[key] === 'number' ? fromDisplay(key, input) : input.value])));
    }
    function ribs() {
      try { return (readRibs() || []).filter(rib => Number.isInteger(rib.index) && rib.index > 0 && Number.isFinite(rib.eta)); }
      catch (_) { return []; }
    }
    function choose(row) {
      selected = rows.includes(row) ? row : rows[0] || null;
      picker.replaceChildren();
      for (const [index, item] of rows.entries()) {
        const name = item.inputs.name.value.trim() || 'Unnamed engine';
        const option = make('option', '', name + (item.inputs.enabled.checked ? '' : ' (disabled)'));
        option.value = String(index); picker.append(option); item.box.hidden = item !== selected;
      }
      picker.value = selected ? String(rows.indexOf(selected)) : '';
      picker.disabled = !rows.length; pickerLabel.hidden = !rows.length;
    }
    picker.onchange = () => choose(rows[Number(picker.value)]);
    function check() {
      let message = initialError;
      try {
        if (!message) {
          const normalized = normalize(drafts()), available = new Set(ribs().map(rib => rib.index));
          if (available.size) for (const row of normalized.filter(row => row.enabled))
            for (const key of ['front_rib', 'aft_rib'])
              if (!available.has(row[key])) throw Error(row.name + ': selected ' + (key === 'front_rib' ? 'front' : 'aft') + ' attachment R' + row[key] + ' is not in the current FEM. Select an available rib.');
        }
      } catch (exception) { message = exception.message; }
      host.dataset.invalidMessage = message; error.textContent = message; error.hidden = !message;
      return message;
    }
    function sync() {
      initialError = ''; stored.value = JSON.stringify(drafts()); choose(selected); check(); updateStatus(); onEdit(KEY);
    }
    function field(parent, row, key, label, tip) {
      const wrap = make('label', '', label), input = make('input');
      input.type = typeof defaults[key] === 'boolean' ? 'checkbox' : typeof defaults[key] === 'number' ? 'number' : 'text';
      input.dataset.engineField = key; input.setAttribute('aria-label', label); input.title = tip || '';
      if (input.type === 'checkbox') { wrap.className = 'layer'; input.checked = row.value[key]; wrap.prepend(input); }
      else {
        input.value = ['E', 'G'].includes(key) ? row.value[key] / 1e9 : row.value[key];
        input.step = key.endsWith('_rib') || key === 'mass' ? '1' : ['A', 'I1', 'I2', 'J'].includes(key) ? 'any' : '.1';
        if (['mass', 'length', 'E', 'G', 'A', 'I1', 'I2', 'J'].includes(key)) input.min = '0.000000000001';
        if (key.endsWith('_rib')) input.min = '1';
        if (key === 'aft_xc') { input.min = '0'; input.max = '1'; }
        wrap.append(input);
      }
      row.inputs[key] = input; parent.append(wrap);
      input.addEventListener('input', () => { if (!isLocked()) { row.legend.textContent = row.inputs.name.value.trim() || 'Engine'; sync(); updateInertia(row); } });
      return input;
    }
    function updateRibChoices(row, catalog) {
      for (const key of ['front_rib', 'aft_rib']) {
        const select = row.selects[key], value = row.inputs[key].value;
        select.replaceChildren();
        for (const rib of catalog) {
          const option = make('option', '', 'R' + rib.index + ' · eta ' + Number(rib.eta).toPrecision(5));
          option.value = String(rib.index); select.append(option);
        }
        if (!catalog.some(rib => String(rib.index) === value)) {
          const option = make('option', '', 'R' + value + (catalog.length ? ' · unavailable' : ' · awaiting FEM'));
          option.value = value; select.prepend(option);
        }
        select.value = value; select.disabled = isLocked() || !catalog.length;
      }
    }
    function updateInertia(row) {
      const mass = numeric(row.inputs.mass), length = numeric(row.inputs.length), inertia = mass * length * length / 12;
      row.inertia.textContent = mass > 0 && length > 0 && Number.isFinite(inertia)
        ? 'Lumped CG inertia · Ixx = 0; Iyy = Izz = ' + Number(inertia.toPrecision(6)) + ' kg·m² (slender-line estimate).'
        : 'Enter positive mass and length to calculate the engine inertia.';
    }
    function append(value) {
      const box = make('fieldset', 'engine-card'), legend = make('legend', '', value.name), identity = make('div', 'engine-grid'),
        location = make('fieldset', 'engine-fields'), locationTitle = make('legend', '', 'Engine centre / centre of gravity'), locationGrid = make('div', 'engine-grid'),
        beam = make('fieldset', 'engine-fields'), beamTitle = make('legend', '', 'Engine mass and beam length'), beamGrid = make('div', 'engine-grid'),
        stiffness = make('fieldset', 'engine-fields'), stiffnessTitle = make('legend', '', 'Flexible beam stiffness'), stiffnessGrid = make('div', 'engine-grid'),
        attachments = make('fieldset', 'engine-fields'), attachmentTitle = make('legend', '', 'Wing-box attachments'), attachmentGrid = make('div', 'engine-grid'),
        inertia = make('p', 'pick-note'), remove = make('button', 'mini ghost', 'Remove engine');
      const row = { value, box, legend, inputs: {}, selects: {}, inertia, remove }; rows.push(row);
      field(identity, row, 'name', 'Name', 'Distinct engine name used in the model and Study.');
      field(identity, row, 'enabled', 'Include in FEM', 'Off preserves this engine definition but omits its beam, attachments and mass from the FEM.');
      for (const key of ['x', 'y', 'z']) field(locationGrid, row, key, 'BASIC ' + key.toUpperCase() + ' (m)', 'Engine beam midpoint and centre of gravity in the BASIC model coordinate system, in metres. X follows the line of flight; Y is spanwise; Z is normal to the reference planform.');
      field(beamGrid, row, 'mass', 'Engine mass (kg)', 'Complete engine mass concentrated once at the CG. Slender-line inertia is estimated from this mass and the beam length; the elastic beam elements are massless.');
      field(beamGrid, row, 'length', 'Engine length (m)', 'Full beam length along BASIC X, centred at the engine CG and split into two flexible CBAR elements.');
      for (const [key, label, tip] of [
        ['E', 'Young\'s modulus E (GPa)', 'Elastic modulus used for axial and bending stiffness. Saved in Pa. Default 70 GPa is an example; use equivalent engine-beam data.'],
        ['G', 'Shear modulus G (GPa)', 'Shear modulus used for torsional stiffness GJ. Saved in Pa. Default 26 GPa is an example.'],
        ['A', 'Area A (m²)', 'Equivalent beam cross-sectional area for axial stiffness EA. The entered engine mass is independent of this area.'],
        ['I1', 'I1 about Z (m⁴)', 'Equivalent second moment of area about BASIC Z, for bending in the XY plane. Its bending stiffness is E times I1.'],
        ['I2', 'I2 about Y (m⁴)', 'Equivalent second moment of area about BASIC Y, for bending in the XZ plane. Its bending stiffness is E times I2.'],
        ['J', 'Torsional constant J (m⁴)', 'Saint-Venant torsional constant of the equivalent beam section. Torsional stiffness is G times J, independent of its CG mass inertia.']
      ]) field(stiffnessGrid, row, key, label, tip);
      for (const [key, label, tip] of [
        ['front_rib', 'Front attachment rib', 'Front engine attachment at the front spar of this physical main-box rib.'],
        ['aft_rib', 'Aft attachment rib', 'Aft engine attachment on this physical main-box rib; its chordwise position is the separate aft x/c input.']
      ]) {
        const input = field(attachmentGrid, row, key, label, tip), select = make('select'); input.type = 'hidden';
        select.dataset.engineRib = key; select.setAttribute('aria-label', label); select.title = tip; input.parentElement.append(select); row.selects[key] = select;
        select.onchange = () => { if (!isLocked()) { input.value = select.value; sync(); } };
      }
      field(attachmentGrid, row, 'aft_xc', 'Aft attachment x/c', 'Fraction of the complete local aerodynamic chord at the aft rib, measured from the leading edge. It must lie within the structural box, at a location distinct from the front attachment; the mesh generator checks the actual geometry.');
      remove.type = 'button'; remove.onclick = () => { if (isLocked()) return; rows = rows.filter(item => item !== row); box.remove(); sync(); refresh(); };
      location.append(locationTitle, locationGrid); beam.append(beamTitle, beamGrid, inertia); stiffness.append(stiffnessTitle, stiffnessGrid); attachments.append(attachmentTitle, attachmentGrid);
      box.append(legend, identity, location, beam, stiffness, attachments, remove); list.append(box); updateInertia(row); return row;
    }
    function updateStatus() {
      const active = drafts().filter(row => row.enabled), count = active.length;
      status.textContent = (count ? count + ' engine' + (count === 1 ? '' : 's') + ' enabled. ' : 'No engines included in the FEM. ') +
        (ribs().length ? 'Attachment choices use the current numbered physical ribs. ' : 'Create FEM to update the attachment rib choices. ') +
        'Create FEM and rerun the analysis after editing.';
    }
    function refresh() {
      if (destroyed) return;
      const catalog = ribs(), locked = isLocked(); add.disabled = locked;
      for (const row of rows) {
        for (const input of Object.values(row.inputs)) input.disabled = locked;
        row.remove.disabled = locked; updateRibChoices(row, catalog); updateInertia(row);
      }
      choose(selected); check(); updateStatus();
    }
    add.onclick = () => {
      if (isLocked()) return;
      const names = new Set(rows.map(row => row.inputs.name.value.trim())); let index = 1;
      while (names.has('Engine ' + index)) index++;
      const catalog = ribs(), rib = catalog.find(item => item.index === 2) || catalog[0];
      selected = append({ ...defaults, name: 'Engine ' + index, front_rib: rib?.index ?? defaults.front_rib, aft_rib: rib?.index ?? defaults.aft_rib });
      sync(); refresh();
    };
    create.onclick = () => {
      try { const message = check(); if (message) throw Error(message); createFEM?.(); }
      catch (exception) { error.textContent = exception.message; error.hidden = false; }
    };
    try {
      const values = JSON.parse(stored.value || '[]');
      if (!Array.isArray(values)) throw Error('Engine definitions must be a list.');
      if (values.length > 100 || values.some(value => !value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !(key in defaults))))
        throw Error('Engine definitions contain unknown settings or exceed the 100-engine limit.');
      for (const value of values) append({ ...defaults, ...value });
    } catch (exception) { initialError = exception.message; }
    host.addEventListener('parameterlockchange', refresh); refresh();
    return {
      refresh, readDrafts: () => ({ [KEY]: drafts() }),
      assertValidDraft() { const message = check(); if (message) throw Error(message); },
      destroy() { destroyed = true; host.removeEventListener('parameterlockchange', refresh); editor.remove(); }
    };
  }
  return { KEY, defaults, HELP, normalize, canonical, install };
});
