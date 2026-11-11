'use strict';
// Standalone component with explicit model-operation fixtures. No running Boxer is changed.
// node fe_edit_browser_test.cjs OUT PLAYWRIGHT [CHROME]
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const [outArg, playwrightArg, chromeArg] = process.argv.slice(2), out = path.resolve(outArg), web = path.resolve(__dirname, '../web');
const {chromium} = require(path.resolve(playwrightArg));
(async () => {
  fs.mkdirSync(out, {recursive: true});
  const browser = await chromium.launch({headless: true, ...(chromeArg ? {executablePath: chromeArg} : {})});
  const page = await browser.newPage({viewport: {width: 1450, height: 1100}}), checks = [], errors = [];
  try {
    page.on('pageerror', error => errors.push(error.message));
    await page.setContent('<html><body style="margin:0;background:#0d1622"><main style="display:grid;grid-template-columns:440px minmax(0,1fr);min-height:100vh"><div id="tools" style="padding:14px;min-width:0"></div><div style="padding:40px;color:#aac4df;font:16px sans-serif">3D viewport · planes and candidate nodes are sent through the preview callback.</div></main></body></html>');
    for (const file of ['style.css', 'fe_edit.css']) await page.addStyleTag({path: path.join(web, file)});
    await page.addStyleTag({content: 'html,body{height:auto;overflow:auto}main{height:auto}'});
    await page.addScriptTag({path: path.join(web, 'fe_edit.js')});
    await page.evaluate(() => {
      window.context = {available: false, sourceName: 'fuselage.bdf', unitsLabel: 'source units (millimetres in this example)', modelKey: 'original', initialize: {imported_token: 'selected-source'}};
      window.calls = []; window.commits = []; window.previews = []; window.exports = []; window.failCut = false;
      let revision = 0;
      window.editor = WingFEEdit.install(document.getElementById('tools'), {
        readContext: () => context,
        request: async (action, payload) => {
          calls.push({action, payload});
          if (action === 'cut' && failCut) return {ok: false, error: 'Plane does not cover element 501. Increase the square side length.'};
          if (action === 'preview') return {ok: true, selected_element_ids: [101, 102]};
          if (action === 'parts') return {ok:true,parts:[{id:'left',label:'Left',element_ids:[101]},{id:'right',label:'Right',element_ids:[102]}]};
          if (action === 'candidates') return {ok: true, candidate_groups: Array.from({length: 55}, (_, i) => ({nodes: [i * 2 + 1, i * 2 + 2], retained_node: i * 2 + 1, max_distance: 1e-8}))};
          revision++;
          return {ok: true, session_id: 'editable-copy', revision, ...(action==='cut'?{parts:[{id:'left',label:'Left',element_ids:[101]},{id:'right',label:'Right',element_ids:[102]}]}:{}),source: {name: 'fuselage_edited.bdf', text: 'BEGIN BULK\nGRID,1,,0,0,0\nENDDATA\n'}, summary: {nodes: 110, elements: 80, bounds: {min: [0, -2, -3], max: [10, 2, 3]}, warnings: []}};
        },
        onCommit: (data, action) => {commits.push({revision: data.revision, action}); context.modelKey = 'edited-' + data.revision;},
        onPreview: data => previews.push(data),
        onExport: data => {exports.push({...data, userActivation: navigator.userActivation.isActive}); return {name: data.name};}
      });
    });
    const action = name => page.locator('[data-action="' + name + '"]'), field = name => page.locator('[data-field="' + name + '"]');
    const idle = () => page.waitForFunction(() => !editor.busy);
    assert(await action('initialize').isDisabled()); assert(await action('cut').isDisabled());
    await page.evaluate(() => {context.available = true; editor.refresh();}); await action('initialize').click(); await idle();
    assert.deepEqual(await page.evaluate(() => calls[0]), {action: 'initialize', payload: {imported_token: 'selected-source'}});
    assert.equal(await field('point_x').inputValue(), '5'); assert.equal(await field('side_length').inputValue(), '12');
    assert.equal(await page.locator('[data-role=units]').innerText(), 'source units (millimetres in this example)');
    checks.push('Explicit initialization preserves source-unit labels and positions the first plane at the model bounds centre');
    await field('normal_x').fill('10'); await action('preview').click(); await idle();
    assert.deepEqual(await page.evaluate(() => calls.at(-1).payload.plane.normal), [1, 0, 0]);
    assert.deepEqual(await page.evaluate(() => previews.at(-1).selected_element_ids), [101, 102]);
    await field('normal_x').fill('0'); const beforeInvalid = await page.evaluate(() => calls.length); await action('preview').click();
    await page.waitForFunction(() => document.querySelector('[data-role=message]').dataset.error === 'true');
    assert.equal(await page.evaluate(() => calls.length), beforeInvalid); await action('dismiss').click(); assert(await page.locator('[data-role=message]').isHidden());
    await field('normal_axis').selectOption('x'); await page.evaluate(() => failCut = true); const beforeFailure = await page.evaluate(() => commits.length);
    await action('cut').click(); await idle(); assert.equal(await page.evaluate(() => commits.length), beforeFailure);
    assert((await page.locator('[data-role=message-text]').innerText()).includes('element 501'));
    await page.evaluate(() => failCut = false); await action('cut').click(); await idle();
    assert(await page.locator('[data-role=stale]').isVisible()); assert(await action('undo').isEnabled());
    assert.equal(await page.evaluate(() => calls.at(-1).payload.duplicate_nodes), true);
    checks.push('Normalized previews identify affected elements; invalid inputs and rejected cuts leave the last committed mesh untouched and expose a closeable explanation');
    await field('selection').selectOption('slab'); await field('depth').fill('2'); await action('cut-second').click(); await idle();
    assert.deepEqual(await page.evaluate(() => calls.at(-1).payload.plane.point), [7, 0, 0]);
    await action('clear-part').click();
    await field('movement_mode').selectOption('direction'); await field('move_x').fill('0'); await field('move_y').fill('3'); await field('move_z').fill('4'); await field('distance').fill('-2');
    await field('detach_shared').check(); assert(await page.locator('[data-role=detach-help]').isVisible());
    await action('translate').click(); await idle();
    assert.deepEqual(await page.evaluate(() => calls.at(-1).payload.vector), [0, -1.2, -1.6]);
    assert.equal(await page.evaluate(() => calls.at(-1).payload.selection.kind), 'slab');
    assert.equal(await page.evaluate(() => calls.at(-1).payload.detach_shared), true);
    await page.locator('[data-role=repeat-tools]').evaluate(el=>el.open=true);await field('copy_count').fill('3'); await action('copy').click(); await idle();
    assert.equal(await page.evaluate(() => calls.at(-1).payload.count), 3);
    checks.push('Parallel slice boundaries, signed direction-based movement and repeat-copy counts reach the backend without moving geometry locally');
    await page.locator('[data-role=global-search]').evaluate(el=>el.open=true);await action('candidates').click(); await idle();
    assert.equal(await page.locator('[data-role=candidate-rows] tr').count(), 50); assert(await action('equivalence').isDisabled());
    await page.locator('[data-role=candidate-rows] tr').first().getByRole('button', {name: 'Highlight'}).click();
    assert.deepEqual(await page.evaluate(() => previews.at(-1).candidate_groups[0].nodes), [1, 2]);
    await field('select_all').check(); await action('next').click(); assert.equal(await page.locator('[data-role=candidate-rows] tr').count(), 5);
    assert((await page.locator('[data-role=candidate-count]').innerText()).includes('55 of 55'));
    await page.screenshot({path: path.join(out, 'fe-edit-node-candidates.png'), fullPage: true});
    await action('equivalence').click(); await idle(); assert.equal(await page.evaluate(() => calls.at(-1).payload.groups.length), 55);
    assert(await page.locator('[data-role=candidate-results]').isHidden()); await action('undo').click(); await idle();
    checks.push('Candidate discovery never merges automatically; highlights and explicit selection include paginated groups, and successful joins clear stale candidates');
    await action('export').click(); await idle();
    assert.equal(await page.evaluate(() => exports[0].name), 'fuselage_edited.bdf'); assert.equal(await page.evaluate(() => exports[0].userActivation), true);
    assert((await page.evaluate(() => exports[0].deck_text)).endsWith('ENDDATA\n'));
    const snapshot = await page.evaluate(() => editor.snapshot()); await field('point_x').fill('123'); await page.evaluate(saved => editor.restore(saved), snapshot); assert.equal(await field('point_x').inputValue(), '5');
    await page.evaluate(() => {context.modelKey = 'another-study'; editor.refresh();}); assert(await action('cut').isDisabled());
    assert.equal(await page.evaluate(() => editor.session), null); assert.deepEqual(await page.evaluate(() => previews.at(-1)), {clear: true});
    checks.push('Export receives the full cached deck during the click activation; settings restore exactly, while changing Study invalidates the previous editing session');
    await action('initialize').click(); await idle(); await action('preview').click(); await idle();
    await page.screenshot({path: path.join(out, 'fe-edit-wide.png'), fullPage: true});
    await page.setViewportSize({width: 390, height: 900}); await page.evaluate(() => {document.querySelector('main').style.gridTemplateColumns = 'minmax(0,1fr)'; document.querySelector('main>div:nth-child(2)').style.display = 'none';});
    await page.screenshot({path: path.join(out, 'fe-edit-narrow.png'), fullPage: true});
    const overflow = await page.evaluate(() => ({scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth})); assert(overflow.scroll <= overflow.client + 1);
    const missingHelp = await page.evaluate(() => [...document.querySelectorAll('.fe-edit input,.fe-edit select')].filter(input => !input.title && !input.getAttribute('aria-label')).length); assert.equal(missingHelp, 0);
    assert.deepEqual(errors, []); checks.push('Wide and narrow forms fit their containers; all inputs have explanatory tooltips and no browser errors occur');
    fs.writeFileSync(path.join(out, 'fe-edit-summary.json'), JSON.stringify({passed: true, checks, errors}, null, 2)); console.log('FE editing component: ' + checks.length + ' groups passed.');
  } catch (error) {
    fs.writeFileSync(path.join(out, 'fe-edit-failure.json'), JSON.stringify({error: error.stack, checks, errors}, null, 2));
    await page.screenshot({path: path.join(out, 'fe-edit-failure.png'), fullPage: true}).catch(() => {}); throw error;
  } finally {await browser.close();}
})().catch(error => {console.error(error); process.exitCode = 1;});
