import assert from 'node:assert/strict';
import test from 'node:test';
import { createCuaApi } from './open-computer-use-repl.mjs';

function fixture() {
  const requests = [];
  return { requests, api: createCuaApi({ request: async (_, params) => {
    requests.push(params); return { content: [] };
  } }, () => ({ write() {}, emitImage() {} })) };
}

test('unsupported input options fail before native dispatch', async () => {
  const { api, requests } = fixture();
  const app = await api.getApp('fixture');
  for (const options of [null, [], 1, 'x', { modifiers: ['Command'] }, { durationMs: 100 },
    { [Symbol('unknown')]: true }, Object.assign(Object.create({ modifiers: ['Command'] }), { keyMethod: 'sky_key' })]) {
    await assert.rejects(app.pressKey('s', options), /OCU_(INVALID_OPTIONS|UNSUPPORTED_OPTION)/);
    await assert.rejects(app.typeText('private text', options), /OCU_(INVALID_OPTIONS|UNSUPPORTED_OPTION)/);
    await assert.rejects(app.click(1, options), /OCU_(INVALID_OPTIONS|UNSUPPORTED_OPTION)/);
  }
  await assert.rejects(app.pressKey('s', { modifiers: ['Command'] }), /pressKey\("super\+s"\).*No input was sent/);
  for (const options of [{ mouseButton: 'r' }, { mouseButton: 'oops' }, { clickCount: 0 }, { clickCount: 1.5 },
    { clickCount: Infinity }, { button: 'right' }, { key: 'ctrl' }, { clickMethod: 'sky_click', mouseButton: 'right', clickCount: 2 }]) {
    await assert.rejects(app.click(1, options));
  }
  await assert.rejects(app.pressKey('s', { keyMethod: 'global' }));
  assert.equal(requests.length, 1);
});

test('right button and whole keyboard chords survive the adapter unchanged', async () => {
  const { api, requests } = fixture();
  const app = await api.getApp('fixture');
  await app.click(7, { mouseButton: 'right' });
  await app.click([20, 30], { mouseButton: 'right', clickMethod: 'sky_click' });
  await app.pressKey('super+s', { keyMethod: 'sky_key' });
  await app.pressKey('super+shift+s');
  assert.deepEqual(requests.slice(1).map(r => r.arguments), [
    { app: 'fixture', element_index: 7, mouse_button: 'right' },
    { app: 'fixture', x: 20, y: 30, mouse_button: 'right', click_method: 'sky_click' },
    { app: 'fixture', key: 'super+s', key_method: 'sky_key' },
    { app: 'fixture', key: 'super+shift+s' },
  ]);
});
