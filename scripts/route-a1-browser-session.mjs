import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createConnection } from 'node:net';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';

function validateEnvironment({ locale, timezone }) {
    const [canonical] = Intl.getCanonicalLocales(locale);
    if (!canonical || Intl.DateTimeFormat.supportedLocalesOf([canonical]).length !== 1) {
        throw new Error('unsupported BCP 47 locale');
    }
    new Intl.DateTimeFormat(canonical, { timeZone: timezone });
    return canonical;
}

class DebugConnection {
    constructor(socket, onAttach, onDetach, onFailure) {
        this.socket = socket;
        this.pending = new Map();
        this.nextId = 0;
        this.error = undefined;
        socket.addEventListener('message', ({ data }) => {
            try {
                this.receive(JSON.parse(data), onAttach, onDetach);
            } catch (error) {
                this.fail(error);
                onFailure(error);
            }
        });
        for (const event of ['close', 'error']) {
            socket.addEventListener(event, () => {
                const error = new Error(`CDP WebSocket ${event}`);
                this.fail(error);
                onFailure(error);
            });
        }
    }

    fail(error) {
        this.error = error;
        for (const { reject } of this.pending.values()) reject(error);
        this.pending.clear();
    }

    receive(message, onAttach, onDetach) {
        if (message.method === 'Target.attachedToTarget') onAttach(message.params);
        if (message.method === 'Target.detachedFromTarget') onDetach(message.params);
        const pending = this.pending.get(message.id);
        if (!pending) return;
        this.pending.delete(message.id);
        if (message.error) {
            pending.reject(new Error(`${pending.method}: ${message.error.message}`));
        } else {
            pending.resolve(message.result);
        }
    }

    async send(method, params = {}, sessionId) {
        if (this.error) throw this.error;
        const id = ++this.nextId;
        let timer;
        try {
            return await new Promise((resolve, reject) => {
                timer = setTimeout(() => reject(new Error(`CDP timeout: ${method}`)), 7000);
                this.pending.set(id, { method, resolve, reject });
                this.socket.send(JSON.stringify({ id, method, params, sessionId }));
            });
        } finally {
            clearTimeout(timer);
            this.pending.delete(id);
        }
    }
}

async function connectDebugger(browser) {
    const lines = createInterface({ input: browser.stderr });
    let timer;
    const failed = (message) => new Error(message);
    let socket;
    try {
        const url = await new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(failed('no loopback DevTools address announced')), 8500);
            lines.on('line', (line) => {
                const match = line.match(/^DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[a-f0-9-]+)$/);
                if (match) resolve(match[1]);
                if (!line.startsWith('DevTools listening on')) console.error(line);
                if (line.includes('DevTools remote debugging requires')) reject(failed(line.trim()));
            });
            browser.once('error', reject);
            browser.once('exit', () => reject(failed('browser exited before DevTools opened')));
        });
        socket = new WebSocket(url);
        await new Promise((resolve, reject) => {
            socket.addEventListener('open', resolve, { once: true });
            socket.addEventListener('error', () => reject(failed('loopback DevTools connection failed')),
                { once: true });
            const timeout = setTimeout(() => reject(failed('loopback DevTools connection timed out')), 2500);
            timeout.unref();
        });
        return socket;
    } catch (error) {
        socket?.close();
        throw error;
    } finally {
        clearTimeout(timer);
        lines.close();
        browser.stderr.resume();
    }
}

const autoAttach = {
    autoAttach: true, flatten: true, waitForDebuggerOnStart: true,
    filter: [{ type: 'page' }, { type: 'iframe' }],
};

function flagsFor(config, locale) {
    const flags = [
        `--user-data-dir=${config.profile}`, '--profile-directory=Default',
        `--proxy-server=http://127.0.0.1:${config.port}`,
        '--proxy-bypass-list=<-loopback>',
        '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
        '--disable-quic', '--dns-prefetch-disable',
        '--webrtc-ip-handling-policy=disable_non_proxied_udp',
        '--disable-background-networking', '--disable-component-update',
        '--disable-crash-reporter', '--disable-breakpad', '--disable-domain-reliability',
        '--disable-default-apps', '--disable-extensions', '--disable-sync',
        '--no-first-run', '--no-default-browser-check', '--no-pings',
        '--disable-session-crashed-bubble',
        '--disable-features=MediaRouter,DnsOverHttps,OptimizationHints,Translate,AutofillServerCommunication,NetworkTimeServiceQuerying',
        `--lang=${locale}`, `--accept-lang=${locale}`,
    ];
    if (config.headless) flags.push('--headless=new', '--disable-gpu');
    if (config.cachedTest) flags.push('--no-sandbox');
    if (config.local) flags.push(`--log-net-log=${join(process.cwd(), 'netlog.json')}`);
    return flags;
}

