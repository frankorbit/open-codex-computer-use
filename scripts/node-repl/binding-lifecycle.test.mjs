import assert from "node:assert/strict";
import test from "node:test";
import { createCuaApi, PersistentJavaScriptSession, WorkerJavaScriptSession } from "./open-computer-use-repl.mjs";

const frame = { type: "image", mimeType: "image/png", data: "AQID" };
const snapshot = { content: [{ type: "text", text: "fresh window state" }, frame], isError: false };
const failure = message => ({ content: [{ type: "text", text: message }], isError: true });
const initialization = app => ({ name: "get_app_state", arguments: { app, text_limit: "max", initialize: true } });

function fixture(reply = () => snapshot) {
  const calls = [], output = [];
  const native = { async request(method, params) {
    assert.equal(method, "tools/call");
    calls.push(params);
    return reply(params);
  } };
  const api = createCuaApi(native, () => ({
    write: (text, label) => output.push({ text, label }),
    emitImage: image => output.push(image),
  }));
  return { api, native, calls, output };
}

for (const Session of [PersistentJavaScriptSession, WorkerJavaScriptSession]) {
  test(`${Session.name}: getApp emits one initial snapshot and persists a usable binding`, async () => {
    for (const app of ["Text Edit", "com.example.Text"]) {
      const f = fixture();
      const session = new Session({ native: f.native });
      try {
        const result = await session.run(`var bound = await cua.getApp(${JSON.stringify(app)});`);
        assert.equal(result.isError, false);
        assert.deepEqual(f.calls, [initialization(app)]);
        assert.deepEqual(result.content.filter(item => item.type === "image"), [frame]);
        assert.equal(result.content.filter(item => item.text === "fresh window state").length, 1);
        const next = await session.run("await bound.pressKey('Escape'); await bound.getAXState();");
        assert.equal(next.isError, false);
        assert.deepEqual(f.calls.slice(1), [
          { name: "press_key", arguments: { app, key: "Escape" } },
          { name: "get_app_state", arguments: { app, initialize: false } },
        ]);
      } finally {
        await session.close?.();
      }
    }
  });

  test(`${Session.name}: initialization failure preserves errors without binding, fallback or retry`, async () => {
    for (const message of ["Apple event error -10005: cgWindowNotFound", 'appNotFound("fixture")', "Accessibility permission denied", "transport lost"]) {
      const f = fixture(() => {
        if (message === "transport lost") throw new Error(message);
        return { ...failure(message), content: [...failure(message).content, frame] };
      });
      const session = new Session({ native: f.native });
      try {
        const result = await session.run("var bound; bound = await cua.getApp('fixture');");
        assert.equal(result.isError, true);
        assert.ok(result.content.at(-1).text.includes(message));
        assert.doesNotMatch(result.content.at(-1).text, /openApp|explicitly call|Activation\/reopening/);
        assert.equal(result.content.filter(item => item.type === "image").length, 0);
        assert.equal(result.content.filter(item => item.text === "fresh window state").length, 0);
        const checked = await session.run("nodeRepl.write(typeof bound);");
        assert.equal(checked.isError, false);
        assert.equal(checked.content[0].text, "undefined");
        assert.deepEqual(f.calls, [initialization("fixture")]);
      } finally {
        await session.close?.();
      }
    }
  });
}

for (const Session of [PersistentJavaScriptSession, WorkerJavaScriptSession]) {
  test(`${Session.name}: getApp can recover observation after failure without an existing binding`, async () => {
    // 原生回包模拟 pending 期间的观察失败与恢复；不在 JS 重建原生生命周期状态机。
    const unavailable = failure("cgWindowNotFound: initialization observation pending");
    const replies = [unavailable, unavailable, snapshot, snapshot, unavailable, snapshot];
    let replyIndex = 0;
    const f = fixture(() => {
      assert.ok(replyIndex < replies.length, "unexpected automatic native call");
      return replies[replyIndex++];
    });
    const session = new Session({ native: f.native });
    try {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const result = await session.run("var recovered; recovered = await cua.getApp('fixture');");
        assert.equal(result.isError, true);
        assert.ok(result.content.at(-1).text.includes(unavailable.content[0].text));
        assert.equal(result.content.filter(item => item.type === "image").length, 0);
        assert.deepEqual(f.calls, Array.from({ length: attempt + 1 }, () => initialization("fixture")));
        const checked = await session.run("nodeRepl.write(typeof recovered);");
        assert.equal(checked.isError, false);
        assert.equal(checked.content[0].text, "undefined");
        assert.equal(f.calls.length, attempt + 1);
      }

      const recovered = await session.run("recovered = await cua.getApp('fixture');");
      assert.equal(recovered.isError, false);
      assert.deepEqual(f.calls, Array.from({ length: 3 }, () => initialization("fixture")));
      assert.deepEqual(recovered.content.filter(item => item.type === "image"), [frame]);
      assert.equal(recovered.content.filter(item => item.text === "fresh window state").length, 1);
      const observed = await session.run("await recovered.getAXState();");
      assert.equal(observed.isError, false);
      assert.deepEqual(f.calls[3], { name: "get_app_state", arguments: { app: "fixture", initialize: false } });

      // 之后新生命周期仍通过原生 initialize:true；JS 不永久封闭 getApp，也不重放输入。
      const later = await session.run("var nextBinding; nextBinding = await cua.getApp('fixture');");
      assert.equal(later.isError, true);
      assert.equal(f.calls.length, 5);
      const resumed = await session.run("nextBinding = await cua.getApp('fixture');");
      assert.equal(resumed.isError, false);
      assert.deepEqual(f.calls.slice(4), [initialization("fixture"), initialization("fixture")]);
      assert.deepEqual(resumed.content.filter(item => item.type === "image"), [frame]);
      assert.equal(resumed.content.filter(item => item.text === "fresh window state").length, 1);
    } finally {
      await session.close?.();
    }
  });
}

