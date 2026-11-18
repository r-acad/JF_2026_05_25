/* Portable FEM results retain their original solver buffers and recovery data. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WingStudyResults = api;
})(globalThis, function () {
  'use strict';

  const originals = new WeakMap();
  const FORMAT = 'wingfegen-study-checkpoint-1';

  function remember(record, payload, envelope) {
    originals.set(record, {payload, envelope});
    return record;
  }

  function original(record) {
    const source = originals.get(record);
    if (!source) throw Error('The original FEM recovery data is unavailable. Reload the analysis results before saving this Study.');
    return source;
  }

  function wireResults(cases, {loadCaseIndependent = false} = {}) {
    const loadCases = [];
    let envelope;
    for (const [id, record] of cases || []) {
      if (record.variants?.size) {
        const variants = [];
        let first;
        for (const [variantId, variant] of record.variants) {
          const source = original(variant);
          first ||= source;
          variants.push({...source.payload, id: variantId});
        }
        envelope ||= first.envelope;
        loadCases.push({...first.payload, id: Number(id), variants, default_variant: record.defaultVariant});
      } else {
        const source = original(record);
        envelope ||= source.envelope;
        loadCases.push({...source.payload, id: Number(id)});
      }
    }
    if (!loadCases.length) throw Error('There are no FEM results to save with this Study.');
    return {...envelope, load_cases: loadCases, load_case_independent: loadCaseIndependent};
  }

  function normalize(checkpoint) {
    if (checkpoint === undefined || checkpoint === null) return undefined;
    if (typeof checkpoint !== 'object' || checkpoint.format !== FORMAT ||
        checkpoint.encoding !== 'msgpack+gzip+base64' ||
        typeof checkpoint.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(checkpoint.sha256) ||
        typeof checkpoint.data_base64 !== 'string' || !checkpoint.data_base64.length ||
        checkpoint.data_base64.length % 4 !== 0 ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(checkpoint.data_base64)) {
      throw Error('The saved FEM-results checkpoint is invalid or uses an unsupported format.');
    }
    return checkpoint;
  }

  return {FORMAT, remember, wireResults, normalize};
});