async function readPage(cdp, sessionId, expression) {
    const response = await cdp.send('Runtime.evaluate', {
        expression, returnByValue: true, awaitPromise: true,
    }, sessionId);
    if (response.exceptionDetails) throw new Error('browser JavaScript failed');
    return response.result.value;
}

function canonicalTimezone(timeZone) {
    return new Intl.DateTimeFormat('en', { timeZone }).resolvedOptions().timeZone;
}

async function waitUntil(check, description) {
    for (let attempt = 0; attempt < 60; attempt++) {
        const value = await check();
        if (value) return value;
        await delay(100);
    }
    throw new Error(`timed out waiting for ${description}`);
}

async function smokeTest(cdp, sessionId, config, locale) {
    const go = (url) => cdp.send('Page.navigate', { url }, sessionId);
    const first = await go(config.smoke.page);
    if (first.errorText) throw new Error(first.errorText);
    await waitUntil(() => readPage(cdp, sessionId,
        "document.title === 'A1 mock origin'"), 'mock page');
    const state = await readPage(cdp, sessionId, `(async () => {
        const previous = localStorage.getItem('a1');
        localStorage.setItem('a1', document.querySelector('main').textContent);
        const rtc = new RTCPeerConnection({ iceServers: [] });
        const candidates = [];
        rtc.onicecandidate = ({candidate}) => {
            if (candidate) candidates.push(candidate.candidate);
        };
        rtc.createDataChannel('a1');
        await rtc.setLocalDescription(await rtc.createOffer());
        await Promise.race([
            new Promise(resolve => setTimeout(resolve, 1000)),
            new Promise(resolve => { rtc.onicegatheringstatechange = () => {
                if (rtc.iceGatheringState === 'complete') resolve();
            }; }),
        ]);
        const gathering = rtc.iceGatheringState;
        rtc.close();
        return {
            previous, storage: localStorage.getItem('a1'), locale: navigator.language,
            languages: navigator.languages,
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, candidates, gathering,
        };
    })()`);
    if (state.locale !== locale || canonicalTimezone(state.timezone) !== canonicalTimezone(config.timezone)
        || state.candidates.length) {
        throw new Error(`unexpected browser state: ${JSON.stringify(state)}`);
    }
    const iframeTimezone = await waitUntil(() => readPage(cdp, sessionId, 'window.frameTimezone'),
        'cross-site iframe timezone');
    if (canonicalTimezone(iframeTimezone) !== canonicalTimezone(config.timezone)) {
        throw new Error(`cross-site iframe timezone mismatch: ${iframeTimezone}`);
    }
    state.iframeTimezone = iframeTimezone;
    console.log('SMOKE STATE', JSON.stringify(state));
    const { processInfo } = await cdp.send('SystemInfo.getProcessInfo');
    console.log('SMOKE PIDS', JSON.stringify(processInfo.map(({ id }) => id)));
    await go(config.smoke.cut);
    await waitUntil(() => new Promise((resolve) => {
        const socket = createConnection({ host: '127.0.0.1', port: config.port });
        socket.setTimeout(500);
        socket.once('connect', () => { socket.destroy(); resolve(false); });
        socket.once('timeout', () => { socket.destroy(); resolve(false); });
        socket.once('error', (error) => resolve(error.code === 'ECONNREFUSED'));
    }), 'proxy listener to close');
    const failed = await go(config.smoke.canary);
    if (failed.errorText !== 'net::ERR_PROXY_CONNECTION_FAILED') {
        throw new Error(`unexpected proxy outage result: ${JSON.stringify(failed)}`);
    }
    console.log('SMOKE OUTAGE', failed.errorText);
}

