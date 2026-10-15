// node --test APPS/JFEM-Boxer/test/http_error_test.cjs
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.resolve(__dirname, '../web/app.js'), 'utf8');
const start = source.indexOf('async function readError(res) {');
const end = source.indexOf('\nfunction setBusy(', start);
assert(start >= 0 && end > start, 'readError implementation is present');
const readError = vm.runInNewContext(source.slice(start, end) + '\nreadError');
const response = value => new Response(JSON.stringify(value), {status: 400});

test('preserves ordinary error text and consumes a real response only once', async () => {
  const res = response({ok: false, error: 'The solver produced no result file.'});
  assert.equal(await readError(res), 'The solver produced no result file.');
  assert.equal(res.bodyUsed, true);
});
test('retains nested messages, structured detail, causes and error codes', async () => {
  const detail = await readError(response({error: {message: 'Worker stopped', detail: {pid: 42, exit_code: 7}, code: 'WORKER_EXIT'}, message: 'Analysis failed', details: ['Case 2', {cause: 'Pipe closed'}], code: 'SOLVER'}));
  for (const expected of ['Worker stopped', '"pid": 42', '"exit_code": 7', 'Code: WORKER_EXIT', 'Analysis failed', 'Case 2', 'Pipe closed', 'Code: SOLVER']) assert(detail.includes(expected), expected);
  assert(!detail.includes('[object Object]'));
});
test('handles message-only, JSON string, arrays and unfamiliar objects', async () => {
  assert.equal(await readError(response({message: 'Invalid input'})), 'Invalid input');
  assert.equal(await readError(response('Readable JSON string')), 'Readable JSON string');
  assert.equal(await readError(response({error: [{message: 'First'}, {detail: 'Second'}]})), 'First\nSecond');
  assert.match(await readError(response({validation: {field: 'density', valid: false}})), /"field": "density"/);
});
test('keeps plain-text HTTP failures instead of discarding the body', async () => {
  assert.equal(await readError(new Response('Reverse proxy: worker connection closed.', {status: 502})), 'Reverse proxy: worker connection closed.');
});
test('bounds long plain and structured error details', async () => {
  for (const res of [new Response('x'.repeat(100000), {status: 500}), response({error: {message: 'x'.repeat(20000), code: 'LONG'}})]) {
    const message = await readError(res);
    assert(message.length <= 8192);
    assert.match(message, /response detail truncated/);
  }
});
test('uses status for empty, null or unreadable bodies', async () => {
  assert.equal(await readError(new Response('  ', {status: 503, statusText: 'Service Unavailable'})), 'HTTP 503 Service Unavailable');
  assert.equal(await readError(response(null)), 'HTTP 400');
  assert.equal(await readError({status: 502, text: async () => {throw Error('body stream closed');}}), 'HTTP 502');
  assert.equal(await readError({text: async () => ''}), 'Request failed');
});
test('supports JSON response adapters and strips nonprinting controls', async () => {
  assert.equal(await readError({status: 400, json: async () => ({error: {message: 'Readable\u0000 message', code: 'E1'}})}), 'Readable message\nCode: E1');
});
