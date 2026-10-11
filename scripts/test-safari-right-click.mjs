#!/usr/bin/env node
// 显式验收当前 Safari 图片页；仅保存唯一命名的测试图片，不导航或覆盖用户文件。
import assert from 'node:assert/strict';
import { existsSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { JsonLinePeer } from './node-repl/open-computer-use-repl.mjs';
const args = new Map(process.argv.slice(2).map(x => x.split(/=(.*)/s).slice(0, 2)));
if (!args.has('--save-test-image') || !args.get('--title')) {
  throw new Error('Usage: node scripts/test-safari-right-click.mjs --save-test-image --title=expected-image-title [--adapter=path] [--point=x,y]');
}
const adapter = args.get('--adapter') ?? 'scripts/node-repl/open-computer-use-repl.mjs';
const { createCuaApi } = await import(pathToFileURL(resolve(adapter)));
const peer = new JsonLinePeer({ command: resolve('.build/debug/OpenComputerUse'), args: ['mcp'], env: {
  ...process.env, OPEN_COMPUTER_USE_EXECUTION_MODE: 'background', OPEN_COMPUTER_USE_COORDINATE_CLICK_MODE: 'background',
  OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: '1', OPEN_COMPUTER_USE_VISUAL_CURSOR: '0', OPEN_COMPUTER_USE_ACTION_READ_BACK: '1',
} });
const evidence = { helperPID: peer.child.pid, adapter, calls: [], states: [] };
const native = { async request(method, params) {
  const result = await peer.request(method, params);
  evidence.calls.push({ tool: params.name, diagnostic: result._meta?.ocuDiagnostic, isError: result.isError === true });
  return result;
} };
const api = createCuaApi(native, () => ({ write() {}, async emitImage() {} }));
const filename = `OCU-right-click-${Date.now()}.jpg`;
const output = join(homedir(), 'Desktop', filename);
function index(state, pattern) {
  const matches = [...state.matchAll(pattern)];
  assert.equal(matches.length, 1, 'Expected one unambiguous observed target');
  return Number(matches[0][1]);
}
try {
  const app = await api.getApp('com.apple.Safari');
  async function observe(stage) {
    const state = await app.getAXState({ emit: false, textLimit: 'max' });
    evidence.states.push({ stage, state });
    return state;
  }
  let state = await observe('before');
  assert.ok(state.includes(args.get('--title')), 'Wrong Safari page');
  if (state.includes('SafariContextMenu')) {
    await app.pressKey('Escape', { keyMethod: 'sky_key' });
    state = await observe('menu-dismissed');
    assert.ok(!state.includes('SafariContextMenu'));
  }
  const count = evidence.calls.length;
  await assert.rejects(app.pressKey('s', { modifiers: ['Command'] }), /OCU_UNSUPPORTED_OPTION/);
  await assert.rejects(app.click(0, { button: 'right' }), /OCU_UNSUPPORTED_OPTION/);
  assert.equal(evidence.calls.length, count, 'Invalid options must send zero native requests');
  let target = index(state, /^\s*(\d+) image\s*$/gm);
  if (args.has('--point')) {
    // 坐标必须来自操作者查看的同一窗口截图；重读后由 native 再验证窗口几何。
    target = args.get('--point').split(',').map(Number);
    assert.ok(target.length === 2 && target.every(Number.isFinite));
  }
  await app.click(target, { mouseButton: 'right', ...(args.has('--method') ? { clickMethod: args.get('--method') } : {}) });
  state = await observe('right-menu');
  assert.ok(state.includes('SafariContextMenu'), 'Right click did not open the menu');
  await app.click(index(state, /^\s*(\d+) menu item Save Image As.*$/gm));
  state = await observe('save-sheet');
  // 某些后台菜单的 AXPress 只选中条目；新观察明确显示选中后，用 Return 完成菜单确认。
  if (!state.includes('save-panel') && /menu item \(selected\) Save Image As/.test(state)) {
    await app.pressKey('Return', { keyMethod: 'sky_key' });
    state = await observe('confirmed-menu');
  }
  assert.ok(state.includes('save-panel'), 'Save sheet did not open');
  assert.match(state, /(?:Where:.*Desktop|Desktop.*where popup)/);
  const nameIndex = index(state, /^\s*(\d+) text field.*saveAsNameTextField.*$/gm);
  assert.ok(!existsSync(output));
  await app.setValue(nameIndex, filename);
  state = await observe('named-save-sheet');
  assert.ok(state.includes(filename));
  await app.click(index(state, /^\s*(\d+) button Save ID: OKButton.*$/gm));
  state = await observe('saved');
  assert.ok(!state.includes('save-panel'), 'Save sheet remains open');
  const deadline = Date.now() + 5000;
  while (!existsSync(output) && Date.now() < deadline) await new Promise(r => setTimeout(r, 100));
  assert.ok(existsSync(output));
  assert.ok(statSync(output).size > 1000);
  evidence.output = { path: output, bytes: statSync(output).size };
  evidence.ok = true;
  console.log(JSON.stringify({ ok: true, helperPID: evidence.helperPID, output: evidence.output, stages: evidence.states.map(x => x.stage) }));
} finally {
  writeFileSync(args.get('--evidence') ?? '/tmp/ocu-right-click-acceptance.json', JSON.stringify(evidence, null, 2), { mode: 0o600 });
  peer.close();
}