async function session(config, locale) {
    const browser = spawn(config.browser,
        [...flagsFor(config, locale), '--remote-debugging-address=127.0.0.1',
            '--remote-debugging-port=0', '--no-startup-window'], {
        cwd: process.cwd(), env: process.env, windowsHide: config.headless,
        stdio: ['ignore', 'ignore', 'pipe'],
    });
    const exited = once(browser, 'exit').catch(() => []);
    let closing = false;
    let ready = false;
    let unexpected;
    let stop;
    const stopped = new Promise((resolve) => { stop = resolve; });
    const requestStop = () => stop();
    process.on('SIGINT', requestStop);
    process.on('SIGBREAK', requestStop);
    browser.once('exit', stop);
    const attached = new Map();
    const detached = new Set();
    const sessionTargets = new Map();
    const fail = (error) => {
        if (!closing && browser.exitCode === null) {
            unexpected = error;
            stop();
        }
    };
    const attach = async ({ sessionId, targetInfo }) => {
        sessionTargets.set(sessionId, targetInfo.targetId);
        try {
            await cdp.send('Emulation.setTimezoneOverride', { timezoneId: config.timezone }, sessionId);
            // OOPIF sessions attach to their parent target.
            await cdp.send('Target.setAutoAttach', autoAttach, sessionId);
            await cdp.send('Runtime.runIfWaitingForDebugger', {}, sessionId);
            attached.set(targetInfo.targetId, sessionId);
        } catch (error) {
            // Tabs may close while their initial commands are in flight.
            await delay(50);
            if (!detached.has(sessionId)) fail(error);
        } finally {
            detached.delete(sessionId);
        }
    };
    const detach = ({ sessionId }) => {
        const targetId = sessionTargets.get(sessionId);
        if (targetId && !attached.delete(targetId)) detached.add(sessionId);
        sessionTargets.delete(sessionId);
    };
    let cdp;
    try {
        const socket = await connectDebugger(browser);
        cdp = new DebugConnection(socket, attach, detach, (error) => {
            // A normal browser shutdown may close CDP before the process exits.
            setTimeout(() => fail(error), 500).unref();
        });
        const version = await cdp.send('Browser.getVersion');
        await cdp.send('Browser.setDownloadBehavior', { behavior: 'deny' });
        await cdp.send('Target.setAutoAttach', autoAttach);
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const sessionId = await waitUntil(() => {
            if (unexpected) throw unexpected;
            if (cdp.error) throw cdp.error;
            return attached.get(targetId);
        }, 'initial tab attachment');
        const initial = await readPage(cdp, sessionId,
            '({locale: navigator.language, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone})');
        if (initial.locale !== locale ||
            canonicalTimezone(initial.timezone) !== canonicalTimezone(config.timezone)) {
            throw new Error(`initial tab locale/timezone mismatch: ${JSON.stringify(initial)}`);
        }
        ready = true;
        console.log(`BROWSER READY ${browser.pid} ${version.product}`);
        if (config.smoke) {
            await smokeTest(cdp, sessionId, config, locale);
        } else {
            await stopped;
        }
        if (unexpected) throw unexpected;
        if ((browser.exitCode !== null && browser.exitCode !== 0) || browser.signalCode) {
            throw new Error(`browser exited unexpectedly: ${browser.exitCode ?? browser.signalCode}`);
        }
    } finally {
        closing = true;
        process.off('SIGINT', requestStop);
        process.off('SIGBREAK', requestStop);
        if (browser.pid && browser.exitCode === null && browser.signalCode === null) {
            try {
                await cdp?.send('Browser.close');
            } catch {
                // If CDP disconnected, wait briefly before terminating this tree.
            }
            if (!await Promise.race([exited.then(() => true), delay(3000, false)])) {
                browser.kill();
                await exited;
            }
        }
        cdp?.socket.close();
        if (ready) console.log('BROWSER CLOSED', browser.pid);
    }
}

async function diagnostic(config, locale) {
    // Only the local mock diagnostic uses this compatibility flag. The normal
    // launcher preserves Chromium's sandbox.
    const browser = spawn(config.browser, [...flagsFor(config, locale), '--no-sandbox', '--dump-dom',
        config.diagnostic], {
        cwd: process.cwd(), env: process.env, windowsHide: true,
        stdio: ['ignore', 'pipe', 'inherit'],
    });
    const closed = once(browser, 'close');
    let output = '';
    browser.stdout.setEncoding('utf8');
    browser.stdout.on('data', (chunk) => { output += chunk; });
    let timer;
    const stopBrowser = () => browser.kill();
    process.on('SIGBREAK', stopBrowser);
    try {
        const [code] = await Promise.race([closed, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('headless diagnostic timed out')), 18000);
        })]);
        const match = output.match(/<output id="a1-result">([^<]+)<\/output>/);
        if (code !== 0 || !match) throw new Error(`headless diagnostic did not return results (${code})`);
        const result = JSON.parse(match[1]);
        if (result.locale !== locale) {
            throw new Error(`headless diagnostic mismatch: ${JSON.stringify(result)}`);
        }
        console.log('DIAGNOSTIC STATE', JSON.stringify(result));
        console.log('BROWSER CLOSED', browser.pid);
    } finally {
        clearTimeout(timer);
        process.off('SIGBREAK', stopBrowser);
        if (browser.pid && browser.exitCode === null && browser.signalCode === null) {
            stopBrowser();
            await closed;
        }
    }
}

try {
    process.stdin.setEncoding('utf8');
    let input = '';
    for await (const chunk of process.stdin) input += chunk;
    const config = JSON.parse(input);
    const locale = validateEnvironment(config);
    if (process.argv[2] !== '--validate') {
        if (config.diagnostic) await diagnostic(config, locale);
        else await session(config, locale);
    }
} catch (error) {
    console.error('SESSION FAILED:', error.message);
    process.exitCode = 1;
}
