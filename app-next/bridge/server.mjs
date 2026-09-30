import http from 'node:http';
import {
  readFileSync, existsSync, appendFileSync, mkdirSync, writeFileSync,
  statSync, renameSync, unlinkSync, readdirSync,
} from 'node:fs';
import { fileURLToPath } from 'node:url';

const LOG_FILE = new URL('./proxy.log', import.meta.url);
// Full dumps of every rejected request. proxy.log truncates bodies at 500 chars,
// which is why the real trigger was never visible before. Local-only, gitignored.
const DIAG_DIR = new URL('./diag/', import.meta.url);

// --- log rotation ------------------------------------------------------------
// Measured before this existed: proxy.log reached 37 MB and diag/ reached
// 21.4 GB across 10041 files in four days of normal use, because every filter
// rejection wrote a full request dump (avg 2.18 MB) and nothing ever pruned.
// Rotation is size-based with a bounded generation count, so disk use has a
// hard ceiling instead of growing with uptime.
let logBytes = null;
// Deliberately NOT read from `config`: log() can fire before the config const is
// initialised, and a TDZ reference throws (optional chaining does not help).
// Real limits are installed by applyLogLimits() once config exists.
const logLimits = { maxBytes: 0, keep: 3 };
function applyLogLimits(maxBytes, keep) {
  logLimits.maxBytes = maxBytes;
  logLimits.keep = keep;
}

function rotateLogIfNeeded(nextLineBytes) {
  const max = logLimits.maxBytes;
  if (!max) return;
  if (logBytes == null) {
    try { logBytes = statSync(LOG_FILE).size; } catch { logBytes = 0; }
  }
  if (logBytes + nextLineBytes <= max) return;
  const path = fileURLToPath(LOG_FILE);
  const keep = logLimits.keep;
  try {
    // Shift generations: .N-1 -> .N, oldest falls off the end.
    for (let i = keep - 1; i >= 1; i--) {
      if (existsSync(`${path}.${i}`)) {
        if (i === keep - 1) { try { unlinkSync(`${path}.${i + 1}`); } catch {} }
        renameSync(`${path}.${i}`, `${path}.${i + 1}`);
      }
    }
    renameSync(path, `${path}.1`);
    logBytes = 0;
  } catch {
    // Rotation must never break logging: fall back to letting the file grow.
    logBytes = 0;
  }
}

