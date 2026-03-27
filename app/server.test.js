const test = require('node:test');
const assert = require('node:assert/strict');
const { createRuntime } = require('./server');

async function startRuntime(options = {}) {
  const runtime = createRuntime({
    exitOnIdleAfterSignal: false,
    ...options,
  });

  await runtime.listen(0, '127.0.0.1');
  const state = runtime.snapshot();
  const baseUrl = `http://127.0.0.1:${state.port}`;

  return { runtime, baseUrl };
}

test('SIGTERM readiness drain flips readiness and rejects new work while allowing inflight work to finish', async () => {
  const events = [];
  const { runtime, baseUrl } = await startRuntime({
    drainReadinessOnSigterm: true,
    rejectNewRequestsOnDrain: true,
    logger: (entry) => events.push(entry),
  });

  try {
    const longRunning = fetch(`${baseUrl}/work?duration=1`);
    await new Promise((resolve) => setTimeout(resolve, 100));

    runtime.beginShutdown('TEST');

    const readinessResponse = await fetch(`${baseUrl}/health/ready`);
    assert.equal(readinessResponse.status, 503);

    const rejectedResponse = await fetch(`${baseUrl}/work?duration=0`);
    assert.equal(rejectedResponse.status, 503);

    const completedResponse = await longRunning;
    assert.equal(completedResponse.status, 200);
    const completedBody = await completedResponse.json();
    assert.equal(completedBody.durationSeconds, 1);

    const readinessChange = events.find((entry) => entry.event === 'readiness.changed');
    assert.ok(readinessChange);
    assert.equal(readinessChange.ready, false);
  } finally {
    await runtime.close();
  }
});

test('Pattern A can keep readiness healthy when readiness drain is disabled', async () => {
  const { runtime, baseUrl } = await startRuntime({
    drainReadinessOnSigterm: false,
    rejectNewRequestsOnDrain: false,
    logger: () => {},
  });

  try {
    runtime.beginShutdown('TEST');

    const readinessResponse = await fetch(`${baseUrl}/health/ready`);
    assert.equal(readinessResponse.status, 200);

    const workResponse = await fetch(`${baseUrl}/work?duration=0`);
    assert.equal(workResponse.status, 200);
  } finally {
    await runtime.close();
  }
});
