import assert from 'node:assert/strict';
import test from 'node:test';
import { createCuaApi } from './open-computer-use-repl.mjs';

function fixture(fail = false) {
  const requests = [];
  const api = createCuaApi({ request: async (_, params) => {
    requests.push(params);
    return params.name === 'paste_text' && fail
      ? { isError: true, content: [{ type: 'text', text: 'paste outcome unknown' }] }
      : { content: [] };
  } }, () => ({ write() {}, emitImage() {} }));
  return { api, requests };
}

test('paste preserves Chinese text and emits exactly one native request', async () => {
  const f = fixture();
  const app = await f.api.getApp('fixture');
  await app.paste('中文 Uber 👩‍💻\nsecond line', { format: 'text' });
  assert.deepEqual(f.requests.at(-1), { name: 'paste_text', arguments: { app: 'fixture', text: '中文 Uber 👩‍💻\nsecond line' } });
  assert.equal(f.requests.length, 2);
});

test('unsupported paste options are rejected before native dispatch', async () => {
  const f = fixture();
  const app = await f.api.getApp('fixture');
  for (const options of [{ format: 'html' }, { format: 'md' }, { keyMethod: 'global' }, null, [], 1]) {
    await assert.rejects(app.paste('text', options), /supports only/);
  }
  await assert.rejects(app.paste({ toString: () => 'text' }), /supports only/);
  assert.equal(f.requests.length, 1);
});

test('unknown paste result is preserved with no automatic fallback or replay', async () => {
  const f = fixture(true);
  const app = await f.api.getApp('fixture');
  await assert.rejects(app.paste('once'), /paste outcome unknown/);
  assert.equal(f.requests.filter(x => x.name === 'paste_text').length, 1);
  assert.equal(f.requests.length, 2);
});
