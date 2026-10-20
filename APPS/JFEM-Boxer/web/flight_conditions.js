(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.WingFlightConditions = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";
  // NOAA/NASA U.S. Standard Atmosphere 1976, Part 1 (below 86 km).
  // Keep constants and equations aligned with src/atmosphere.jl.
  const RADIUS = 6356766, R = 8314.32 / 28.9644, G = 9.80665, GAMMA = 1.4;
  const FIELDS = ["atmosphere", "altitude", "altitude_unit", "speed", "speed_unit", "density", "speed_of_sound"];
  const geopotential = z => RADIUS * z / (RADIUS + z);
  const geometric = h => RADIUS * h / (RADIUS - h);
  function number(value, label) {
    if (value === "" || value === null || !Number.isFinite(Number(value))) throw Error(label + " must be a finite number.");
    return Number(value);
  }
  function isa1976(value) {
    const z = number(value, "Altitude");
    if (z < -5000 || z > 86000) throw Error("ISA 1976 supports -5000 to 86000 geometric metres.");
    const h = geopotential(z), heights = [0, 11000, 20000, 32000, 47000, 51000, 71000], lapses = [-.0065, 0, .001, .0028, 0, -.0028, -.002];
    let t = 288.15, pressure = 101325, base = 0;
    for (let i = 0; i < heights.length; i++) {
      const top = i === heights.length - 1 ? h : Math.min(h, heights[i + 1]), lapse = lapses[i], next = t + lapse * (top - base);
      pressure *= lapse === 0 ? Math.exp(-G * (top - base) / (R * t)) : Math.pow(t / next, G / (R * lapse));
      t = next;
      if (h <= top) break;
      base = top;
    }
    let ratio = 1;
    if (z > 80000) {
      const ratios = [1, .999996, .999989, .999971, .999941, .999909, .999870, .999829, .999786, .999741, .999694, .999641, .999579];
      const position = (z - 80000) / 500, lower = Math.min(Math.floor(position), 11), fraction = position - lower;
      ratio = (1 - fraction) * ratios[lower] + fraction * ratios[lower + 1];
    }
    return {model: "isa1976", altitude_geometric_m: z, altitude_geopotential_m: h, pressure_altitude_ft: h / .3048,
      temperature_K: t * ratio, pressure_Pa: pressure, density_kg_m3: pressure / (R * t), speed_of_sound_m_s: Math.sqrt(GAMMA * R * t)};
  }
  function atmosphere(c) {
    if ((c.atmosphere || "manual") === "isa1976") return isa1976(c.altitude ?? 0);
    if (c.atmosphere && c.atmosphere !== "manual") throw Error("Choose ISA 1976 or Manual atmosphere.");
    const density = number(c.density, "Density"), sound = number(c.speed_of_sound, "Speed of sound");
    if (density <= 0 || sound <= 0) throw Error("Density and speed of sound must be greater than zero.");
    return {model: "manual", temperature_K: null, pressure_Pa: null, density_kg_m3: density, speed_of_sound_m_s: sound};
  }
  function condition(c) {
    const air = atmosphere(c), speed = number(c.speed, "True airspeed");
    if (speed <= 0) throw Error("True airspeed must be greater than zero.");
    return {...air, speed_m_s: speed, Mach: speed / air.speed_of_sound_m_s, q_Pa: .5 * air.density_kg_m3 * speed * speed};
  }
  function altitudeToSI(value, unit) {
    const v = number(value, "Altitude");
    if (unit === "m") return v;
    if (unit === "ft") return v * .3048;
    if (unit === "FL") {
      if (v * 30.48 >= RADIUS) throw Error("Flight level is outside the atmosphere model.");
      return geometric(v * 30.48);
    }
    throw Error("Unknown altitude unit.");
  }
  function altitudeFromSI(value, unit) {
    const z = number(value, "Altitude");
    if (unit === "m") return z;
    if (unit === "ft") return z / .3048;
    if (unit === "FL") return geopotential(z) / 30.48;
    throw Error("Unknown altitude unit.");
  }
  function speedToSI(value, unit, sound) {
    const speed = number(value, "True airspeed");
    if (unit === "m/s") return speed;
    if (unit === "knots") return speed * 1852 / 3600;
    if (unit === "Mach") return speed * number(sound, "Speed of sound");
    throw Error("Unknown airspeed unit.");
  }
  function speedFromSI(value, unit, sound) {
    if (unit === "m/s") return number(value, "True airspeed");
    if (unit === "knots") return number(value, "True airspeed") * 3600 / 1852;
    if (unit === "Mach") return number(value, "True airspeed") / number(sound, "Speed of sound");
    throw Error("Unknown airspeed unit.");
  }
  function atmosphereChange(c, patch) {
    const result = {...patch};
    if (c.speed_unit === "Mach") result.speed = number(c.speed, "True airspeed") / atmosphere(c).speed_of_sound_m_s * atmosphere({...c, ...patch}).speed_of_sound_m_s;
    return result;
  }
  function altitudeChange(c, value, unit = c.altitude_unit || "m") {
    return atmosphereChange(c, {altitude: altitudeToSI(value, unit), altitude_unit: unit});
  }
  function modeChange(c, mode) {
    const patch = {atmosphere: mode};
    if (mode === "manual") {
      const air = atmosphere(c); patch.density = air.density_kg_m3; patch.speed_of_sound = air.speed_of_sound_m_s;
    }
    return atmosphereChange(c, patch);
  }
  const display = value => Number(value.toPrecision(12)).toString();
  function mount({host, read, write}) {
    const document = host.ownerDocument, section = document.createElement("section");
    let lastValid = {...read()}, lastMethod = null, warningText = "";
    section.className = "flight-conditions"; section.id = "case-flight-conditions";
    section.setAttribute("aria-label", "Flight condition");
    const heading = document.createElement("h3"); heading.textContent = "Flight condition";
    const disclosure = document.createElement("details"); disclosure.className = "flight-coefficient-settings";
    const disclosureTitle = document.createElement("summary"); disclosureTitle.textContent = "Flight condition for coefficients";
    disclosureTitle.title = "Prescribed lift sets the force directly. These conditions calculate its equivalent aerodynamic coefficients; they do not change the prescribed force.";
    disclosure.append(disclosureTitle);
    const fields = document.createElement("div"); fields.className = "flight-condition-fields";
    const warning = document.createElement("p"); warning.className = "flight-condition-warning";
    warning.id = "case-flight-condition-warning"; warning.setAttribute("role", "status"); warning.setAttribute("aria-live", "polite"); warning.hidden = true;
    section.append(heading, disclosure, fields, warning);
    const makeRow = (key, label, choices) => {
      const row = document.createElement("div"); row.className = "case-field"; row.id = "case-row-" + key;
      const caption = document.createElement("label"); caption.htmlFor = "case-" + key; caption.textContent = label;
      const input = document.createElement(choices ? "select" : "input"); input.id = "case-" + key; input.setAttribute("aria-label", label);
      if (choices) for (const [value, text] of choices) {const option = document.createElement("option"); option.value = value; option.textContent = text; input.append(option);}
      else { input.type = "number"; input.step = "any"; }
      row.append(caption, input); fields.append(row); return {row, input, caption};
    };
    const mode = makeRow("atmosphere", "Atmosphere", [["isa1976", "ISA 1976"], ["manual", "Manual density / sound speed"]]);
    const altitude = makeRow("altitude", "Altitude"), altitudeUnit = makeRow("altitude_unit", "Altitude unit", [["m", "m (geometric)"], ["ft", "ft (geometric)"], ["FL", "Flight level (pressure)"]]);
    altitude.row.title = altitudeUnit.row.title = "Metres and feet are geometric height above sea level. Flight levels are standard pressure altitude in hundreds of feet: FL300 = 30000 pressure feet. ISA geopotential height converts this to geometric height; actual weather can change the geometric height of a pressure surface.";
    const speed = makeRow("speed", "True airspeed"), speedUnit = makeRow("speed_unit", "Airspeed unit", [["m/s", "m/s"], ["knots", "knots (TAS)"], ["Mach", "Mach"]]);
    speed.row.title = speedUnit.row.title = "True airspeed, not IAS/CAS/EAS. Mach uses this case's local speed of sound. Altitude edits retain the entered Mach when Mach is selected; changing a unit preserves the physical value. VLM supports Mach ≤ 0.5.";
    const density = makeRow("density", "Manual air density (kg/m³)"), sound = makeRow("speed_of_sound", "Manual speed of sound (m/s)");
    const summary = document.createElement("output"); summary.id = "case-atmosphere-summary"; summary.setAttribute("aria-live", "polite"); fields.append(summary);
    const help = document.createElement("details"), helpTitle = document.createElement("summary");
    help.className = "form-help"; helpTitle.textContent = "Atmosphere, units and prescribed lift"; help.append(helpTitle);
    const note = document.createElement("p"); note.className = "case-method-note";
    note.textContent = "ISA 1976 uses a dry standard day with no weather correction, from −5 to 86 km geometric altitude. Manual mode uses the entered density and sound speed; altitude does not change them. Prescribed lift uses this condition only for its equivalent aerodynamic coefficients.";
    help.append(note); fields.append(help); host.append(section);
    function refreshWarning() {
      warning.hidden = !warningText || section.dataset.mode !== "coefficients" || disclosure.open;
      warning.textContent = warningText;
    }
    disclosure.addEventListener("toggle", refreshWarning);
    function refreshLayout() {
      const method = read().method || "analytic", coefficients = method !== "vortex_lattice";
      section.dataset.mode = coefficients ? "coefficients" : "vlm";
      heading.hidden = coefficients; disclosure.hidden = !coefficients;
      const parent = coefficients ? disclosure : section;
      if (fields.parentNode !== parent) coefficients ? parent.append(fields) : warning.before(fields);
      if (method !== lastMethod && coefficients) disclosure.open = false;
      lastMethod = method; refreshWarning();
    }
    function refreshSummary() {
      try {
        const c = read(), air = condition(c), isa = air.model === "isa1976";
        lastValid = {...c};
        const f = (value, digits = 6) => Number(value.toPrecision(digits)).toString();
        warningText = c.method === "vortex_lattice" && air.Mach > .5 + Number.EPSILON ? "VLM requires Mach ≤ 0.5; reduce true airspeed." : "";
        summary.classList.toggle("flight-condition-warning", !!warningText);
        summary.textContent = (isa ? "T " + f(air.temperature_K) + " K · p " + f(air.pressure_Pa) + " Pa · " : "Manual: temperature and pressure are unspecified. ") +
          "ρ " + f(air.density_kg_m3) + " kg/m³ · a " + f(air.speed_of_sound_m_s) + " m/s · TAS " + f(air.speed_m_s) + " m/s · Mach " + f(air.Mach) + " · q " + f(air.q_Pa) + " Pa" +
          (isa ? " · geopotential height " + f(air.altitude_geopotential_m) + " m" : "") +
          (warningText ? ". " + warningText : "");
      } catch (error) { warningText = error.message; summary.classList.add("flight-condition-warning"); summary.textContent = error.message; }
      refreshWarning();
    }
    function refresh() {
      const c = read(); mode.input.value = c.atmosphere || "manual"; altitudeUnit.input.value = c.altitude_unit || "m"; speedUnit.input.value = c.speed_unit || "m/s";
      altitude.caption.textContent = altitudeUnit.input.value === "FL" ? "Flight level (FL300 = 30000 pressure ft)" : "Geometric altitude";
      try { altitude.input.value = display(altitudeFromSI(c.altitude ?? 0, altitudeUnit.input.value)); } catch (_) { altitude.input.value = ""; }
      try { speed.input.value = display(speedFromSI(c.speed, speedUnit.input.value, atmosphere(c).speed_of_sound_m_s)); } catch (_) { speed.input.value = ""; }
      density.input.value = c.density ?? ""; sound.input.value = c.speed_of_sound ?? "";
      density.row.hidden = sound.row.hidden = mode.input.value !== "manual";
      refreshLayout(); refreshSummary();
    }
    mode.input.onchange = () => { try {write(modeChange(read(), mode.input.value)); refresh();} catch (error) {warningText = error.message; summary.textContent = error.message; summary.classList.add("flight-condition-warning"); refreshWarning();} };
    altitudeUnit.input.onchange = () => {write({altitude_unit: altitudeUnit.input.value}); refresh();};
    speedUnit.input.onchange = () => {write({speed_unit: speedUnit.input.value}); refresh();};
    speed.input.oninput = () => {
      try { write({speed: speedToSI(speed.input.value, speedUnit.input.value, atmosphere(read()).speed_of_sound_m_s)}); }
      catch (_) { write({speed: ""}); }
      refreshSummary();
    };
    altitude.input.oninput = () => {
      try { write(altitudeChange(lastValid, altitude.input.value, altitudeUnit.input.value)); }
      catch (_) { write({altitude: ""}); }
      refreshSummary();
    };
    for (const [control, key] of [[density, "density"], [sound, "speed_of_sound"]]) control.input.oninput = () => {
      try { const patch = {[key]: number(control.input.value, control.caption.textContent)}; write(key === "speed_of_sound" ? atmosphereChange(lastValid, patch) : patch); }
      catch (_) { write({[key]: ""}); }
      refreshSummary();
    };
    refresh(); return {refresh};
  }
  return {FIELDS, isa1976, atmosphere, condition, geopotential, geometric, altitudeToSI, altitudeFromSI, speedToSI, speedFromSI, atmosphereChange, altitudeChange, modeChange, mount};
});