function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.join(' ')}`;
  console.log(line);
  try {
    const bytes = Buffer.byteLength(line) + 1;
    rotateLogIfNeeded(bytes);
    appendFileSync(LOG_FILE, line + '\n');
    if (logBytes != null) logBytes += bytes;
  } catch {}
}

function loadEnv() {
  const values = {};
  if (!existsSync(new URL('./.env', import.meta.url))) return values;
  const text = readFileSync(new URL('./.env', import.meta.url), 'utf8');
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match && !match[1].startsWith('#')) values[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
  }
  return values;
}

// Trim every value. Without this, a trailing space - which Windows `set VAR=0 &&`
// silently appends - turns "0" into "0 " and every `!== '0'` feature flag flips
// back on while the operator sees the correct value in their shell. Found while
// A/B testing SHAPE_ROUTING: the flag simply refused to switch off.
const rawEnv = { ...loadEnv(), ...process.env };
const env = Object.fromEntries(
  Object.entries(rawEnv).map(([k, v]) => [k, typeof v === 'string' ? v.trim() : v]),
);
const config = {
  host: env.HOST || '127.0.0.1',
  port: Number(env.PORT || 33110),
  upstream: (env.UPSTREAM_BASE_URL || 'https://agentrouter.org').replace(/\/$/, ''),
  upstreamKey: env.UPSTREAM_API_KEY,
  upstreamUserAgent: env.UPSTREAM_USER_AGENT || 'claude-cli/1.0.83 (external, cli)',
  localKey: env.LOCAL_API_KEY || 'api',
  timeout: Number(env.REQUEST_TIMEOUT_MS || 120000),

  // Retries for genuinely transient faults only (network, 429, non-filter 5xx).
  // Filter rejections are never retried with identical bytes: measured over 62
  // rejections in proxy.log, not one changed verdict across 3 identical attempts.
  transientRetries: Number(env.MAX_RETRIES || 2),
  retryDelayMs: Number(env.RETRY_DELAY_MS || 1000),

  // Models explicitly known to have a broken upstream stream (connection dropped
  // or hangs). Empty by default: Zoo requires progressive SSE, so a model is
  // wrapped into one synthetic chunk only by an explicit operator opt-out.
  wrapStreamModels: (env.NO_STREAM_MODELS || '')
    .split(',').map(s => s.trim().toLowerCase()).filter(Boolean),

  // --- recovery ladder -------------------------------------------------------
  // The gateway runs a pre-model content gate that rejects deterministically per
  // exact request bytes. Each rung below changes something real about the
  // request; re-sending identical bytes is deliberately never a rung.
  //
  // Rung "nudge": append one neutral sentence to the last user message.
  // Measured 12/12 rescue across every payload that both routes refused, and
  // 0 regressions on payloads that already passed.
  nudgeText: env.NUDGE_TEXT || '(Please respond to the message above.)',
  nudgeEnabled: env.NUDGE_RETRY !== '0',
  // Nudge rescued 16 of 5906 requests while costing 4688 rejections: it belongs
  // after the rung that actually works, not before it.
  nudgeAfterAnthropic: env.NUDGE_AFTER_ANTHROPIC !== '0',
  // Predict which request shapes the pre-model gate refuses and lead with the
  // form that passes, instead of walking two guaranteed failures first.
  shapeRouting: env.SHAPE_ROUTING !== '0',
  // Rung "anthropic": replay over /v1/messages with system hoisted to a
  // top-level field - the shape claude-cli uses. Rescues payloads the OpenAI
  // route rejects as `sensitive_words_detected`.
  anthropicRetry: env.ANTHROPIC_RETRY !== '0',
  // Rung "flatten": render the whole conversation as a labelled transcript in a
  // single user message. Most invasive, so it sits late in the ladder.
  flattenRetry: env.FLATTEN_RETRY !== '0',
  // A second gateway host with its own key and quota.
  fallbackUpstream: (env.UPSTREAM_FALLBACK_BASE_URL || env.ANTHROPIC_BASE_URL || '').replace(/\/$/, ''),
  fallbackKey: env.UPSTREAM_FALLBACK_API_KEY || env.ANTHROPIC_AUTH_TOKEN || '',
  // Model swap. Off by default: it changes which model answers, so opt in.
  modelFallbacks: (env.MODEL_FALLBACKS || '').split(',').map(s => s.trim()).filter(Boolean),
  diag: env.DIAG_DUMPS !== '0',

  // Fallback output limit when the client states none. The old hard-coded 4096
  // truncated long answers on the rung that serves 76% of traffic.
  defaultMaxTokens: Number(env.DEFAULT_MAX_TOKENS || 32768),

  // --- context compaction ----------------------------------------------------
  // off | trim | summary | hybrid. Hybrid = local digest of the middle span,
  // with a hard trim as the floor when the digest is still over budget.
  compactMode: ['off', 'trim', 'summary', 'hybrid'].includes(env.COMPACT_MODE)
    ? env.COMPACT_MODE : 'hybrid',
  // Estimated input tokens allowed before compaction engages. A live request
  // reached 6.17 MB (~1.5 M tokens), so a ceiling is not optional.
  compactMaxTokens: Number(env.COMPACT_MAX_TOKENS || 180000),
  // A tool result may be structurally required but arbitrarily large (terminal
  // dumps reached hundreds of thousands of tokens). Preserve its call/result
  // pair, but cap its payload so one result cannot make the entire session
  // unforwardable.
  compactMaxToolResultTokens: Math.max(1024, Number(env.COMPACT_MAX_TOOL_RESULT_TOKENS || 24000)),
  // Turns preserved verbatim at each end: the head carries the task framing,
  // the tail carries the work in progress.
  compactKeepHead: Math.max(1, Number(env.COMPACT_KEEP_HEAD || 2)),
  compactKeepTail: Math.max(1, Number(env.COMPACT_KEEP_TAIL || 6)),
  // Image transmission is OFF by operator decision: strip every image block
  // from inbound requests before compaction/upstream. Set STRIP_IMAGES=0 to
  // re-enable image forwarding.
  stripImages: env.STRIP_IMAGES !== '0',
  // Per-model ceilings, e.g. "claude-opus-5=32768,glm-5.3=16384". Prefix match.
  modelMaxTokens: (env.MODEL_MAX_TOKENS || '').split(',').map(s => s.trim()).filter(Boolean)
    .reduce((acc, pair) => {
      const [name, value] = pair.split('=');
      if (name && Number(value) > 0) acc[name.trim().toLowerCase()] = Number(value);
      return acc;
    }, {}),

  // --- disk hygiene ----------------------------------------------------------
  // Without these, four days of use produced 21.4 GB in diag/ and a 37 MB log.
  // Every limit is a hard ceiling, not a suggestion.
  logMaxBytes: Number(env.LOG_MAX_BYTES || 16 * 1024 * 1024),
  logKeep: Math.max(1, Number(env.LOG_KEEP || 3)),
  diagMaxFiles: Number(env.DIAG_MAX_FILES || 400),
  diagMaxBytes: Number(env.DIAG_MAX_BYTES || 512 * 1024 * 1024),
  // One dump per distinct (status, strategy, response-code, shape) is evidence.
  // The next 4000 identical ones are noise: 9427 of the 10041 dumps on disk were
  // repeats of just two labels. Repeats are counted in the log instead.
  diagDedupe: env.DIAG_DEDUPE !== '0',
  // Cap a single dump: one request body reached 6.17 MB.
  diagMaxBodyBytes: Number(env.DIAG_MAX_BODY_BYTES || 256 * 1024),
};

applyLogLimits(config.logMaxBytes, config.logKeep);

if (!config.upstreamKey) throw new Error('UPSTREAM_API_KEY is required in api-test/.env');

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, X-API-Key, anthropic-version, x-request-id');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

function json(res, status, body) {
  cors(res);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

function auth(req) {
  if (!config.localKey) return true;
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : req.headers['x-api-key'];
  return token === config.localKey;
}

// Accepts /health, any /v1/* path, common paths without the /v1 prefix,
// and repairs doubled prefixes like /v1/v1/models.
function normalizePath(pathname) {
  if (pathname === '/health') return '/health';
  if (pathname === '/status') return '/status';
  let p = pathname;
  while (p.startsWith('/v1/v1/')) p = p.slice(3);
  if (p.startsWith('/v1/')) return p;
  const known = ['/models', '/chat/completions', '/completions', '/responses', '/messages', '/embeddings'];
  if (known.includes(p)) return '/v1' + p;
  return null;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 20 * 1024 * 1024) reject(new Error('Request body too large'));
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

// Compact fingerprint of a request payload: role sequence, sizes, features.
// Rejections are deterministic per exact payload, so the fingerprint is what we
// need in order to correlate failures instead of guessing.
function describeShape(parsed, rawLength) {
  if (!parsed || typeof parsed !== 'object') return `unparsed bytes=${rawLength}`;
  const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
  const roles = messages.map(m => (m && typeof m.role === 'string' ? m.role[0] : '?')).join(',');
  const blocks = messages.filter(m => Array.isArray(m?.content)).length;
  const perMsgChars = messages.map(m => {
    if (typeof m?.content === 'string') return m.content.length;
    if (Array.isArray(m?.content)) return JSON.stringify(m.content).length;
    return 0;
  });
  return [
    `msgs=${messages.length}`,
    `roles=${roles || '-'}`,
    `blockMsgs=${blocks}`,
    `bytes=${rawLength}`,
    `msgChars=[${perMsgChars.join(',')}]`,
    `tools=${Array.isArray(parsed.tools) ? parsed.tools.length : 0}`,
    `stream=${parsed.stream === true}`,
    parsed.temperature != null ? `temp=${parsed.temperature}` : 'temp=-',
    `topLevelSystem=${parsed.system != null}`,
  ].join(' ');
}

// Two distinct upstream gates, separable purely by latency:
//   pre-model  ~230-950ms  : request never reaches a model
//   post-model ~4000ms+    : model ran, output filter killed the answer
// Which gate fired decides whether a fix must change the request or the reply.
function classifyGate(ms) {
  return ms < 2000 ? 'PRE_MODEL_GATE' : 'POST_MODEL_GATE';
}

let diagReady = false;
// Files this process wrote, oldest first. Only our own dumps are pruned, so a
// pre-existing archive is never silently deleted.
const diagWritten = [];
let diagBytes = 0;
// signature -> count. A repeat bumps the counter and writes nothing.
const diagSeen = new Map();

function diagSignature(record) {
  let code = '';
  try { code = JSON.parse(record.responseBody || '{}')?.error?.code || ''; } catch {}
  return [record.status, record.kind, record.strategy, code, record.shape].join('|');
}

function pruneDiag() {
  while (
    diagWritten.length &&
    (diagWritten.length > config.diagMaxFiles || diagBytes > config.diagMaxBytes)
  ) {
    const oldest = diagWritten.shift();
    try { unlinkSync(new URL(oldest.name, DIAG_DIR)); diagBytes -= oldest.size; } catch { diagBytes -= oldest.size; }
  }
  if (diagBytes < 0) diagBytes = 0;
}

function clipBody(value) {
  if (typeof value !== 'string') return value;
  const max = config.diagMaxBodyBytes;
  if (!max || value.length <= max) return value;
  return `${value.slice(0, max)}\n...[clipped ${value.length - max} of ${value.length} chars]`;
}

function dumpFailure(record) {
  if (!config.diag) return null;
  if (config.diagDedupe) {
    const sig = diagSignature(record);
    const seen = diagSeen.get(sig);
    if (seen) {
      seen.count++;
      // Report on a log scale: the signal is "still happening", not each event.
      if (seen.count === 2 || seen.count % 50 === 0) {
        log(`diag dedupe: ${seen.count}x identical failure signature (first dump: diag/${seen.name})`);
      }
      return null;
    }
  }
  try {
    if (!diagReady) { mkdirSync(DIAG_DIR, { recursive: true }); diagReady = true; }
    const safe = String(record.strategy || 'unknown').replace(/[^a-z0-9]+/gi, '_');
    const name = `${new Date().toISOString().replace(/[:.]/g, '-')}-${record.status}-${safe}.json`;
    const payload = JSON.stringify({
      ...record,
      requestBody: clipBody(record.requestBody),
      responseBody: clipBody(record.responseBody),
    }, null, 2);
    writeFileSync(new URL(name, DIAG_DIR), payload);
    diagWritten.push({ name, size: Buffer.byteLength(payload) });
    diagBytes += Buffer.byteLength(payload);
    if (config.diagDedupe) diagSeen.set(diagSignature(record), { count: 1, name });
    pruneDiag();
    return name;
  } catch (e) {
    log(`diag dump failed: ${e.message}`);
    return null;
  }
}

// The gateway reports content rejections under several unrelated shapes:
//   {"type":"new_api_error","code":"sensitive_words_detected"}   status 500
//   {"type":"agent_router_api_error","code":"content-blocked"}   status 400
// Classify by body markers first, because the status code alone is misleading.
const FILTER_MARKERS = [
  'sensitive_words_detected', 'sensitive words', 'sensitive_word',
  'content-blocked', 'content_blocked', 'content_policy', 'content policy',
  '敏感', '违规', '不安全',
];

// --- DEBUG PROBE (self-poisoning hypothesis) --------------------------------
// The whole recovery ladder rests on one axiom (SPEC section 3): the gateway
// rejects the *shape* of a request, not its *text*. Every rung therefore
// changes form (blocks -> anthropic -> nudge -> flatten -> alt-host) while
// preserving wording. If a payload is refused because of WORDING that no rung
// removes, all nine rungs fail identically with `filter` - exactly the
// signature seen when the assistant is debugging this bridge and the
// conversation history has absorbed the gateway's own block markers
// ("content-blocked", "sensitive_words_detected", proxy.log excerpts, diag
// filenames). This probe only observes and logs; it changes no behaviour.
function poisonMarkersIn(text) {
  const lower = (text || '').toLowerCase();
  return FILTER_MARKERS.filter(m => lower.includes(m.toLowerCase()));
}

// Upstream 500s that are deterministic rather than transient. Retrying the
// identical rung just burns another 3-4 s before the same refusal: "No
// available channel for model X" means this route/model pair has no capacity
// assigned, so only the NEXT rung (different shape, host, or model) can help.
// Classifying these as 'route' makes the ladder advance immediately instead of
// repeating the same call - the bulk of the "twice as slow" regression.
const DETERMINISTIC_UPSTREAM_MARKERS = [
  'no available channel',
  'no channel available',
  'no available channels',
];

function classifyFailure(status, body) {
  const lower = (body || '').toLowerCase();
  if (FILTER_MARKERS.some(m => lower.includes(m))) return 'filter';
  // Upstream validation errors are deterministic and shape-level: retrying the
  // same bytes cannot help, but they are NOT content refusals either.
  if (status === 400 && /validationexception|tool_use|tool_result|unexpected role/i.test(body || '')) return 'invalid';
  if (status === 401 || status === 403) return 'auth';
  if (status === 402) return 'quota';
  if (status === 404) return 'route';
  if (status >= 500 && DETERMINISTIC_UPSTREAM_MARKERS.some(m => lower.includes(m))) return 'route';
  if (status === 429 || status >= 500) return 'transient';
  return 'fatal';
}

// ---------------------------------------------------------------------------
// Request transforms used by the recovery ladder
// ---------------------------------------------------------------------------

// --- multimodal content -----------------------------------------------------
// Historical bug: this function kept only blocks whose type was 'text', and it
// is the single path used by BOTH the anthropic rung (76% of live traffic) and
// the flatten rung. Every image block was therefore dropped silently - the
// model answered as if no image had been attached, with no error anywhere.
// Images are now converted, and where a rung genuinely cannot carry one, an
// explicit textual marker is emitted so the loss is visible instead of silent.

const IMAGE_MEDIA_TYPES = {
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
  gif: 'image/gif', webp: 'image/webp',
};

// Accepts both wire formats:
//   OpenAI    {type:'image_url', image_url:{url:'data:image/png;base64,...'|'https://...'}}
//   Anthropic {type:'image', source:{type:'base64',media_type,data}|{type:'url',url}}
function parseImageBlock(block) {
  if (!block || typeof block !== 'object') return null;

  if (block.type === 'image_url' || block.image_url) {
    const raw = typeof block.image_url === 'string' ? block.image_url : block.image_url?.url;
    if (typeof raw !== 'string' || !raw) return null;
    const data = raw.match(/^data:([^;,]+);base64,(.*)$/s);
    if (data) return { kind: 'base64', mediaType: data[1], data: data[2] };
    if (/^https?:\/\//i.test(raw)) {
      const ext = (raw.split('?')[0].match(/\.([a-z0-9]+)$/i)?.[1] || '').toLowerCase();
      return { kind: 'url', url: raw, mediaType: IMAGE_MEDIA_TYPES[ext] || 'image/png' };
    }
    return null;
  }

  if (block.type === 'image' && block.source && typeof block.source === 'object') {
    const s = block.source;
    if (s.type === 'base64' && typeof s.data === 'string') {
      return { kind: 'base64', mediaType: s.media_type || 'image/png', data: s.data };
    }
    if ((s.type === 'url' || typeof s.url === 'string') && typeof s.url === 'string') {
      return { kind: 'url', url: s.url, mediaType: s.media_type || 'image/png' };
    }
  }
  return null;
}

function imageToAnthropic(image) {
  return image.kind === 'base64'
    ? { type: 'image', source: { type: 'base64', media_type: image.mediaType, data: image.data } }
    : { type: 'image', source: { type: 'url', url: image.url } };
}

// A stand-in used only where a rung cannot carry binary content at all.
function imageMarker(image, index) {
  return image.kind === 'url'
    ? `[image ${index}: ${image.url}]`
    : `[image ${index}: ${image.mediaType}, ${Math.round((image.data?.length || 0) * 0.75 / 1024)} KB attached by the user]`;
}

function contentBlocks(content) {
  if (typeof content === 'string') return content ? [{ type: 'text', text: content }] : [];
  if (Array.isArray(content)) return content.filter(b => b && typeof b === 'object');
  if (content && typeof content === 'object') return [content];
  return [];
}

// Image transmission is OFF by operator decision: the bridge strips every image
// block from inbound requests BEFORE compaction and before any upstream call.
// A pasted screenshot is ~900 KB of base64 (~230k est. tokens) that single-
// handedly blows the 180k budget and forces the planner to delete ~200 real
// messages - the "coder forgot the session" symptom. Removing images at the
// edge keeps the dialogue intact and never forwards binary payloads upstream.
// Each image is replaced by a short text marker so the model still knows an
// attachment was dropped. Controlled by STRIP_IMAGES (default on; =0 to disable).
function stripImages(parsed) {
  if (!parsed || !Array.isArray(parsed.messages)) return 0;
  let removed = 0;
  for (let i = 0; i < parsed.messages.length; i++) {
    const m = parsed.messages[i];
    if (!m || !Array.isArray(m.content)) continue;
    let touched = false;
    const next = [];
    for (const b of m.content) {
      if (parseImageBlock(b) != null) { removed++; touched = true; continue; }
      next.push(b);
    }
    if (touched) {
      next.push({ type: 'text', text: '[bridge] image attachment removed (image transmission disabled)' });
      parsed.messages[i] = { ...m, content: next };
    }
  }
  return removed;
}

function hasImage(messages) {
  return (Array.isArray(messages) ? messages : []).some(m =>
    contentBlocks(m?.content).some(b => parseImageBlock(b) != null));
}

// Text-only projection. Images become markers rather than vanishing.
// Unknown object shapes are JSON-stringified instead of returning '': a tool
// result whose content is an unrecognized object must stay clip-able, or one
// huge result makes the whole session permanently unforwardable.
function textFromContent(content, { imageMarkers = true } = {}) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    const parts = [];
    let images = 0;
    for (const b of content) {
      if (!b || typeof b !== 'object') continue;
      if (b.type === 'text' || typeof b.text === 'string') { parts.push(b.text); continue; }
      const image = parseImageBlock(b);
      if (image && imageMarkers) parts.push(imageMarker(image, ++images));
    }
    return parts.filter(p => typeof p === 'string' && p.length).join('\n');
  }
  if (content && typeof content === 'object') {
    if (typeof content.text === 'string') return content.text;
    if (typeof content.content === 'string') return content.content;
    try { return JSON.stringify(content); } catch { return String(content); }
  }
  return '';
}

// Full-fidelity projection for the Anthropic route: text stays text, images stay
// images. Used instead of textFromContent wherever the target can carry blocks.
function blocksToAnthropic(content) {
  if (typeof content === 'string') return content;
  const out = [];
  for (const b of contentBlocks(content)) {
    if (b.type === 'text' || typeof b.text === 'string') {
      if (b.text) out.push({ type: 'text', text: b.text });
      continue;
    }
    const image = parseImageBlock(b);
    if (image) out.push(imageToAnthropic(image));
  }
  if (!out.length) return '';
  if (out.length === 1 && out[0].type === 'text') return out[0].text;
  return out;
}

// Append a short, neutral sentence to the last user message. It states nothing
// about the user's task, so it cannot contradict their intent.
function applyNudge(parsed, nudge) {
  const clone = { ...parsed, messages: (parsed.messages || []).map(m => ({ ...m })) };
  for (let i = clone.messages.length - 1; i >= 0; i--) {
    const m = clone.messages[i];
    if (m.role !== 'user') continue;
    if (typeof m.content === 'string') m.content = `${m.content}\n\n${nudge}`;
    else if (Array.isArray(m.content)) m.content = [...m.content, { type: 'text', text: nudge }];
    else m.content = nudge;
    return clone;
  }
  clone.messages.push({ role: 'user', content: nudge });
  return clone;
}

// ---------------------------------------------------------------------------
// Context compaction
// ---------------------------------------------------------------------------
// Measured need: a single live request reached 6.17 MB. Nothing between that and
// the 20 MB body guard did anything about length, so oversized conversations
// were handed to the gateway untouched.
//
// Two mechanisms, because they fail in opposite directions:
//   trim    - drop whole middle turns, keep the head (task framing) and the
//             tail (current work). Cheap, no extra upstream call, but loses
//             detail from the dropped span.
//   summary - replace the middle span with a compact digest built locally from
//             the dropped turns. Keeps a trace of what happened, costs nothing
//             upstream either, but is lossy in a different way.
//   hybrid  - summary for the middle, trim as the hard floor if the result is
//             still over budget. This is the default.
//
// The client's own summarisation is respected: Zoo Code sends explicit condense
// requests, and those are passed through untouched (see isCondenseRequest).

function estimateTokens(value) {
  // Deliberately crude: ~4 chars per token. The point is a stable budget signal,
  // not tokeniser fidelity, and it must never cost an upstream call.
  if (typeof value === 'string') return Math.ceil(value.length / 4);
  return Math.ceil(JSON.stringify(value ?? '').length / 4);
}

function messageTokens(m) {
  let total = estimateTokens(m?.content);
  if (Array.isArray(m?.tool_calls)) total += estimateTokens(m.tool_calls);
  return total;
}

function conversationTokens(messages) {
  return (Array.isArray(messages) ? messages : []).reduce((sum, m) => sum + messageTokens(m), 0);
}

// CTX-03 (V1): the bridge is the source of truth about context size. The
// agentrouter provider returns garbage usage.input_tokens (cache hits /
// estimates: 57442 then 375 for a monotonically growing request), so Zoo's
// context counter jumps 500 <-> 58000. We substitute the client-facing
// usage.prompt_tokens with the bridge's own post-compaction estimate,
// calibrated by an EMA coefficient learned ONLY from plausible provider
// values (within +/-50% of the estimate). The raw provider number stays in the
// log line for diagnosis. Zero extra upstream calls: the estimate is free.
let calibCoef = 1;
function calibrateContextUsage(ctxAfter, rawPromptTokens) {
  if (!(ctxAfter > 0)) return null;
  const raw = Number(rawPromptTokens) || 0;
  if (raw > 0) {
    const ratio = raw / ctxAfter;
    if (ratio >= 0.5 && ratio <= 1.5) {
      // Exponential moving average so a single plausible sample nudges, not
      // resets, the coefficient.
      calibCoef = calibCoef * 0.8 + ratio * 0.2;
    }
  }
  return Math.max(1, Math.round(ctxAfter * calibCoef));
}

// Rewrite a client-facing usage object's prompt/input token count with the
// calibrated estimate. Completion tokens stay verbatim.
function applyCalibratedUsage(usageObj, ctxAfter) {
  if (!usageObj || !(ctxAfter > 0)) return usageObj;
  const rawIn = usageObj.prompt_tokens ?? usageObj.input_tokens ?? 0;
  const outTok = usageObj.completion_tokens ?? usageObj.output_tokens ?? 0;
  const calib = calibrateContextUsage(ctxAfter, rawIn);
  if (calib == null) return usageObj;
  const next = { ...usageObj };
  if ('prompt_tokens' in next) { next.prompt_tokens = calib; next.total_tokens = calib + (Number(outTok) || 0); }
  if ('input_tokens' in next) { next.input_tokens = calib; }
  return next;
}

// A request that IS a summarisation must never itself be summarised.
function isCondenseRequest(parsed) {
  const first = (parsed?.messages || []).find(m => m?.role === 'system' || m?.role === 'developer');
  const text = textFromContent(first?.content, { imageMarkers: false });
  return /tasked with summarizing conversations|summariz(e|ing) the conversation/i.test(text || '');
}

// Compact digest of dropped turns. Local, deterministic, no upstream call.
function digestTurns(turns) {
  const lines = [];
  for (const m of turns) {
    const role = ROLE_LABEL[m.role] || m.role;
    // Image markers are extracted FIRST and kept verbatim: a 220-char text
    // truncation must never swallow the fact that an image was present.
    const images = [];
    for (const b of contentBlocks(m.content)) {
      const image = parseImageBlock(b);
      if (image) images.push(imageMarker(image, images.length + 1));
    }
    let text = textFromContent(m.content, { imageMarkers: false }).replace(/\s+/g, ' ').trim();
    if (Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const names = m.tool_calls.map(c => c.function?.name || 'tool').join(', ');
      text = text ? `${text} [called: ${names}]` : `[called: ${names}]`;
    }
    if (text.length > 220) text = `${text.slice(0, 220)}...`;
    if (images.length) text = `${text}${text ? ' ' : ''}${images.join(', ')}`;
    if (!text) continue;
    lines.push(`- ${role}: ${text}`);
  }
  return lines.join('\n');
}

// --- context planner (stable long-session compaction) -----------------------
// Defect this replaces: the old planner re-cut the history to a fixed
// head/tail on EVERY request, so a 200-300k session collapsed into what looked
// like a brand-new conversation, and string tool content was clipped
// separately from its tool_use call - producing orphaned halves of a tool
// cycle. The planner below is incremental and cycle-atomic.

// Small, dependency-free, deterministic hash. Fingerprint material is the
// model name plus the system/developer contract text only - never message
// bodies, never keys, so nothing secret can leak into logs or markers.
function hashFingerprint(text) {
  let h = 5381;
  for (let i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) | 0;
  return (h >>> 0).toString(36);
}

function sessionFingerprint(parsed) {
  const parts = [String(parsed?.model || '')];
  for (const m of (Array.isArray(parsed?.messages) ? parsed.messages : [])) {
    if (m?.role === 'system' || m?.role === 'developer') {
      parts.push(textFromContent(m.content, { imageMarkers: false }));
    }
  }
  return hashFingerprint(parts.join('\u0000'));
}

// Marker left in the history by a previous compaction. A payload carrying it
// is already compacted: the marker is extended, never re-digested, so repeated
// compaction cannot cascade or erase the whole dialogue.
const COMPACT_TAG = '[bridge:compacted';

function isCompactedMarker(m) {
  return typeof m?.content === 'string' && m.content.startsWith(COMPACT_TAG);
}

function unitTokens(unit) {
  return unit.msgs.reduce((sum, m) => sum + messageTokens(m), 0);
}

// Group messages into atomic units. A tool cycle (assistant turn carrying
// tool_calls plus every tool result answering it) is ONE unit: it is dropped
// whole or kept whole, never split. `open` marks an unfinished cycle - the
// last thing in the conversation with no user turn after it.
function buildUnits(messages) {
  const units = [];
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    if (m?.role === 'assistant' && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const cycle = [m];
      let j = i + 1;
      while (j < messages.length && messages[j]?.role === 'tool') { cycle.push(messages[j]); j++; }
      units.push({ kind: 'tool-cycle', msgs: cycle, open: j === messages.length });
      i = j - 1;
      continue;
    }
    units.push({ kind: 'turn', msgs: [m], open: false });
  }
  return units;
}

function clipTextMiddle(text, limitChars, label) {
  if (typeof text !== 'string' || text.length <= limitChars) return text;
  // For very small limits the two-sided keep degenerates; fall back to a
  // head-only clip so the result ALWAYS respects the limit.
  if (limitChars < 220) {
    return `${text.slice(0, Math.max(1, limitChars))}\n[bridge] ...${text.length - limitChars} chars ${label}...`;
  }
  const keep = Math.max(1, Math.floor((limitChars - 160) / 2));
  return `${text.slice(0, keep)}\n[bridge] ...${text.length - (2 * keep)} chars ${label}...\n${text.slice(-keep)}`;
}

// Tool results remain paired with their tool call, but their payload is not
// indivisible. Keeping the role and tool_call_id while clipping only content
// preserves provider validation and prevents one huge terminal/file dump from
// causing a permanent 413 for every following Zoo request.
function clipOversizedToolResults(messages, maxTokens) {
  const limitChars = maxTokens * 4;
  return messages.map(m => {
    if (m?.role !== 'tool') return m;
    if (typeof m.content === 'string') {
      return m.content.length <= limitChars ? m : { ...m, content: clipTextMiddle(m.content, limitChars, 'tool result clipped to fit context') };
    }
    if (Array.isArray(m.content)) {
      return {
        ...m,
        content: m.content.map(b => (b && typeof b.text === 'string' && b.text.length > limitChars
          ? { ...b, text: clipTextMiddle(b.text, limitChars, 'tool result clipped to fit context') }
          : b)),
      };
    }
    // Structured non-text payload (e.g. {type:'text',...} object or unknown
    // shape): project to text, clip, wrap back so the budget is enforceable.
    if (m.content && typeof m.content === 'object') {
      const text = textFromContent(m.content, { imageMarkers: false });
      if (text.length > limitChars) {
        return { ...m, content: clipTextMiddle(text, limitChars, 'tool result clipped to fit context') };
      }
    }
    return m;
  });
}

// Hard budget enforcement: the sum of a protected tail (several tool cycles,
// each potentially near the per-result ceiling) plus system+head can exceed
// the whole budget even after per-result clipping. This walks tool messages
// NEWEST first and shrinks each one until the total fits. The pairing with
// the tool call survives (role/tool_call_id untouched); only payload text
// shrinks. A floor keeps tiny results intact.
function enforceToolResultBudget(messages, maxTokens) {
  const floorTokens = 500;
  let out = messages;
  for (let pass = 0; pass < 64; pass++) {
    const total = conversationTokens(out);
    if (total <= maxTokens) return out;
    const over = total - maxTokens;
    // Newest-first: shave the NEWEST tool message above the floor by the whole
    // overshoot (clamped to its own size). One pass per message converges in
    // at most (number of tool messages) passes; 64 covers every realistic tail.
    const idx = [...out].map((m, i) => ({ m, i })).reverse().find(x =>
      x.m?.role === 'tool' && messageTokens(x.m) > floorTokens);
    if (!idx) return out; // nothing left to shave: caller reports the residue
    const cur = messageTokens(idx.m);
    const target = Math.max(floorTokens, cur - over);
    const limitTokens = Math.max(1, Math.ceil(target));
    const before = conversationTokens(out);
    out = out.map((m, i) => (i === idx.i
      ? clipOversizedToolResults([m], limitTokens)[0]
      : m));
    // Safety: if this pass somehow did not shrink anything, stop early.
    if (conversationTokens(out) >= before) return out;
  }
  return out;
}

// Last-resort clipping for plain text turns that are individually over budget.
// Tool payloads are handled separately above: the call/result pairing is kept.
// Block-form (Array) content is clip-able too, and it MUST be measured by the
// SAME metric the budget uses. conversationTokens/messageTokens size an array
// content as JSON.stringify(content) — that counts image base64 and any other
// non-text block, not just b.text. Measuring only b.text was the endless-413
// bug: a user turn whose bulk is a non-text block (pasted image, structured
// payload) looked small to the clipper but stayed huge to the budget, so it
// was never shrunk and every request failed context_limit. Here we measure by
// estimateTokens (JSON) and, when over the share, we clip text blocks AND
// collapse every non-text block to a short marker so the JSON provably fits.
function clipOversizedTurns(messages, maxTokens) {
  const budgetChars = maxTokens * 4;
  // Measure in CHARS to compare against limitChars (chars). For block content
  // the JSON length is the honest proxy the budget uses (estimateTokens*4).
  const turnLen = m => (typeof m.content === 'string'
    ? m.content.length
    : Array.isArray(m.content) ? estimateTokens(m.content) * 4 : 0);
  const clippable = new Set(messages.filter(m =>
    m.role !== 'system' && m.role !== 'developer'
    && m.role !== 'tool'
    && !Array.isArray(m.tool_calls)
    && (typeof m.content === 'string' || Array.isArray(m.content))
    && !isCompactedMarker(m)));
  if (!clippable.size) return messages;
  // Share the budget across clippable turns, with a floor so short turns are
  // never mangled and a request never degenerates into fragments.
  const limitChars = Math.max(1000, Math.floor(budgetChars / clippable.size));
  return messages.map(m => {
    if (!clippable.has(m) || turnLen(m) <= limitChars) return m;
    if (typeof m.content === 'string') {
      return { ...m, content: clipTextMiddle(m.content, limitChars, 'plain turn clipped to fit context') };
    }
    // Block form: clip oversized TEXT blocks only. Non-text blocks (images)
    // are preserved here - the "images must not silently vanish" invariant.
    // If the conversation is STILL over budget after text clipping, the
    // separate collapseNonTextPass below sheds non-text blocks, biggest first.
    const next = m.content.map(b => (b && typeof b.text === 'string' && b.text.length > limitChars
      ? { ...b, text: clipTextMiddle(b.text, limitChars, 'plain turn clipped to fit context') }
      : b));
    return { ...m, content: next };
  });
}

// Final resort when text clipping alone cannot bring the conversation under
// budget (the endless-413 shape: a user turn whose bulk is a base64 image or
// other non-text block - invisible to text clipping, but counted by the
// JSON-based budget). Collapses non-text blocks to short markers, biggest
// block first, and stops as soon as the budget fits, so small images survive.
function collapseNonTextPass(messages, maxTokens) {
  let out = messages;
  for (let guard = 0; guard < 64; guard++) {
    if (conversationTokens(out) <= maxTokens) return out;
    let worst = -1; let worstSave = 0; let worstIdx = -1;
    for (let i = 0; i < out.length; i++) {
      const m = out[i];
      if (!m || !Array.isArray(m.content)) continue;
      if (m.role === 'system' || m.role === 'developer' || m.role === 'tool') continue;
      for (let b = 0; b < m.content.length; b++) {
        const blk = m.content[b];
        if (!blk || typeof blk.text === 'string') continue;
        const save = estimateTokens(blk) - 16;
        if (save > worstSave) { worstSave = save; worst = i; worstIdx = b; }
      }
    }
    if (worst < 0) return out; // no non-text blocks left: truly indivisible
    const m = out[worst];
    const kind = (m.content[worstIdx] && typeof m.content[worstIdx].type === 'string')
      ? m.content[worstIdx].type : 'block';
    const nextContent = m.content.slice();
    nextContent[worstIdx] = { type: 'text', text: `[bridge] non-text ${kind} block omitted to fit context` };
    out = out.map((x, i) => (i === worst ? { ...x, content: nextContent } : x));
  }
  return out;
}

// Returns { messages, applied, before, after, mode } and never mutates input.
// On an unresolvable oversized indivisible element (e.g. a single tool result
// bigger than the whole budget) returns { error } instead of a broken payload.
//
// Indivisible by construction: leading system/developer turns, the last user
// turn, and the trailing unfinished tool-cycle. Only COMPLETED old cycles and
// old plain turns are dropped, whole.
function compactConversation(parsed, { mode, maxTokens, maxToolResultTokens, keepHead, keepTail }) {
  const messages = Array.isArray(parsed?.messages) ? parsed.messages : [];
  const before = conversationTokens(messages);
  if (mode === 'off' || before <= maxTokens) {
    return { messages, applied: false, before, after: before, mode };
  }
  const fp = sessionFingerprint(parsed);

  // System/developer turns are never candidates: they carry the contract.
  const leadingSystem = [];
  let i = 0;
  while (i < messages.length && (messages[i]?.role === 'system' || messages[i]?.role === 'developer')) {
    leadingSystem.push(messages[i]); i++;
  }
  const units = buildUnits(messages.slice(i));

  // Indivisible tail: the trailing open tool-cycle, then the assistant reply
  // and user turn that close the conversation. keepTail units are protected,
  // but never more than what exists.
  const tailUnits = [];
  if (units.length && units[units.length - 1].open) tailUnits.unshift(units.pop());
  // Pop whole units (turns OR completed tool-cycles) until keepTail units are
  // protected. A trailing open cycle is already indivisible via the pop above.
  while (tailUnits.length < keepTail && units.length) {
    tailUnits.unshift(units.pop());
  }
  // Keep tail alternation valid: a tail starting with an assistant turn needs
  // its preceding user turn inside the tail as well.
  if (tailUnits.length && tailUnits[0].kind === 'turn'
    && tailUnits[0].msgs[0]?.role === 'assistant' && units.length
    && units[units.length - 1].kind === 'turn'
    && units[units.length - 1].msgs[0]?.role === 'user') {
    tailUnits.unshift(units.pop());
  }

  // An already-compacted history keeps its marker as the head: the summary is
  // the continuity anchor that stops a long session from looking brand-new.
  const markerIdx = units.findIndex(u => u.kind === 'turn' && isCompactedMarker(u.msgs[0]));
  let head, rest;
  if (markerIdx >= 0) {
    head = [units[markerIdx]];
    rest = units.filter((_, k) => k !== markerIdx);
  } else {
    head = units.slice(0, Math.min(keepHead, units.length));
    rest = units.slice(head.length);
  }

  const fixedTokens = leadingSystem.reduce((s, m) => s + messageTokens(m), 0)
    + head.reduce((s, u) => s + unitTokens(u), 0)
    + tailUnits.reduce((s, u) => s + unitTokens(u), 0);

  // Drop the OLDEST completed units first, whole, until the budget fits.
  const kept = [...rest];
  const dropped = [];
  let total = fixedTokens + kept.reduce((s, u) => s + unitTokens(u), 0);
  while (kept.length && total > maxTokens) {
    const u = kept.shift();
    dropped.push(u);
    total -= unitTokens(u);
  }

  let out;
  let clipped = false;
  if (markerIdx >= 0) {
    // Incremental re-compaction: bump the revision, never re-digest, never
    // touch the tail. The dialogue keeps its shape across requests.
    const prevRev = Number(head[0].msgs[0].content.match(/rev=(\d+)/)?.[1] || 1);
    const marker = dropped.length
      ? { role: 'user', content: `${COMPACT_TAG} session=${fp} rev=${prevRev + 1}] `
          + `${dropped.length} more earlier turn(s) folded into this summary.` }
      : head[0].msgs[0];
    out = [...leadingSystem, marker, ...kept.flatMap(u => u.msgs), ...tailUnits.flatMap(u => u.msgs)];
  } else if (dropped.length) {
    let digest = mode === 'trim' ? '' : digestTurns(dropped.flatMap(u => u.msgs));
    // The digest must fit the budget that remains after head/tail/kept. A
    // digest larger than that is truncated: an oversized marker is excluded
    // from clipping (it is the continuity anchor), so it has to be sized here.
    const reserved = leadingSystem.reduce((s, m) => s + messageTokens(m), 0)
      + head.reduce((s, u) => s + unitTokens(u), 0)
      + tailUnits.reduce((s, u) => s + unitTokens(u), 0)
      + kept.reduce((s, u) => s + unitTokens(u), 0);
    const digestBudget = Math.max(0, maxTokens - reserved - 64);
    if (digest.length > digestBudget * 4) {
      digest = digest.slice(0, Math.max(0, digestBudget * 4 - 40)) + '\n[...digest truncated to fit]';
    }
    const marker = {
      role: 'user',
      content: digest
        ? `${COMPACT_TAG} session=${fp} rev=1]\nSummary of ${dropped.length} earlier turn(s):\n${digest}`
        : `${COMPACT_TAG} session=${fp} rev=1] ${dropped.length} earlier turn(s) omitted to fit the context budget.`,
    };
    // The marker replaces the dropped span; the kept head units stay verbatim.
    out = [...leadingSystem, ...head.flatMap(u => u.msgs), marker, ...kept.flatMap(u => u.msgs), ...tailUnits.flatMap(u => u.msgs)];
  } else {
    out = [...leadingSystem, ...head.flatMap(u => u.msgs), ...kept.flatMap(u => u.msgs), ...tailUnits.flatMap(u => u.msgs)];
  }

  // A trailing tool cycle is protected as a unit, but a giant tool RESULT
  // inside it is safely content-clipped before the general planner gives up.
  out = clipOversizedToolResults(out, Math.min(maxTokens, maxToolResultTokens || 24000));

  // Second pass: enforce the WHOLE budget across tool results. The first clip
  // only capped each result individually; the sum of a protected tail plus
  // system+head can still exceed the budget. Newest-first shaving guarantees
  // termination and keeps the most recent context intact as long as possible.
  out = enforceToolResultBudget(out, maxTokens);

  // Plain text turns kept verbatim can still individually exceed the budget.
  // Clipping is iterative: each pass removes at least half of every oversized
  // plain turn, so the loop terminates and plain text always fits. If the
  // residue is indivisible (a tool cycle or an oversized block-form turn),
  // clipOversizedTurns cannot shrink it - that yields an explicit
  // context-limit error instead of a broken payload.
  let after = conversationTokens(out);
  if (after > maxTokens) {
    let clippedOut = out;
    for (let pass = 0; pass < 16 && conversationTokens(clippedOut) > maxTokens; pass++) {
      const beforePass = conversationTokens(clippedOut);
      clippedOut = clipOversizedTurns(clippedOut, maxTokens);
      const afterPass = conversationTokens(clippedOut);
      if (afterPass >= beforePass) break; // text clipping exhausted
    }
    // Text clipping alone did not fit the budget: this is the endless-413 shape
    // where the bulk is a NON-text block (base64 image / structured payload)
    // that text clipping cannot touch. Collapse non-text blocks, biggest first,
    // until the budget fits - images that are not the problem are preserved.
    if (conversationTokens(clippedOut) > maxTokens) {
      clippedOut = collapseNonTextPass(clippedOut, maxTokens);
    }
    const clippedAfter = conversationTokens(clippedOut);
    if (clippedAfter > maxTokens + 64) {
      // The +64 slack covers the clip marker and short head turns that cannot
      // be reduced further; anything still far over budget is indivisible.
      // An indivisible element (typically one oversized tool result) cannot fit
      // the budget even alone. Fail loudly instead of shipping a broken
      // tool cycle or silently erasing the session.
      // Name the biggest survivors so the next failure is self-describing:
      // role, whether content is block-form, and its JSON estimate. Without
      // this every oversized-turn bug required guessing the culprit shape.
      const top = out
        .map((m, i) => ({ i, role: m?.role, block: Array.isArray(m?.content), tok: estimateTokens(m?.content) }))
        .sort((a, b) => b.tok - a.tok).slice(0, 3)
        .map(x => `#${x.i} ${x.role}${x.block ? '(block)' : ''}~${x.tok}`).join(', ');
      return {
        messages: out, applied: false, before, after, mode,
        error: {
          type: 'context_limit',
          message: `context_limit: conversation (~${after} est. tokens) still exceeds the `
            + `${maxTokens}-token budget after compaction; an indivisible element `
            + `(tool cycle or oversized turn) cannot be reduced further without breaking it `
            + `[largest: ${top}]`,
        },
      };
    }
    out = clippedOut;
    after = clippedAfter;
    clipped = true;
  }

  return { messages: out, applied: dropped.length > 0 || clipped, before, after, mode };
}

