'use strict';
// node test/loft_vertical_shift_browser_test.cjs <evidence-dir> <playwright-module>
// Exercise the production Loft editor and its helpers, without a solver or network catalogue.
const fs = require('node:fs'), path = require('node:path'), http = require('node:http'), assert = require('node:assert/strict');
const { chromium } = require(process.argv[3]), out = path.resolve(process.argv[2]), web = path.resolve(__dirname, '../web');
const Loft = require('../web/loft.js');
const kind = 'vertical_shift', scheduleKey = 'loft.vertical_shift_stations', methodKey = 'loft.vertical_shift_interpolation';
const results = [], check = (name, fn) => { fn(); results.push(name); };
const at = (rows, eta, method = 'linear') => Loft.interpolateSchedule(rows, eta, {kind, method});
check('Signed percentages, sorted eta and untouched typed precision', () => {
  const input = [{eta:.9, shift_percent:3.456789}, {eta:.1, shift_percent:-2.345678}];
  assert.deepEqual(Loft.normalizeSchedule(input, kind), input.slice().reverse());
  assert.equal(input[0].eta, .9);
});
check('Empty zero, endpoint clamp, one constant, linear and cosine equations', () => {
  assert.equal(at([], .4), 0);
  assert.equal(at([{eta:.3, shift_percent:-4}], .8), -4);
  const rows = [{eta:.2, shift_percent:-2}, {eta:.8, shift_percent:6}];
  assert.equal(at(rows, 0), -2); assert.equal(at(rows, 1), 6);
  assert.ok(Math.abs(at(rows, .35) - 0) < 1e-12);
  assert.ok(Math.abs(at(rows, .35, 'cosine') - (-2 + 8 * (1 - Math.cos(Math.PI / 4)) / 2)) < 1e-12);
  assert.equal(Loft.interpolateSchedule([], .5, {kind:'thickness'}), null);
});
check('Invalid rows, missing values, duplicate eta and wrong methods are rejected', () => {
  for (const rows of [[{eta:-.1,shift_percent:0}], [{eta:.2}], [{eta:.3,shift_percent:Infinity}], [{eta:.5,shift_percent:1,twist:0}], [{eta:.5,shift_percent:1},{eta:.5+1e-10,shift_percent:2}]]) {
    assert.throws(() => Loft.normalizeSchedule(rows, kind));
  }
  assert.throws(() => at([], .2, 'spline'));
});
(async () => {
  fs.mkdirSync(out, {recursive:true}); const errors = [];
  const server = http.createServer((req, res) => {
    const name = req.url.slice(1);
    if (['loft.js', 'loft.css'].includes(name)) {
      res.setHeader('Content-Type', (name.endsWith('.js') ? 'application/javascript' : 'text/css') + '; charset=utf-8');
      res.end(fs.readFileSync(path.join(web, name))); return;
    }
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.end('<!doctype html><html><head><style>body{font:13px system-ui;background:#13202b;color:#dcebf6;margin:16px}main{width:400px}.row{display:flex;justify-content:space-between;gap:8px;margin:8px 0}input,select,button{font:inherit;min-width:0;padding:5px}button{color:#e2eff8;background:#243b4f;border:1px solid #4b657a;border-radius:4px}.pick-note,.group-note{line-height:1.5;font-size:12px}[hidden]{display:none!important}</style><link rel="stylesheet" href="/loft.css"></head><body><main id="loft"></main><script src="/loft.js"></script></body></html>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({headless:true, ...(process.env.CHROME_PATH ? {executablePath:process.env.CHROME_PATH} : {channel:'chrome'})});
  const page = await browser.newPage({viewport:{width:720,height:1200}}); page.on('pageerror', e => errors.push(e.message));
  try {
    await page.goto('http://127.0.0.1:' + server.address().port);
    await page.evaluate(() => {
      window.edits = []; window.locked = false;
      window.build = function(values = {}) {
        window.editor?.destroy();
        const host = document.getElementById('loft'); host.innerHTML = '<h2>Loft</h2>';
        const field = (key, value, choices, label) => {
          const row = document.createElement('label'); row.id = 'row-' + key; row.className = 'row'; row.textContent = label || key;
          const node = document.createElement(choices ? 'select' : 'input'); node.id = 'p-' + key;
          if (choices) for (const value of choices) { const option = document.createElement('option'); option.value = option.textContent = value; node.append(option); }
          node.value = values[key] ?? value; row.append(node); host.append(row);
        };
        for (const kind of ['thickness','twist','vertical_shift']) {
          field('loft.'+kind+'_stations','[]');
          field('loft.'+kind+'_interpolation','linear',['linear','cosine'],'Interpolation');
        }
        field('planform.twist_tip','6',null,'Tip twist'); field('planform.twist_axis_xc','.25',null,'Twist axis x/c');
        window.editor = WingLoft.install(host, {onEdit:key=>edits.push(key),onHelp:value=>window.help=value,isLocked:()=>locked});
      }; build();
    });
    const shift = page.locator('[data-loft-kind="vertical_shift"]'), rows = shift.locator('.loft-station-row');
    assert.equal(await shift.locator('legend').textContent(), 'Vertical shift');
    assert.match(await shift.locator('.pick-note').textContent(), /no vertical translation/i);
    assert.equal(await page.locator('[id="p-loft.vertical_shift_interpolation"]').isDisabled(), true);
    assert.equal(await page.locator('[data-loft-kind="twist"] [id="row-planform.twist_tip"]').count(), 1);
    results.push('Vertical shift is separate, twist stays grouped, empty shift is visibly zero');
    await page.locator('[data-loft-add="vertical_shift"]').click();
    assert.deepEqual(await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']), [{eta:0,shift_percent:0},{eta:1,shift_percent:0}]);
    assert.equal(await rows.first().getByLabel('Vertical shift (% semi-span)', {exact:true}).getAttribute('step'), '0.1');
    assert.equal(await page.locator('[id="p-planform.twist_tip"]').inputValue(), '6');
    results.push('New shift anchors are zero and never inherit Tip twist');
    await rows.first().locator('input').last().fill('-1.23456789');
    await rows.last().locator('input').last().fill('3.45678901');
    await page.locator('[data-loft-add="vertical_shift"]').click();
    let draft = await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']);
    assert.deepEqual(draft, [{eta:0,shift_percent:-1.23456789},{eta:.5,shift_percent:1.111},{eta:1,shift_percent:3.45678901}]);
    assert.deepEqual(await rows.evaluateAll(rows=>rows.map(row=>Number(row.querySelector('input').value))), [0,.5,1]);
    results.push('Generated values use four significant figures; existing typed precision is preserved and rows sort immediately');
    await page.locator('[id="p-loft.vertical_shift_interpolation"]').selectOption('cosine');
    assert.equal(await page.evaluate(() => edits.includes('loft.vertical_shift_interpolation')), true);
    const middleEta = rows.nth(1).locator('input').first();
    await middleEta.fill('.75'); await middleEta.dispatchEvent('change');
    assert.equal(await middleEta.evaluate(el=>document.activeElement===el), true);
    assert.equal(await rows.nth(1).locator('input').first().inputValue(), '.75');
    const saved = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll('[id^="p-"]')].map(el=>[el.id.slice(2),el.value])));
    await page.evaluate(values=>build(values), saved);
    assert.equal(await page.locator('[id="p-loft.vertical_shift_interpolation"]').inputValue(), 'cosine');
    assert.deepEqual(await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']), JSON.parse(saved[scheduleKey]));
    results.push('Interpolation notifies edits; focused row and exact schedule values survive sorting and rebuilding');
    await rows.nth(1).locator('input').first().fill('0');
    assert.equal(await page.evaluate(() => {try{editor.assertValidDraft();return false;}catch(e){return /distinct/.test(e.message);}}), true);
    assert.match(await shift.locator('[role="alert"]').textContent(), /vertical shift.*distinct/);
    await rows.nth(1).locator('input').first().fill('.75');
    await rows.nth(1).locator('input').last().fill('');
    assert.equal(await page.evaluate(() => {try{editor.assertValidDraft();return false;}catch(e){return /finite vertical shift percentage/.test(e.message);}}), true);
    await rows.nth(1).locator('input').last().fill('1.111');
    await rows.first().getByRole('button',{name:'Remove vertical shift station'}).click();
    assert.equal(await rows.count(), 2);
    assert.equal(await page.evaluate(() => {editor.assertValidDraft();return true;}), true);
    results.push('Duplicate/missing values block generation; removing a shift station is independent of twist');
    await page.evaluate(() => {locked=true;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});
    assert.equal(await page.locator('[data-loft-add="vertical_shift"]').isDisabled(), true);
    assert.equal(await page.locator('[data-loft-clear="vertical_shift"]').isDisabled(), true);
    assert.equal(await rows.first().locator('input').first().isDisabled(), true);
    assert.equal(await page.locator('[id="p-loft.vertical_shift_interpolation"]').isDisabled(), true);
    await page.evaluate(() => {locked=false;document.getElementById('loft').dispatchEvent(new Event('parameterlockchange'));});
    await page.locator('#loft .group-note button').click();
    assert.equal(await page.evaluate(() => help.paragraphs.some(text => text.includes('delta_z(eta)=s*shift_percent(eta)/100') && text.includes('BASIC +Z') && text.includes('after thickness rescaling and twist'))), true);
    results.push('Planform lock covers all shift inputs and help explains units, direction and transformation order');
    await page.locator('#loft').screenshot({path:path.join(out,'loft-vertical-shift.png')});
    await page.evaluate(() => document.getElementById('loft').style.width='300px');
    assert.equal(await shift.evaluate(el=>el.scrollWidth<=el.clientWidth+1), true);
    await page.locator('[data-loft-clear="vertical_shift"]').click();
    assert.deepEqual(await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']), []);
    assert.equal(await page.locator('[id="p-planform.twist_tip"]').inputValue(), '6');
    results.push('Narrow layout fits, and clear resets only the shift schedule');
    await page.evaluate(() => build({'loft.vertical_shift_stations':JSON.stringify([{eta:.987654321,shift_percent:6.5432109},{eta:.123456789,shift_percent:-.7654321}])}));
    await page.locator('[data-loft-add="vertical_shift"]').click();
    draft = await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']);
    assert.equal(draft[1].eta, .5556);
    const expected = Number(at([draft[0],draft[2]], .5556).toPrecision(4));
    assert.equal(draft[1].shift_percent, expected);
    assert.equal(draft[0].eta, .123456789); assert.equal(draft[2].shift_percent, 6.5432109);
    for(let i=0;i<12;i++) await page.locator('[data-loft-add="vertical_shift"]').click();
    draft = await page.evaluate(() => editor.readDrafts()['loft.vertical_shift_stations']);
    assert.equal(draft.length, 15);
    for(let i=1;i<draft.length;i++) assert.ok(draft[i].eta-draft[i-1].eta>=1e-8);
    assert.deepEqual(await rows.evaluateAll(rows=>rows.map(row=>Number(row.querySelector('input').value))), draft.map(row=>row.eta));
    results.push('Rounded eta uses interpolation at the actual rounded position; repeated additions stay distinct and sorted');
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(out,'loft_vertical_shift.json'), JSON.stringify({passed:true,checks:results.length,results,errors,scope:'Production Loft editor in a browser fixture with actual CSS and mouse/keyboard input; no solver required'},null,2));
    console.log(JSON.stringify({passed:true,checks:results.length,results}));
  } catch(error) {
    await page.screenshot({path:path.join(out,'loft-vertical-shift-failure.png'),fullPage:true}); throw error;
  } finally { await browser.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