test("all bound observations explicitly disable initialization and preserve options", async () => {
  for (const method of ["getAXState", "getScreenshot", "getAXStateAndScreenshot"]) {
    const f = fixture();
    const app = await f.api.getApp("fixture");
    const before = f.output.length;
    await app[method]({ emit: false, initialize: true, textLimit: "max", maxTreeNodes: 42, maxTreeDepth: 7, windowPlacement: "keep" });
    assert.deepEqual(f.calls, [initialization("fixture"), {
      name: "get_app_state", arguments: {
        app: "fixture", initialize: false, text_limit: method === "getScreenshot" ? 1 : "max",
        max_tree_nodes: 42, max_tree_depth: 7, window_placement: "keep",
      },
    }]);
    assert.equal(f.output.length, before);
    await app[method]();
    assert.deepEqual(f.calls.at(-1), { name: "get_app_state", arguments: {
      app: "fixture", initialize: false, ...(method === "getScreenshot" ? { text_limit: 1 } : {}),
    } });
  }
});

test("native and transport failures remain unchanged for initialization and bound observations", async () => {
  for (const message of ["cgWindowNotFound", 'appNotFound("fixture")', "Accessibility permission denied", "Screen Recording permission required", "transport lost"]) {
    const transportError = new Error(message);
    let fails = false;
    const f = fixture(() => {
      if (!fails) return snapshot;
      if (message === "transport lost") throw transportError;
      return { ...failure(message), content: [...failure(message).content, frame] };
    });
    const app = await f.api.getApp("fixture");
    const before = f.output.length;
    fails = true;
    for (const operation of [() => f.api.getApp("fixture"), ...["getAXState", "getScreenshot", "getAXStateAndScreenshot"].map(method => () => app[method]())]) {
      await assert.rejects(operation, error => {
        assert.equal(error.message, message);
        if (message === "transport lost") assert.equal(error, transportError);
        return true;
      });
    }
    assert.equal(f.output.length, before);
    assert.deepEqual(f.calls.map(call => call.arguments.initialize), [true, true, false, false, false]);
    assert.ok(f.calls.every(call => call.name === "get_app_state"));
  }
});

// 截图可被原生配置省略；有效 AX 状态仍可建立绑定。
test("getApp accepts AX-only state and emits no placeholder image", async () => {
  const f = fixture(() => ({ content: [{ type: "text", text: "Window: Editor. Screenshot omitted by configuration." }] }));
  const app = await f.api.getApp("fixture");
  assert.equal(typeof app.getAXState, "function");
  assert.ok(Object.isFrozen(app));
  assert.deepEqual(f.calls, [initialization("fixture")]);
  assert.equal(f.output.filter(item => item.bytes).length, 0);
  assert.equal(f.output.filter(item => item.label === "cua.state").length, 1);
  await assert.rejects(app.getScreenshot(), /Screenshot unavailable/);
  assert.equal(f.calls.at(-1).arguments.initialize, false);
});

test("public API and initial or rewritten guidance use only getApp for initialization", async () => {
  for (const entry of ["getApp", "getState", "listApps"]) {
    const f = fixture();
    assert.equal("openApp" in f.api, false);
    await f.api[entry]("fixture");
    await f.api.getApp("fixture");
    assert.equal(f.output.filter(item => item.label === "cua.core").length, 1);
    await f.api.rewriteDocumentation();
    const docs = f.output.filter(item => item.label === "cua.core");
    assert.equal(docs.length, 2);
    for (const { text } of docs) {
      assert.match(text, /getApp.*initial text and available images once/);
      assert.match(text, /Only getApp initializes/);
      assert.match(text, /launch once in the background/);
      assert.match(text, /reopen once in the background/);
      assert.match(text, /Bound observation methods never launch or reopen/);
      assert.match(text, /retries only observation/);
      assert.match(text, /native keeps initialization pending/);
      assert.match(text, /call `await cua.getApp\(nameOrBundleID\)` again even if no binding was returned/);
      assert.match(text, /while pending, it only retries observation and cannot launch or reopen/);
      assert.match(text, /Successful observation clears pending; a later new lifecycle may reopen through getApp/);
      assert.match(text, /Preserve errors and never automatically replay prior input/);
      assert.doesNotMatch(text, /use an existing binding|do not automatically repeat initialization/);
      assert.doesNotMatch(text, /openApp|open_app|official/);
    }
  }
});