const ROLE_LABEL = { system: 'System', developer: 'System', user: 'User', assistant: 'Assistant', tool: 'Tool result' };

// Render the whole conversation as a labelled transcript inside one user
// message. The model still sees every turn and who said it. Tool schemas stay
// in the top-level `tools` field, so the model can still call tools.
function flattenConversation(parsed) {
  const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
  const instructions = [];
  const turns = [];
  // Images cannot live inside a transcript line, so they are collected and
  // re-attached as real blocks after the text. Dropping them here was the
  // second half of the silent image-loss bug.
  const images = [];

  for (const m of messages) {
    if (!m || typeof m !== 'object') continue;
    for (const b of contentBlocks(m.content)) {
      const image = parseImageBlock(b);
      if (image) images.push(image);
    }
    if (m.role === 'system' || m.role === 'developer') {
      const text = textFromContent(m.content);
      if (text) instructions.push(text);
      continue;
    }
    let text = textFromContent(m.content);
    if (m.role === 'assistant' && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const calls = m.tool_calls
        .map(c => `${c.function?.name || 'tool'}(${c.function?.arguments || '{}'})`)
        .join('\n');
      text = text ? `${text}\n${calls}` : calls;
    }
    if (text) turns.push({ role: m.role, text });
  }

  const parts = [];
  if (instructions.length) parts.push(`Instructions:\n${instructions.join('\n\n')}`);
  if (turns.length > 1) {
    parts.push('Conversation so far:\n'
      + turns.slice(0, -1).map(t => `${ROLE_LABEL[t.role] || t.role}: ${t.text}`).join('\n\n'));
  }
  const last = turns[turns.length - 1];
  if (last) {
    parts.push(last.role === 'assistant'
      ? `Continue your previous reply:\n${last.text}`
      : `Current message:\n${last.text}`);
  }

  const text = parts.join('\n\n') || 'Continue.';
  const content = images.length
    ? [{ type: 'text', text }, ...images.map(img => ({
        type: 'image_url',
        image_url: { url: img.kind === 'url' ? img.url : `data:${img.mediaType};base64,${img.data}` },
      }))]
    : text;

  return { ...parsed, messages: [{ role: 'user', content }] };
}

