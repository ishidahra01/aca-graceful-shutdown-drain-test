const http = require('node:http');
const os = require('node:os');
const { URL } = require('node:url');
const { setTimeout: sleep } = require('node:timers/promises');

function parseBoolean(value, fallback) {
  if (value === undefined || value === null || value === '') {
    return fallback;
  }

  return ['1', 'true', 'yes', 'on'].includes(String(value).toLowerCase());
}

function parsePositiveInt(value, fallback) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

function createRuntime(options = {}) {
  const env = options.env ?? process.env;
  const hostname = options.hostname ?? os.hostname();
  const port = parsePositiveInt(options.port ?? env.PORT, 8080);
  const drainReadinessOnSigterm = parseBoolean(options.drainReadinessOnSigterm ?? env.DRAIN_READINESS_ON_SIGTERM, true);
  const rejectNewRequestsOnDrain = parseBoolean(options.rejectNewRequestsOnDrain ?? env.REJECT_NEW_REQUESTS_ON_DRAIN, true);
  const shutdownPollIntervalMs = parsePositiveInt(options.shutdownPollIntervalMs ?? env.SHUTDOWN_POLL_INTERVAL_MS, 250);
  const exitOnIdleAfterSignal = parseBoolean(options.exitOnIdleAfterSignal ?? env.EXIT_ON_IDLE_AFTER_SIGNAL, true);
  const logger = options.logger ?? ((entry) => console.log(JSON.stringify(entry)));

  const state = {
    hostname,
    port,
    startedAt: new Date().toISOString(),
    readiness: true,
    draining: false,
    sigtermAt: null,
    exitAt: null,
    exitRequested: false,
    shutdownStarted: false,
    activeRequests: 0,
    requestsStarted: 0,
    requestsCompleted: 0,
    requestsRejected: 0,
  };

  let server;
  let shutdownTimer;

  function log(event, data = {}) {
    logger({
      timestamp: new Date().toISOString(),
      event,
      replica: hostname,
      pid: process.pid,
      readiness: state.readiness,
      draining: state.draining,
      activeRequests: state.activeRequests,
      ...data,
    });
  }

  function snapshot() {
    return {
      replica: hostname,
      pid: process.pid,
      port: state.port,
      readiness: state.readiness,
      draining: state.draining,
      sigtermAt: state.sigtermAt,
      exitAt: state.exitAt,
      activeRequests: state.activeRequests,
      requestsStarted: state.requestsStarted,
      requestsCompleted: state.requestsCompleted,
      requestsRejected: state.requestsRejected,
      startedAt: state.startedAt,
    };
  }

  function updateReadiness(ready, reason) {
    if (state.readiness == ready) {
      return;
    }

    state.readiness = ready;
    log('readiness.changed', { ready, reason });
  }

  function maybeExitWhenIdle(reason) {
    if (!exitOnIdleAfterSignal || state.activeRequests > 0 || state.exitRequested) {
      return;
    }

    state.exitRequested = true;
    state.exitAt = new Date().toISOString();
    log('shutdown.exit', { reason });

    if (server) {
      server.close(() => {
        process.exitCode = 0;
        process.exit(0);
      });
      return;
    }

    process.exitCode = 0;
    process.exit(0);
  }

  function monitorShutdown() {
    if (shutdownTimer) {
      return;
    }

    shutdownTimer = setInterval(() => {
      log('shutdown.waiting', { pendingRequests: state.activeRequests });
      if (state.activeRequests === 0) {
        clearInterval(shutdownTimer);
        shutdownTimer = undefined;
        maybeExitWhenIdle('all-requests-finished');
      }
    }, shutdownPollIntervalMs);

    if (typeof shutdownTimer.unref === 'function') {
      shutdownTimer.unref();
    }
  }

  async function handleWorkRequest(req, res, durationSeconds) {
    const requestId = req.headers['x-request-id'] || `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
    const startedAt = Date.now();

    state.requestsStarted += 1;
    state.activeRequests += 1;

    log('request.start', {
      requestId,
      method: req.method,
      path: req.url,
      durationSeconds,
      activeRequestsAfterIncrement: state.activeRequests,
    });

    try {
      await sleep(durationSeconds * 1000);
      const responseBody = {
        ok: true,
        requestId,
        durationSeconds,
        ...snapshot(),
      };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(responseBody));
    } finally {
      state.activeRequests -= 1;
      state.requestsCompleted += 1;

      log('request.end', {
        requestId,
        method: req.method,
        path: req.url,
        durationSeconds,
        elapsedMs: Date.now() - startedAt,
        activeRequestsAfterDecrement: state.activeRequests,
      });

      if (state.shutdownStarted && state.activeRequests === 0) {
        maybeExitWhenIdle('all-requests-finished');
      }
    }
  }

  async function requestListener(req, res) {
    const requestUrl = new URL(req.url, `http://${req.headers.host || `127.0.0.1:${state.port}`}`);
    const pathname = requestUrl.pathname;

    if (pathname === '/health/live') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: 'live', ...snapshot() }));
      return;
    }

    if (pathname === '/health/ready') {
      const statusCode = state.readiness ? 200 : 503;
      res.writeHead(statusCode, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ status: state.readiness ? 'ready' : 'not-ready', ...snapshot() }));
      return;
    }

    if (state.draining && rejectNewRequestsOnDrain) {
      state.requestsRejected += 1;
      log('request.rejected', {
        method: req.method,
        path: req.url,
        reason: 'draining',
      });
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, reason: 'draining', ...snapshot() }));
      return;
    }

    if (pathname === '/' || pathname === '/work') {
      const durationSeconds = parsePositiveInt(requestUrl.searchParams.get('duration'), pathname === '/' ? 0 : 10);
      await handleWorkRequest(req, res, durationSeconds);
      return;
    }

    if (pathname === '/state') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(snapshot()));
      return;
    }

    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'not-found', path: pathname }));
  }

  function beginShutdown(signal = 'SIGTERM') {
    if (state.shutdownStarted) {
      return;
    }

    state.shutdownStarted = true;
    state.draining = true;
    state.sigtermAt = new Date().toISOString();

    log('shutdown.signal', {
      signal,
      drainReadinessOnSigterm,
      rejectNewRequestsOnDrain,
    });

    if (drainReadinessOnSigterm) {
      updateReadiness(false, signal);
    } else {
      log('readiness.unchanged', { reason: 'drain disabled by configuration' });
    }

    if (state.activeRequests === 0) {
      maybeExitWhenIdle('no-active-requests');
      return;
    }

    monitorShutdown();
  }

  function listen(listenPort = port, listenHost = '0.0.0.0') {
    server = http.createServer((req, res) => {
      requestListener(req, res).catch((error) => {
        log('request.error', { message: error.message, stack: error.stack });
        if (!res.headersSent) {
          res.writeHead(500, { 'content-type': 'application/json' });
        }
        res.end(JSON.stringify({ ok: false, error: 'internal-error' }));
      });
    });

    return new Promise((resolve) => {
      server.listen(listenPort, listenHost, () => {
        const address = server.address();
        state.port = typeof address === 'object' && address ? address.port : listenPort;
        log('server.started', { port: state.port, host: listenHost });
        resolve(server);
      });
    });
  }

  function close() {
    return new Promise((resolve, reject) => {
      if (!server) {
        resolve();
        return;
      }

      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }

  return {
    state,
    snapshot,
    listen,
    close,
    beginShutdown,
    requestListener,
  };
}

async function main() {
  const runtime = createRuntime();
  process.on('SIGTERM', () => runtime.beginShutdown('SIGTERM'));
  process.on('SIGINT', () => runtime.beginShutdown('SIGINT'));
  await runtime.listen();
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = {
  createRuntime,
  parseBoolean,
  parsePositiveInt,
};
