'use strict';
// Real browser checks for result ownership and optimization completion.
// The HTTP fixture supplies numerical results so this test isolates UI races.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const [outputArg, playwrightModule = 'playwright'] = process.argv.slice(2);
if (!outputArg) throw Error('Pass an evidence directory and optional Playwright module path.');
const output = path.resolve(outputArg);
const web = path.resolve(__dirname, '../web');
const { chromium } = require(playwrightModule);
const origin = 'http://127.0.0.1:43987';
const checks = [];
const errors = [];
const catalog = {
  responses: [
    { id: 'strength:1', label: 'Upper skin strength', case_id: 1, case_label: 'Positive maneuver', rf: 2 },
    { id: 'plate:2', label: 'Lower skin buckling', case_id: 2, case_label: 'Negative maneuver', rf: .8 }
  ],
  variables: [
    { id: 'upper', label: 'P1 upper skin thickness', path: ['skin_upper'], value: .0015, unit: 'm', lower_bound: .0015, upper_bound: .01 },
    { id: 'lower', label: 'P2 lower skin thickness', path: ['skin_lower'], value: .0015, unit: 'm', lower_bound: .0015, upper_bound: .01 }
  ]
};

(async () => {
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe'
  });
  try {
    const context = await browser.newContext({ viewport: { width: 1480, height: 1050 } });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.stack));
    let mode = 'complete';
    let serial = 0;
    let pendingStart;
    let payload;
    const cancelled = [];
    const statusRequests = [];
    await context.route(origin + '/**', async route => {
      const url = new URL(route.request().url());
      if (url.pathname === '/') {
        return route.fulfill({
          contentType: 'text/html; charset=utf-8',
          body: '<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="rf_sensitivity.css"><script src="rf_sensitivity.js"></script><body class="rf-sensitivity-table-page"><main id="host"></main></body>'
        });
      }
      if (url.pathname === '/api/rf_sensitivity/catalog') return route.fulfill({ json: catalog });
      if (url.pathname === '/api/rf_sensitivity/start') {
        payload = route.request().postDataJSON();
        const id = 'job' + (++serial);
        if (mode === 'delay-start') await new Promise(resolve => { pendingStart = resolve; });
        return route.fulfill({ json: { id, status: 'running' } });
      }
      if (url.pathname === '/api/rf_sensitivity/cancel') {
        cancelled.push(route.request().postDataJSON().id);
        return route.fulfill({ json: { ok: true } });
      }
      if (url.pathname === '/api/rf_sensitivity/status') {
        const id = url.searchParams.get('id');
        statusRequests.push(id);
        const log_events = [
          { sequence: 1, message: 'Solving both selected cases.', phase: 'forward' },
          { sequence: 2, message: 'Iteration 1 mass 100 kg, maximum utilization 1.2.', phase: 'optimization', iteration: 1, mass: 100, maximum_utilization: 1.2 }
        ];
        if (cancelled.includes(id)) return route.fulfill({ json: { status: 'cancelled' } });
        return route.fulfill({ json: {
          status: mode === 'hold' ? 'running' : 'completed',
          progress: { detail: mode === 'hold' ? 'Solving selected cases' : 'Complete', log_events }
        } });
      }
      if (url.pathname === '/api/rf_sensitivity/result') {
        const optimize = payload.operation === 'optimize';
        const result = {
          operation: payload.operation,
          quantity: payload.quantity,
          variables: catalog.variables,
          responses: catalog.responses,
          complete: true
        };
        if (optimize) Object.assign(result, {
          converged: true,
          mass: 98,
          optimized_params: { skin_upper: .001796823456, skin_lower: .0015 },
          final_verification: { complete: true, feasible: true, maximum_utilization: .99 },
          history: [
            { iteration: 1, mass: 100, maximum_utilization: 1.2 },
            { iteration: 2, mass: 98, maximum_utilization: .99, constraint_violation: 0 }
          ],
          dimension_updates: catalog.variables.map(variable => ({
            ...variable,
            initial_value: variable.value,
            optimized_value: variable.id === 'upper' ? .001796823456 : .0015
          }))
        });
        else result.jacobian = [[12, -3], [4, 18]];
        return route.fulfill({ json: result });
      }
      const filename = path.join(web, url.pathname.slice(1));
      return fs.existsSync(filename) ? route.fulfill({ path: filename }) : route.fulfill({ status: 404 });
    });
    await page.goto(origin + '/');
    await page.evaluate(() => {
      globalThis.currentParameters = { skin_upper: .0015, skin_lower: .0015 };
      globalThis.uiContext = { ready: true, signature: 'baseline', meshIdentity: 'mesh1', definitionSignature: 'baseline', studyEpoch: 1 };
      globalThis.applied = [];
      globalThis.logMessages = [];
      globalThis.analysisStarts = [];
      globalThis.sharedBusy = false;
      globalThis.applyMode = 'normal';
      globalThis.releaseApply = null;
      globalThis.ui = WingRFSensitivity.install({
        document,
        host: document.getElementById('host'),
        readParams: () => currentParameters,
        readContext: () => uiContext,
        onBusy: value => { sharedBusy = value; },
        onLog: message => logMessages.push(message),
        onAnalysisStart: value => analysisStarts.push(value.operation),
        onApplyDesign: async parameters => {
          if (sharedBusy) throw Error('The application is still busy when applying dimensions.');
          applied.push(parameters);
          currentParameters = { ...parameters };
          uiContext = { ...uiContext, definitionSignature: 'optimized' };
          if (applyMode === 'hold') await new Promise(resolve => { releaseApply = resolve; });
          if (applyMode === 'fail-after-update') {
            const failure = Error('Simulated model refresh failure.');
            failure.optimizedDimensionsApplied = true;
            failure.definitionSignature = 'optimized';
            throw failure;
          }
          uiContext = { ...uiContext, meshIdentity: 'mesh2' };
          return { applied: true, definitionSignature: 'optimized' };
        }
      });
    });
    await page.locator('#rf-sensitivity > summary').click();
    const readCatalog = async () => {
      await page.getByRole('button', { name: 'Read RFs and design variables', exact: true }).click();
      await page.waitForFunction(() => document.querySelector('.rf-sensitivity-status').textContent.includes('Catalog ready'));
    };
    const run = () => page.locator('#rf-sensitivity button.primary').click();
    const waitDone = () => page.waitForFunction(() => !ui.busy && ui.result !== null);
    await readCatalog();
    await page.getByRole('button', { name: 'Select matching RFs', exact: true }).click();
    await page.getByRole('button', { name: 'Select matching variables', exact: true }).click();
    await run();
    await waitDone();
    assert.deepEqual(payload.case_ids, [1, 2]);
    const popupReady = page.waitForEvent('popup');
    await page.getByRole('button', { name: 'Open RF sensitivity table ↗', exact: true }).click();
    const popup = await popupReady;
    await popup.waitForFunction(() => document.querySelectorAll('td[data-available=true]').length === 4);
    mode = 'hold';
    await run();
    await page.waitForFunction(() => ui.busy && ui.result === null);
    assert.equal(await page.getByRole('button', { name: 'Export result JSON', exact: true }).isDisabled(), true);
    await popup.waitForFunction(() => document.querySelectorAll('td[data-available=true]').length === 0);
    checks.push('Starting a run clears prior derivatives in the main panel and detached table immediately.');
    await page.waitForFunction(() => logMessages.includes('Solving both selected cases.'));
    await page.waitForTimeout(1200);
    assert.equal(await page.evaluate(() => logMessages.filter(value => value === 'Solving both selected cases.').length), 2);
    // One occurrence belongs to each run. Repeated polling adds none.
    assert.equal(await page.locator('.rf-sensitivity-history tr').count(), 2);
    checks.push('Retained progress events appear once per run and update live iteration history.');
    await page.evaluate(() => ui.clearResults({ reason: 'New FE analysis started.' }));
    await page.waitForFunction(() => !ui.busy && ui.result === null);
    assert(cancelled.includes('job2'));
    checks.push('An external analysis cancels the superseded RF job and invalidates late callbacks.');

    const operation = page.getByText('Operation', { exact: true }).locator('..').locator('select');
    await operation.selectOption('optimize');
    mode = 'hold';
    await run();
    await page.waitForFunction(() => ui.busy);
    await page.evaluate(() => { uiContext = { ...uiContext, definitionSignature: 'edited during run' }; });
    mode = 'complete';
    await waitDone();
    assert.equal(await page.evaluate(() => applied.length), 0);
    assert.equal(await page.locator('.rf-sensitivity-stale').isVisible(), true);
    checks.push('A completed result for an edited Study does not overwrite the current properties.');

    await readCatalog();
    await run();
    await waitDone();
    assert.equal(await page.evaluate(() => applied.length), 1);
    assert.equal(await page.evaluate(() => currentParameters.skin_upper), .001796823456);
    assert.equal(await page.getByRole('button', { name: 'Optimized dimensions applied', exact: true }).isDisabled(), true);
    assert.equal(await page.locator('.rf-sizing-dimensions tbody tr').count(), 2);
    assert.match(await page.locator('.rf-sizing-dimensions').innerText(), /Before.*Optimized/s);
    assert.equal(await page.locator('.rf-sensitivity-stale').isVisible(), false);
    await popup.waitForFunction(() => document.getElementById('connection-status').textContent.includes('Sizing results'));
    checks.push('Independently verified sizing automatically applies full-precision dimensions after releasing the analysis busy state.');
    checks.push('The sizing table reports each initial and optimized dimension and the applied result remains current.');

    await page.evaluate(() => {
      applyMode = 'fail-after-update';
      currentParameters = { skin_upper: .0015, skin_lower: .0015 };
      uiContext = { ...uiContext, definitionSignature: 'retry baseline', meshIdentity: 'retry mesh' };
    });
    await readCatalog();
    await run();
    await waitDone();
    assert.match(await page.locator('.rf-sensitivity-error').innerText(), /Simulated model refresh failure/);
    const retryApply = page.getByRole('button', { name: 'Apply optimized dimensions', exact: true });
    assert.equal(await retryApply.isDisabled(), false);
    await page.evaluate(() => { applyMode = 'normal'; });
    await retryApply.click();
    await page.waitForFunction(() => !ui.busy && document.querySelector('.rf-sensitivity-status').textContent.includes('color fields are displayed'));
    checks.push('A certified model-refresh failure preserves exact optimized values and permits retry.');

    await page.evaluate(() => { applyMode = 'hold'; });
    await readCatalog();
    await run();
    await page.waitForFunction(() => releaseApply !== null);
    for (const label of ['Operation', 'Strength envelope', 'Maximum sizing iterations', 'Sizing tolerance']) {
      assert.equal(await page.getByText(label, { exact: true }).locator('..').locator('select,input').isDisabled(), true);
    }
    assert.equal(await page.getByRole('button', { name: 'Read RFs and design variables', exact: true }).isDisabled(), true);
    assert.equal(await page.locator('.rf-sensitivity-choice input:enabled').count(), 0);
    await page.evaluate(() => {
      uiContext = { ...uiContext, assessmentSignature: 'changed assessment during model refresh' };
      applyMode = 'normal';
      releaseApply();
      releaseApply = null;
    });
    await waitDone();
    assert.equal(await page.locator('.rf-sensitivity-stale').isVisible(), true);
    assert.equal(await page.getByRole('button', { name: 'Apply optimized dimensions', exact: true }).isDisabled(), true);
    checks.push('Configuration is locked during model refresh, and an external assessment change remains stale.');

    await readCatalog();
    mode = 'delay-start';
    await run();
    while (!pendingStart) await new Promise(resolve => setTimeout(resolve, 10));
    const lateJob = 'job' + serial;
    await page.evaluate(() => ui.clearResults({ reason: 'A newer analysis replaced this run.' }));
    mode = 'complete';
    pendingStart();
    pendingStart = null;
    await page.waitForTimeout(250);
    assert(cancelled.includes(lateJob));
    assert.equal(await page.evaluate(() => ui.result), null);
    assert.equal(await page.evaluate(() => applied.length), 4);
    checks.push('A late start reply is cancelled and cannot restore a previous result or apply old dimensions.');
    await page.screenshot({ path: path.join(output, 'rf_sizing_lifecycle.png'), fullPage: true });
    await page.evaluate(() => ui.destroy());
    await popup.waitForFunction(() => document.getElementById('connection-status').textContent.includes('closed'));
    assert.equal(await popup.locator('td[data-available=true]').count(), 0);
    assert.deepEqual(errors, []);
    await popup.close();
    fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify({ passed: true, checks, errors, statusRequests }, null, 2));
    console.log('PASS RF sizing lifecycle, ' + checks.length + ' browser checks.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