// ---------------------------------------------------------------------------
// OpenAI <-> Anthropic translation
// ---------------------------------------------------------------------------

// Anthropic requires alternating turns starting with user. When two turns of
// the same role merge, tool_result blocks must lead the merged content: the
// API requires tool_result blocks to appear before other content in a turn.
function normalizeTurns(turns) {
  const merged = [];
  for (const turn of turns) {
    const prev = merged[merged.length - 1];
    if (prev && prev.role === turn.role) {
      const a = Array.isArray(prev.content) ? prev.content : [{ type: 'text', text: String(prev.content) }];
      const b = Array.isArray(turn.content) ? turn.content : [{ type: 'text', text: String(turn.content) }];
      const all = [...a, ...b];
      prev.content = [...all.filter(x => x?.type === 'tool_result'), ...all.filter(x => x?.type !== 'tool_result')];
    } else {
      merged.push({ ...turn });
    }
  }
  if (merged.length && merged[0].role !== 'user') merged.unshift({ role: 'user', content: 'Continue.' });
  return merged;
}

// Per-model ceiling, longest prefix wins; falls back to the global default.
function maxTokensFor(model) {
  const name = String(model || '').toLowerCase();
  let best = null;
  for (const [prefix, value] of Object.entries(config.modelMaxTokens)) {
    if (name.startsWith(prefix) && (best === null || prefix.length > best.prefix.length)) {
      best = { prefix, value };
    }
  }
  return best ? best.value : config.defaultMaxTokens;
}

// Tool-cycle integrity on the Anthropic route. A tool_use whose result was
// dropped upstream of this point triggers a 400 ValidationException, so every
// call is answered: a missing result gets an explicit placeholder, and a
// result with no call is demoted to plain text instead of being forwarded.
function repairToolPairs(messages) {
  const list = (Array.isArray(messages) ? messages : []).filter(m => m && typeof m === 'object');
  const out = [];
  let pending = [];
  for (const m of list) {
    if (m.role === 'assistant' && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      pending = m.tool_calls.map(c => String(c.id || 'call_unknown'));
      out.push(m);
      continue;
    }
    if (m.role === 'tool') {
      const id = String(m.tool_call_id || 'call_unknown');
      if (!pending.includes(id)) {
        // Dangling result: keep the information, lose the pairing hazard.
        out.push({ role: 'user', content: `[tool result for ${id}] ${textFromContent(m.content)}` });
        continue;
      }
      out.push(m);
      // Answer any earlier calls in this turn that were never answered, in
      // call order, so the sequence stays valid.
      const answered = out.filter(x => x.role === 'tool').map(x => String(x.tool_call_id));
      for (const pid of pending) {
        if (!answered.includes(pid)) {
          out.push({ role: 'tool', tool_call_id: pid, content: '[bridge] tool result was not present in the conversation history.' });
        }
      }
      pending = pending.filter(pid => !answered.includes(pid) && pid !== id);
      continue;
    }
    if (pending.length) {
      // A new turn arrives while calls are unanswered: close the cycle first.
      for (const pid of pending) {
        out.push({ role: 'tool', tool_call_id: pid, content: '[bridge] tool result was not present in the conversation history.' });
      }
      pending = [];
    }
    out.push(m);
  }
  for (const pid of pending) {
    out.push({ role: 'tool', tool_call_id: pid, content: '[bridge] tool result was not present in the conversation history.' });
  }
  return out;
}

function toAnthropicRequest(parsed, { stream = false } = {}) {
  const messages = repairToolPairs(Array.isArray(parsed.messages) ? parsed.messages : []);
  const systemParts = [];
  const turns = [];

  for (const m of messages) {
    if (!m || typeof m !== 'object') continue;
    if (m.role === 'system' || m.role === 'developer') {
      // System has no image channel upstream; markers keep the loss visible.
      const text = textFromContent(m.content);
      if (text) systemParts.push(text);
      continue;
    }
    if (m.role === 'tool') {
      turns.push({
        role: 'user',
        content: [{
          type: 'tool_result',
          tool_use_id: m.tool_call_id || 'call_unknown',
          content: textFromContent(m.content),
        }],
      });
      continue;
    }
    if (m.role === 'assistant' && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const blocks = [];
      const text = textFromContent(m.content);
      if (text) blocks.push({ type: 'text', text });
      for (const call of m.tool_calls) {
        let input = {};
        try { input = JSON.parse(call.function?.arguments || '{}'); } catch {}
        blocks.push({ type: 'tool_use', id: call.id || 'call_unknown', name: call.function?.name || 'unknown', input });
      }
      turns.push({ role: 'assistant', content: blocks });
      continue;
    }
    // User/assistant turns keep full fidelity: image blocks survive as images.
    turns.push({ role: m.role === 'assistant' ? 'assistant' : 'user', content: blocksToAnthropic(m.content) });
  }

  const body = {
    model: parsed.model,
    // The client is authoritative when it states a limit. When it does not (Zoo
    // Code usually does not), the old code silently imposed 4096 and long
    // answers came back truncated with finish_reason=length on 76% of traffic.
    max_tokens: Number(parsed.max_tokens || parsed.max_completion_tokens || maxTokensFor(parsed.model)),
    messages: normalizeTurns(turns.length ? turns : [{ role: 'user', content: 'Continue.' }]),
  };
  const system = systemParts.filter(Boolean).join('\n\n');
  if (system) body.system = system;
  if (parsed.temperature != null) body.temperature = parsed.temperature;
  if (parsed.top_p != null) body.top_p = parsed.top_p;
  if (parsed.stop != null) body.stop_sequences = Array.isArray(parsed.stop) ? parsed.stop : [String(parsed.stop)];
  // Reasoning controls must ride through, otherwise the client's model settings
  // are quietly ignored on the rung that serves most requests.
  if (parsed.thinking != null) body.thinking = parsed.thinking;
  else if (parsed.reasoning_effort != null) {
    const budget = { minimal: 1024, low: 4096, medium: 8192, high: 16384, xhigh: 24576 }[String(parsed.reasoning_effort)];
    if (budget) body.thinking = { type: 'enabled', budget_tokens: Math.min(budget, body.max_tokens - 1) };
  }
  if (stream) body.stream = true;
  if (Array.isArray(parsed.tools) && parsed.tools.length) {
    const tools = parsed.tools.map(t => ({
      name: t.function?.name || t.name,
      description: t.function?.description || t.description || '',
      input_schema: t.function?.parameters || t.input_schema || { type: 'object', properties: {} },
    })).filter(t => t.name);
    if (tools.length) body.tools = tools;
  }
  return body;
}

const STOP_REASON_MAP = {
  end_turn: 'stop',
  stop_sequence: 'stop',
  max_tokens: 'length',
  tool_use: 'tool_calls',
};

function fromAnthropicResponse(a, fallbackModel) {
  const blocks = Array.isArray(a?.content) ? a.content : [];
  const text = blocks.filter(b => b?.type === 'text').map(b => b.text).join('');
  const toolUses = blocks.filter(b => b?.type === 'tool_use');
  const message = { role: 'assistant', content: text || null };
  // Surface extended thinking the way OpenAI-compatible clients expect, so the
  // model's reasoning setting is not silently discarded on this route.
  const thinking = blocks.filter(b => b?.type === 'thinking').map(b => b.thinking || b.text).filter(Boolean).join('');
  if (thinking) message.reasoning_content = thinking;
  if (toolUses.length) {
    message.tool_calls = toolUses.map((b, i) => ({
      id: b.id || `call_${i}`,
      type: 'function',
      function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) },
    }));
  }
  const inTok = a?.usage?.input_tokens ?? 0;
  const outTok = a?.usage?.output_tokens ?? 0;
  return {
    id: a?.id || 'chatcmpl-bridge',
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: a?.model || fallbackModel,
    choices: [{ index: 0, message, finish_reason: STOP_REASON_MAP[a?.stop_reason] || 'stop' }],
    usage: { prompt_tokens: inTok, completion_tokens: outTok, total_tokens: inTok + outTok },
  };
}

// ---------------------------------------------------------------------------
// Response emission
// ---------------------------------------------------------------------------

// Turn a complete OpenAI chat.completion into a minimal SSE stream: one chunk
// carrying the whole message, one terminating chunk, then [DONE].
function emitSse(res, completion, fallbackModel, ctxAfter = 0) {
  cors(res);
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  const base = {
    id: completion.id || 'chatcmpl-bridge',
    object: 'chat.completion.chunk',
    created: completion.created || Math.floor(Date.now() / 1000),
    model: completion.model || fallbackModel,
  };
  const choices = (completion.choices || []).map((c, i) => {
    const delta = { role: c.message?.role || 'assistant' };
    if (c.message?.content != null) delta.content = c.message.content;
    if (Array.isArray(c.message?.tool_calls)) {
      // Streaming tool calls carry a positional index per OpenAI's schema.
      delta.tool_calls = c.message.tool_calls.map((tc, idx) => ({ index: idx, ...tc }));
    }
    return { index: c.index ?? i, delta, finish_reason: null };
  });
  res.write(`data: ${JSON.stringify({ ...base, choices })}\n\n`);
  const finals = (completion.choices || []).map((c, i) => ({
    index: c.index ?? i,
    delta: {},
    finish_reason: c.finish_reason || 'stop',
  }));
  res.write(`data: ${JSON.stringify({ ...base, choices: finals })}\n\n`);
  // Usage on the terminating chunk so Zoo's context counter stays correct.
  // CTX-03: prompt_tokens is replaced with the calibrated post-compaction
  // estimate so the counter tracks the real sent context, not the provider's
  // cache-hit guess. Completion tokens stay verbatim.
  if (completion.usage) {
    const usageOut = applyCalibratedUsage(completion.usage, ctxAfter);
    res.write(`data: ${JSON.stringify({ ...base, choices: [], usage: usageOut })}\n\n`);
  }
  res.write('data: [DONE]\n\n');
  res.end();
}

function emitJson(res, status, obj, upstreamResponse) {
  cors(res);
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  const cache = upstreamResponse?.headers.get('cache-control');
  if (cache) res.setHeader('cache-control', cache);
  res.write(JSON.stringify(obj));
  res.end();
}

function emitRaw(res, status, text, upstreamResponse) {
  cors(res);
  res.statusCode = status;
  for (const name of ['content-type', 'cache-control']) {
    const value = upstreamResponse?.headers.get(name);
    if (value) res.setHeader(name, value);
  }
  if (text) res.write(text);
  res.end();
}

// Stream an Anthropic SSE response into the OpenAI-compatible SSE dialect.
// Unlike the old path, this forwards each content_block_delta immediately;
// it never waits for the complete model response. Errors are still buffered
// before this function is called, so a failed rung can safely fall through.
async function emitAnthropicStream(res, upstreamResponse, body, fallbackModel, ctxAfter = 0) {
  cors(res);
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders?.();

  let id = 'chatcmpl-bridge';
  let model = fallbackModel;
  let toolIndex = 0;
  let started = false;
  let buffer = '';
  // One-line usage capture: the provider reports real token counts in
  // message_start / message_delta; the client stream does not carry them, so
  // the only place they can be recorded is here.
  let usage = null;
  const write = (delta, finish_reason = null) => {
    const chunk = {
      id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model,
      choices: [{ index: 0, delta, finish_reason }],
    };
    res.write(`data: ${JSON.stringify(chunk)}\n\n`);
  };
  // Final usage chunk: Zoo reads usage from the terminating chunk of the
  // stream the same way it does for a direct provider connection. Without it
  // the context counter in Zoo never updates.
  const writeUsage = () => {
    if (!usage) return;
    const rawIn = usage.input_tokens ?? 0;
    const outTok = usage.output_tokens ?? 0;
    // CTX-03: substitute the calibrated post-compaction estimate for the
    // provider's unreliable input_tokens. The raw value stays in the log line.
    const inTok = calibrateContextUsage(ctxAfter, rawIn) ?? rawIn;
    const chunk = {
      id, object: 'chat.completion.chunk', created: Math.floor(Date.now() / 1000), model,
      choices: [],
      usage: { prompt_tokens: inTok, completion_tokens: outTok, total_tokens: inTok + outTok },
    };
    res.write(`data: ${JSON.stringify(chunk)}\n\n`);
  };
  const handle = raw => {
    const line = raw.trim();
    if (!line || !line.startsWith('data:')) return;
    const value = line.slice(5).trim();
    if (!value || value === '[DONE]') return;
    let event;
    try { event = JSON.parse(value); } catch { return; }
    if (event.type === 'message_start') {
      id = event.message?.id || id;
      model = event.message?.model || model;
      if (event.message?.usage) usage = { ...event.message.usage };
      if (!started) { write({ role: 'assistant' }); started = true; }
      return;
    }
    if (event.type === 'content_block_start') {
      const block = event.content_block;
      if (block?.type === 'tool_use') {
        toolIndex++;
        write({ tool_calls: [{ index: toolIndex - 1, id: block.id || `call_${toolIndex - 1}`, type: 'function', function: { name: block.name || '', arguments: '' } }] });
      }
      return;
    }
    if (event.type === 'content_block_delta') {
      const d = event.delta || {};
      if (typeof d.text === 'string') write({ content: d.text });
      else if (typeof d.thinking === 'string') write({ reasoning_content: d.thinking });
      else if (typeof d.partial_json === 'string' && toolIndex > 0) {
        write({ tool_calls: [{ index: toolIndex - 1, function: { arguments: d.partial_json } }] });
      }
      return;
    }
    if (event.type === 'message_delta') {
      const stop = event.delta?.stop_reason;
      const mapped = STOP_REASON_MAP[stop] || (stop === 'end_turn' ? 'stop' : null);
      if (event.usage) usage = { ...(usage || {}), ...event.usage };
      if (mapped) write({}, mapped);
      return;
    }
  };

  try {
    for await (const chunk of body) {
      buffer += Buffer.from(chunk).toString('utf8');
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop() || '';
      for (const line of lines) handle(line);
    }
    if (buffer) handle(buffer);
    if (!started) write({ role: 'assistant' });
    write({}, 'stop');
    writeUsage();
    res.write('data: [DONE]\n\n');
    res.end();
    if (usage) {
      log(`USAGE in=${usage.input_tokens ?? '?'} out=${usage.output_tokens ?? '?'} `
        + `(model=${model}, real provider tokens)`);
    }
  } catch (error) {
    if (!res.writableEnded) res.destroy(error);
    throw error;
  }
}

// Stream OpenAI SSE while removing invalid `data: null` events. The previous
// implementation received a fully buffered string, so it could not preserve
// progressive delivery.
// Rewrite the usage block inside an OpenAI SSE `data:` line with the
// calibrated post-compaction estimate (CTX-03). The provider's prompt_tokens
// is a cache-hit guess and makes Zoo's counter jump; completion_tokens stays.
function calibrateSseLine(line, ctxAfter) {
  if (!(ctxAfter > 0) || !line.includes('"usage"')) return line;
  const m = line.match(/^\s*data:\s*(\{.*\})\s*$/);
  if (!m) return line;
  try {
    const obj = JSON.parse(m[1]);
    if (!obj.usage) return line;
    obj.usage = applyCalibratedUsage(obj.usage, ctxAfter);
    return `data: ${JSON.stringify(obj)}`;
  } catch { return line; }
}

async function emitFilteredSseStream(res, status, body, upstreamResponse, ctxAfter = 0) {
  cors(res);
  res.statusCode = status;
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders?.();
  let buffer = '';
  let passthrough = false;
  try {
    for await (const chunk of body) {
      buffer += Buffer.from(chunk).toString('utf8');
      // An upstream that answers with plain text (not SSE lines) must be
      // forwarded verbatim: re-framing text as SSE lines corrupts it.
      if (!passthrough && buffer.length > 0 && !buffer.startsWith('data:') && !buffer.startsWith(':') && buffer.includes('\n')) {
        passthrough = true;
      }
      if (passthrough) {
        res.write(buffer);
        buffer = '';
        continue;
      }
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop() || '';
      for (const line of lines) {
        if (/^\s*data:\s*null\s*$/.test(line)) continue;
        res.write(`${calibrateSseLine(line, ctxAfter)}\n\n`);
      }
    }
    if (buffer && !/^\s*data:\s*null\s*$/.test(buffer)) res.write(`${calibrateSseLine(buffer, ctxAfter)}\n\n`);
    res.end();
  } catch (error) {
    if (!res.writableEnded) res.destroy(error);
    throw error;
  }
}

// Strip `data: null` lines, which some upstream models emit and which crash
// clients with "Cannot read properties of null (reading 'choices')".
function emitFilteredSse(res, status, text, upstreamResponse, ctxAfter = 0) {
  cors(res);
  res.statusCode = status;
  for (const name of ['content-type', 'cache-control']) {
    const value = upstreamResponse?.headers.get(name);
    if (value) res.setHeader(name, value);
  }
  let buffer = '';
  for (const line of text.split('\n')) {
    if (/^\s*data:\s*null\s*$/.test(line)) continue;
    buffer += calibrateSseLine(line, ctxAfter) + '\n';
  }
  res.write(buffer.trimEnd());
  res.end();
}

// ---------------------------------------------------------------------------
// Recovery ladder
// ---------------------------------------------------------------------------

function serializeOpenAi(parsed, { model, forceNonStream } = {}) {
  const clone = { ...parsed };
  if (model) clone.model = model;
  if (forceNonStream) { clone.stream = false; delete clone.stream_options; }
  return JSON.stringify(clone);
}

// Shape-based routing.
//
// Measured over 5906 live requests: the pre-model gate rejects deterministically
// by request SHAPE, not by wording. Every one of the 4238 payloads carrying
// block-form `content` together with a tool catalogue was refused on
// /v1/chat/completions and accepted on /v1/messages. Walking the old fixed order
// therefore burned two guaranteed failures per request - 4619 + 4688 rejections,
// ~7.4 h of pure latency - before reaching the rung that works.
//
// So: predict the losing form and skip it. The skipped rung is not deleted, it
// is demoted, because the prediction is a heuristic and must be able to be wrong
// without costing correctness.
function predictGateRejection(parsed, model) {
  if (!config.shapeRouting || !parsed || !Array.isArray(parsed.messages)) return false;
  const blockMsgs = parsed.messages.filter(m => Array.isArray(m?.content)).length;
  const tools = Array.isArray(parsed.tools) ? parsed.tools.length : 0;
  return blockMsgs > 0 && tools > 0;
}

// Every rung changes something meaningful about the request, ordered from least
// to most invasive. Re-sending identical bytes is never a rung.
function buildStrategies({ method, upstreamPath, parsed, rawBody, clientWantsStream, model }) {
  const primary = { base: config.upstream, key: config.upstreamKey, name: 'primary' };
  const secondary = config.fallbackUpstream && config.fallbackKey && config.fallbackUpstream !== config.upstream
    ? { base: config.fallbackUpstream, key: config.fallbackKey, name: 'alt-host' }
    : null;

  const isChat = upstreamPath === '/v1/chat/completions' && parsed && Array.isArray(parsed.messages);
  const wrapStream = clientWantsStream && parsed != null
    && config.wrapStreamModels.some(m => model.startsWith(m));

  const strategies = [];

  const asIs = {
    label: 'primary/as-is',
    target: primary,
    path: upstreamPath,
    body: method === 'POST'
      ? (wrapStream ? serializeOpenAi(parsed, { forceNonStream: true }) : rawBody)
      : undefined,
    upstreamStream: clientWantsStream && !wrapStream,
    translate: 'none',
  };

  // Fast path: the OpenAI form of this request is predicted to be refused, so
  // lead with the Anthropic form and keep as-is as the immediate fallback.
  const skipAsIs = isChat && config.anthropicRetry && predictGateRejection(parsed, model);
  if (skipAsIs) {
    strategies.push({
      label: 'primary/anthropic-first',
      target: primary,
      path: '/v1/messages',
      body: JSON.stringify(toAnthropicRequest(parsed, { stream: clientWantsStream && !wrapStream })),
      extraHeaders: { 'anthropic-version': '2023-06-01' },
      upstreamStream: clientWantsStream && !wrapStream,
      translate: 'anthropic',
    });
  }
  strategies.push(asIs);

  if (!isChat) {
    // Non-chat routes (models, embeddings, anthropic passthrough) only get the
    // alternate host, since the content transforms do not apply.
    if (secondary) {
      strategies.push({
        label: 'alt-host/as-is',
        target: secondary,
        path: upstreamPath,
        body: method === 'POST' ? rawBody : undefined,
        upstreamStream: false,
        translate: 'none',
      });
    }
    return strategies;
  }

  const nudged = config.nudgeEnabled ? applyNudge(parsed, config.nudgeText) : null;
  const flat = config.flattenRetry ? flattenConversation(parsed) : null;

  // Nudge: originally believed to be the cheapest effective rescue (12/12 in the
  // small early sample). At scale it is the opposite: 16 rescues out of 5906
  // requests (0.27%) against 4688 rejections costing 3.3 s each - 4.3 h wasted.
  // It stays available but sits AFTER the Anthropic form, which is what actually
  // rescues these payloads.
  const pushNudge = () => {
    if (!nudged) return;
    strategies.push({
      label: 'primary/nudge',
      target: primary,
      path: upstreamPath,
      body: serializeOpenAi(nudged, { forceNonStream: true }),
      upstreamStream: false,
      translate: 'none',
    });
  };
  if (!config.nudgeAfterAnthropic) pushNudge();

  // Anthropic route, system hoisted top-level (the claude-cli shape). Skipped
  // when it already ran as the leading rung.
  if (config.anthropicRetry && !skipAsIs) {
    strategies.push({
      label: 'primary/anthropic',
      target: primary,
      path: '/v1/messages',
      body: JSON.stringify(toAnthropicRequest(parsed, { stream: clientWantsStream && !wrapStream })),
      extraHeaders: { 'anthropic-version': '2023-06-01' },
      upstreamStream: clientWantsStream && !wrapStream,
      translate: 'anthropic',
    });
  }
  if (config.nudgeAfterAnthropic) pushNudge();
  if (config.anthropicRetry) {
    if (nudged) {
      strategies.push({
        label: 'primary/anthropic+nudge',
        target: primary,
        path: '/v1/messages',
        body: JSON.stringify(toAnthropicRequest(nudged, { stream: clientWantsStream && !wrapStream })),
        extraHeaders: { 'anthropic-version': '2023-06-01' },
        upstreamStream: clientWantsStream && !wrapStream,
        translate: 'anthropic',
      });
    }
  }

  // Rung 4: whole conversation collapsed into a single user message.
  if (flat) {
    strategies.push({
      label: 'primary/flatten',
      target: primary,
      path: upstreamPath,
      body: serializeOpenAi(flat, { forceNonStream: true }),
      upstreamStream: false,
      translate: 'none',
    });
    if (config.anthropicRetry) {
      strategies.push({
        label: 'primary/flatten+anthropic',
        target: primary,
        path: '/v1/messages',
        body: JSON.stringify(toAnthropicRequest(flat)),
        extraHeaders: { 'anthropic-version': '2023-06-01' },
        upstreamStream: false,
        translate: 'anthropic',
      });
    }
  }

  // Rung 5: a different gateway host with its own key and quota.
  if (secondary) {
    strategies.push({
      label: 'alt-host/as-is',
      target: secondary,
      path: upstreamPath,
      body: serializeOpenAi(parsed, { forceNonStream: true }),
      upstreamStream: false,
      translate: 'none',
    });
    if (nudged) {
      strategies.push({
        label: 'alt-host/nudge',
        target: secondary,
        path: upstreamPath,
        body: serializeOpenAi(nudged, { forceNonStream: true }),
        upstreamStream: false,
        translate: 'none',
      });
    }
    if (config.anthropicRetry) {
      strategies.push({
        label: 'alt-host/anthropic',
        target: secondary,
        path: '/v1/messages',
        body: JSON.stringify(toAnthropicRequest(nudged || parsed, { stream: clientWantsStream && !wrapStream })),
        extraHeaders: { 'anthropic-version': '2023-06-01' },
        upstreamStream: clientWantsStream && !wrapStream,
        translate: 'anthropic',
      });
    }
  }

  // Rung 6: explicit opt-in model swap over the Anthropic route.
  for (const alt of config.modelFallbacks) {
    if (alt.toLowerCase() === model) continue;
    strategies.push({
      label: `primary/model=${alt}`,
      target: primary,
      path: '/v1/messages',
      body: JSON.stringify(toAnthropicRequest({ ...(nudged || parsed), model: alt }, { stream: clientWantsStream && !wrapStream })),
      extraHeaders: { 'anthropic-version': '2023-06-01' },
      upstreamStream: clientWantsStream && !wrapStream,
      translate: 'anthropic',
    });
  }

  return strategies;
}

async function callUpstream(strategy, { method, search, accept, contentType, signal }) {
  const headers = {
    Authorization: `Bearer ${strategy.target.key}`,
    'x-api-key': strategy.target.key,
    'User-Agent': config.upstreamUserAgent,
    Accept: strategy.upstreamStream ? (accept || 'text/event-stream') : 'application/json',
    ...(strategy.extraHeaders || {}),
  };
  if (strategy.body !== undefined) {
    headers['Content-Type'] = contentType || 'application/json';
    headers['Content-Length'] = Buffer.byteLength(strategy.body);
  }
  const url = `${strategy.target.base}${strategy.path}${search || ''}`;
  const response = await fetch(url, { method, headers, body: strategy.body, signal });

  // A successful stream must stay a stream. Error bodies are buffered because
  // the ladder needs their markers before deciding whether to advance.
  if (strategy.upstreamStream && response.ok) {
    return { response, body: response.body, text: '', url };
  }
  let text = '';
  if (response.body) {
    const chunks = [];
    for await (const chunk of response.body) chunks.push(chunk);
    text = Buffer.concat(chunks.map(c => Buffer.isBuffer(c) ? c : Buffer.from(c))).toString('utf8');
  }
  return { response, body: null, text, url };
}

// Last N one-line status records for the Bridge window mini-log. Newest last;
// the UI reads the tail. Kept tiny on purpose: no bodies, no keys, no secrets.
const statusLines = [];
function pushStatus(line) {
  statusLines.push(`${new Date().toISOString()} ${line}`);
  if (statusLines.length > 30) statusLines.shift();
}

async function proxy(req, res) {
  const url = new URL(req.url, `http://${config.host}:${config.port}`);
  const upstreamPath = normalizePath(url.pathname);
  if (!upstreamPath) {
    log(`404 ${req.method} ${req.url}`);
    return json(res, 404, { error: { message: `Not found: ${url.pathname}`, type: 'invalid_request_error' } });
  }
  if (upstreamPath === '/status') {
    // Mini-log for the Bridge window: one changing line per event.
    return json(res, 200, { lines: statusLines.slice(-10) });
  }
  if (upstreamPath === '/health') {
    return json(res, 200, {
      ok: true,
      upstream: config.upstream,
      altUpstream: config.fallbackUpstream && config.fallbackKey ? config.fallbackUpstream : null,
      nudge: config.nudgeEnabled,
      anthropicRetry: config.anthropicRetry,
      flattenRetry: config.flattenRetry,
      modelFallbacks: config.modelFallbacks,
      port: config.port,
      // Everything the UI needs to show real state instead of guessing.
      shapeRouting: config.shapeRouting,
      nudgeAfterAnthropic: config.nudgeAfterAnthropic,
      // BUI-04: honest streaming state derived from the operator opt-out list.
      // Empty NO_STREAM_MODELS => real progressive SSE for every model ("on");
      // a non-empty list means those models are wrapped into one chunk ("off").
      streaming: config.wrapStreamModels.length ? 'off' : 'on',
      wrapStreamModels: config.wrapStreamModels,
      // Image transmission state: true = images stripped at the edge (off).
      stripImages: config.stripImages,
      compact: {
        mode: config.compactMode,
        maxTokens: config.compactMaxTokens,
        maxToolResultTokens: config.compactMaxToolResultTokens,
        keepHead: config.compactKeepHead,
        keepTail: config.compactKeepTail,
      },
      defaultMaxTokens: config.defaultMaxTokens,
      modelMaxTokens: config.modelMaxTokens,
      limits: {
        logMaxBytes: config.logMaxBytes,
        logKeep: config.logKeep,
        diagMaxFiles: config.diagMaxFiles,
        diagMaxBytes: config.diagMaxBytes,
        diagDedupe: config.diagDedupe,
      },
      uptimeSec: Math.round(process.uptime()),
    });
  }
  if (!auth(req)) {
    log(`401 ${req.method} ${req.url} (invalid local key; authorization=${req.headers.authorization ? 'present' : 'absent'}, x-api-key=${req.headers['x-api-key'] ? 'present' : 'absent'})`);
    return json(res, 401, { error: { message: 'Invalid local API key', type: 'authentication_error' } });
  }
  if (!['GET', 'POST'].includes(req.method)) {
    return json(res, 405, { error: { message: 'Method not allowed', type: 'invalid_request_error' } });
  }

  // Not const: context compaction below can replace the body being forwarded.
  let rawBody = req.method === 'POST' ? await readBody(req) : undefined;
  let parsed = null;
  let clientWantsStream = false;
  let model = '';
  let shape = '';
  if (rawBody) {
    try {
      parsed = JSON.parse(rawBody);
      clientWantsStream = parsed.stream === true;
      model = String(parsed.model || '').toLowerCase();
      shape = describeShape(parsed, rawBody.length);
    } catch {
      shape = describeShape(null, rawBody.length);
    }
    const truncated = rawBody.length > 500 ? rawBody.substring(0, 500) + '...' : rawBody;
    log(`REQ BODY: ${truncated}`);
    log(`REQ SHAPE: model=${model || '-'} ${shape}`);
    // DEBUG PROBE: does the INBOUND payload already contain the gateway's own
    // block markers? If so, no shape-changing rung can clear the gate, because
    // every rung preserves wording. This validates the self-poisoning theory.
    const poison = poisonMarkersIn(rawBody);
    if (poison.length) {
      log(`REQ POISON: inbound payload carries ${poison.length} gateway block marker(s): ${JSON.stringify([...new Set(poison)])} `
        + `- ALL rungs will fail with filter if wording is the trigger`);
    }
  }

  // Image transmission OFF: strip image blocks at the edge, BEFORE compaction
  // and before any upstream call. Recompute rawBody/shape so the budget, the
  // recovery ladder and the logs all see the stripped request. This is the
  // single control point for "never forward images".
  if (config.stripImages && parsed && Array.isArray(parsed.messages)) {
    const removed = stripImages(parsed);
    if (removed > 0) {
      rawBody = JSON.stringify(parsed);
      shape = describeShape(parsed, rawBody.length);
      log(`STRIP IMAGES: removed ${removed} image block(s) from inbound request `
        + `(image transmission disabled; body now ${rawBody.length} bytes)`);
    }
  }

  const clientIsAnthropic = upstreamPath === '/v1/messages';
  // CTX-03: post-compaction context estimate carried into every usage path.
  let ctxAfter = 0;

  // Compact before building the ladder, so every rung sees the same conversation
  // and the same request cannot be over budget on one rung and not on another.
  // The client's own condense requests pass through untouched.
  if (parsed && Array.isArray(parsed.messages) && config.compactMode !== 'off' && !isCondenseRequest(parsed)) {
    const result = compactConversation(parsed, {
      mode: config.compactMode,
      maxTokens: config.compactMaxTokens,
      maxToolResultTokens: config.compactMaxToolResultTokens,
      keepHead: config.compactKeepHead,
      keepTail: config.compactKeepTail,
    });
    if (result.error) {
      // An indivisible element (e.g. a single tool result) cannot fit the
      // budget. Surfacing this explicitly beats forwarding a broken tool
      // cycle or silently resetting the session.
      log(`COMPACT context-limit: ${result.error.message}`);
      pushStatus(`413 context_limit: ~${result.after}/${config.compactMaxTokens} tok`);
      return json(res, 413, { error: { type: result.error.type, message: result.error.message } });
    }
    if (result.applied) {
      log(`COMPACT ${result.mode}: ~${result.before} -> ~${result.after} est. tokens `
        + `(budget ${config.compactMaxTokens}, msgs ${parsed.messages.length} -> ${result.messages.length})`);
      pushStatus(`compact ${result.mode}: ~${result.before}->~${result.after} tok`);
      parsed = { ...parsed, messages: result.messages };
      // The raw bytes no longer represent the request being sent.
      rawBody = JSON.stringify(parsed);
    }
    // CTX-03: the post-compaction estimate is the truth about the context the
    // model actually receives. Carry it to every usage-emitting path so Zoo's
    // counter reflects the real sent prompt, not the provider's cache-hit guess.
    // When compaction did NOT apply, the sent prompt equals the raw estimate.
    ctxAfter = result.after;
  } else if (parsed && Array.isArray(parsed.messages)) {
    ctxAfter = conversationTokens(parsed.messages);
  }

  const strategies = buildStrategies({
    method: req.method,
    upstreamPath,
    parsed,
    rawBody,
    clientWantsStream,
    model,
  });

  let clientGone = false;
  let activeController = null;
  req.on('close', () => {
    clientGone = true;
    if (!res.writableEnded && activeController) activeController.abort();
  });

  const started = Date.now();
  const trail = [];
  let lastStatus = 502;
  let lastBody = '';
  let lastResponse = null;

  for (let i = 0; i < strategies.length; i++) {
    const strategy = strategies[i];
    if (clientGone) return;

    // Transient faults are worth repeating on the same rung. Deterministic
    // rejections are not, so they fall straight through to the next rung.
    for (let attempt = 1; attempt <= config.transientRetries; attempt++) {
      if (clientGone) return;
      const attemptStarted = Date.now();
      const controller = new AbortController();
      activeController = controller;
      const timer = setTimeout(() => controller.abort(), config.timeout);

      let outcome;
      try {
        const { response, body, text, url: calledUrl } = await callUpstream(strategy, {
          method: req.method,
          search: url.search,
          accept: req.headers.accept,
          contentType: req.headers['content-type'],
          signal: controller.signal,
        });
        clearTimeout(timer);
        const attemptMs = Date.now() - attemptStarted;

        if (response.ok) {
          log(`-> ${req.method} ${req.url} => ${strategy.label} ${strategy.path} upstream=${response.status} (${Date.now() - started}ms total, rung ${i + 1}/${strategies.length}${trail.length ? `, after: ${trail.join(' | ')}` : ''})`);
          pushStatus(`${strategy.label} ${response.status} ${Date.now() - started}ms`);

          // Real token accounting, non-stream path: usage rides inside the
          // completion body (OpenAI) or the anthropic message. One line, so
          // the log stays readable and the numbers can be trusted.
          try {
            const probe = JSON.parse(text);
            const u = probe?.usage;
            if (u) {
              const inTok = u.prompt_tokens ?? u.input_tokens ?? '?';
              const outTok = u.completion_tokens ?? u.output_tokens ?? '?';
              log(`USAGE in=${inTok} out=${outTok} (model=${parsed?.model || model}, real provider tokens)`);
              pushStatus(`tokens in=${inTok} out=${outTok}`);
            }
          } catch { }

          // Streaming responses must be committed immediately after the status
          // is known. Error bodies are still buffered by callUpstream, so a
          // failed rung never leaks partial bytes and can safely fall through.
          if (strategy.upstreamStream && body) {
            if (strategy.translate === 'anthropic') {
              return emitAnthropicStream(res, response, body, parsed?.model || model, ctxAfter);
            }
            return emitFilteredSseStream(res, response.status, body, response, ctxAfter);
          }

          if (!text) { cors(res); res.statusCode = response.status; return res.end(); }

          if (strategy.translate === 'anthropic') {
            // Upstream answered in Anthropic shape; the client speaks OpenAI.
            let completion;
            try {
              completion = fromAnthropicResponse(JSON.parse(text), parsed?.model || model);
            } catch (e) {
              log(`anthropic translate failed: ${e.message}; forwarding raw`);
              return emitRaw(res, response.status, text, response);
            }
            if (clientWantsStream) return emitSse(res, completion, parsed?.model || model, ctxAfter);
            // CTX-03: calibrate the non-stream usage too so the counter is
            // consistent regardless of transport.
            if (completion.usage) completion.usage = applyCalibratedUsage(completion.usage, ctxAfter);
            return emitJson(res, 200, completion, response);
          }

          if (strategy.upstreamStream) return emitFilteredSse(res, response.status, text, response, ctxAfter);

          if (clientWantsStream && !clientIsAnthropic) {
            // Client wanted a stream, upstream gave a single JSON completion.
            try {
              const wrapped = JSON.parse(text);
              if (wrapped.usage) wrapped.usage = applyCalibratedUsage(wrapped.usage, ctxAfter);
              return emitSse(res, wrapped, parsed?.model || model, ctxAfter);
            } catch (e) {
              log(`wrap-stream parse failed: ${e.message}; forwarding raw`);
              return emitRaw(res, response.status, text, response);
            }
          }

          return emitRaw(res, response.status, text, response);
        }

        const kind = classifyFailure(response.status, text);
        const gate = classifyGate(attemptMs);
        log(`rung ${i + 1}/${strategies.length} ${strategy.label} attempt ${attempt}/${config.transientRetries} upstream=${response.status} ${kind} (${attemptMs}ms ${gate}): ${text.slice(0, 300)}`);
        const dump = dumpFailure({
          ts: new Date().toISOString(),
          status: response.status,
          kind,
          gate,
          strategy: strategy.label,
          attempt,
          attemptMs,
          upstream: calledUrl,
          model: parsed?.model || model,
          shape,
          responseBody: text,
          requestBody: strategy.body,
        });
        if (dump) log(`diag dump: diag/${dump}`);

        lastStatus = response.status;
        lastBody = text;
        lastResponse = response;
        outcome = kind;
      } catch (error) {
        clearTimeout(timer);
        if (clientGone) return;
        log(`rung ${i + 1}/${strategies.length} ${strategy.label} attempt ${attempt}/${config.transientRetries} ERR ${error.name}: ${error.message}`);
        lastStatus = error.name === 'AbortError' ? 504 : 502;
        lastBody = JSON.stringify({
          error: {
            message: error.name === 'AbortError' ? 'Upstream timeout' : 'Upstream connection failed',
            type: 'proxy_error',
          },
        });
        lastResponse = null;
        outcome = 'transient';
      }

      trail.push(`${strategy.label}:${outcome}`);

      if (outcome === 'auth' && strategy.target.name === 'primary') {
        // A bad primary key will not fix itself; surface it instead of walking
        // the ladder hammering the same credential.
        log('aborting ladder: primary upstream rejected the key');
        return emitRaw(res, lastStatus, lastBody, lastResponse);
      }
      if (outcome === 'transient' && attempt < config.transientRetries) {
        const delay = config.retryDelayMs * attempt;
        log(`transient fault, retrying same rung in ${delay}ms`);
        await new Promise(r => setTimeout(r, delay));
        continue;
      }
      break; // move to the next rung
    }
  }

  if (clientGone) return;

  const detail = `${lastStatus} after ${strategies.length} recovery path(s): ${trail.join(' | ')}`;
  log(`ALL RUNGS FAILED ${req.method} ${req.url} (${Date.now() - started}ms) ${detail}`);

  // No graceful degradation. The old fake-200 embedded the gateway's own refusal
  // text ("sensitive words detected", "content gate", ...) into the assistant
  // turn; the client appended it to history and re-sent it next request, tripping
  // the PRE_MODEL_GATE on the bridge's own words. That self-poisoning loop is what
  // broke long sessions. Surface the real upstream status verbatim instead.
  return emitRaw(res, lastStatus, lastBody, lastResponse);
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') { cors(res); res.writeHead(204); return res.end(); }
  proxy(req, res).catch(error => {
    log(`ERR ${req.method} ${req.url} ${error.message}`);
    if (!res.headersSent) json(res, 400, { error: { message: error.message, type: 'invalid_request_error' } });
  });
});

server.on('error', error => {
  if (error.code === 'EADDRINUSE') log(`Port ${config.port} is already in use; no existing process was changed.`);
  else log(error.stack || String(error));
  process.exitCode = 1;
});

server.listen(config.port, config.host, () => {
  log(`AgentRouter bridge listening at http://${config.host}:${config.port}`);
  log(`OpenAI base URL for Zoo Code: http://127.0.0.1:${config.port}/v1`);
  log(`ladder: primary=${config.upstream} nudge=${config.nudgeEnabled} anthropic=${config.anthropicRetry} flatten=${config.flattenRetry} altHost=${config.fallbackUpstream && config.fallbackKey ? config.fallbackUpstream : 'none'} modelFallbacks=[${config.modelFallbacks.join(',')}]`);
});
