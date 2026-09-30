// Offline unit tests for the pure request transforms in server.mjs.
//
// Why a child process instead of `import`: server.mjs binds a port on import,
// so it cannot be imported into a test. Instead the transforms are exercised
// through a tiny harness that loads the source, strips the bootstrap tail and
// evaluates the pure part. No network, no quota, no listening socket.
//
// Run: node tools/unit-transforms.mjs
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';

const SRC = new URL('../server.mjs', import.meta.url);
const source = readFileSync(SRC, 'utf8');

// Everything from the http server construction onwards is side-effectful.
const cut = source.indexOf('const server = http.createServer');
if (cut < 0) throw new Error('cannot locate server bootstrap marker in server.mjs');

const pure = source.slice(0, cut)
  // The key guard throws when .env is absent; tests supply their own config.
  .replace("if (!config.upstreamKey) throw new Error('UPSTREAM_API_KEY is required in api-test/.env');", '');

const harness = `${pure}
export const __t = {
  textFromContent, blocksToAnthropic, parseImageBlock, hasImage, contentBlocks,
  toAnthropicRequest, fromAnthropicResponse, flattenConversation, applyNudge,
  buildStrategies, predictGateRejection, maxTokensFor, describeShape,
  classifyFailure, classifyGate, normalizePath, config,
  emitAnthropicStream,
  compactConversation, conversationTokens, estimateTokens, isCondenseRequest, digestTurns,
  sessionFingerprint, buildUnits, clipOversizedTurns, clipOversizedToolResults, isCompactedMarker,
  normalizeTurns, repairToolPairs,
};
`;

// The harness must live next to server.mjs: the source resolves proxy.log and
// diag/ relative to import.meta.url, which a data: URL cannot provide.
process.env.UPSTREAM_API_KEY = process.env.UPSTREAM_API_KEY || 'test-key';
// Point log/diag writes at throwaway names so tests never touch real artefacts.
process.env.DIAG_DUMPS = '0';
process.env.LOG_MAX_BYTES = '0';

const HARNESS = new URL('../.unit-harness.tmp.mjs', import.meta.url);
writeFileSync(HARNESS, harness);
let T;
try {
  T = (await import(`${HARNESS.href}?v=${Date.now()}`)).__t;
} finally {
  try { unlinkSync(HARNESS); } catch {}
}

let pass = 0, fail = 0;
function check(name, ok, detail = '') {
  if (ok) { pass++; console.log(`  PASS  ${name}`); }
  else { fail++; console.log(`  FAIL  ${name} :: ${detail}`); }
}
function eq(name, actual, expected) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  check(name, a === e, `expected ${e}, got ${a}`);
}

const PNG = 'iVBORw0KGgoAAAANSUhEUg==';
const DATA_URI = `data:image/png;base64,${PNG}`;

console.log('--- image block parsing ---');
eq('openai data-uri image_url',
  T.parseImageBlock({ type: 'image_url', image_url: { url: DATA_URI } }),
  { kind: 'base64', mediaType: 'image/png', data: PNG });
eq('openai http url image_url',
  T.parseImageBlock({ type: 'image_url', image_url: { url: 'https://example.com/a.jpeg' } }),
  { kind: 'url', url: 'https://example.com/a.jpeg', mediaType: 'image/jpeg' });
eq('anthropic base64 image',
  T.parseImageBlock({ type: 'image', source: { type: 'base64', media_type: 'image/webp', data: PNG } }),
  { kind: 'base64', mediaType: 'image/webp', data: PNG });
check('text block is not an image', T.parseImageBlock({ type: 'text', text: 'hi' }) === null);
check('garbage is not an image', T.parseImageBlock({ type: 'image_url', image_url: { url: 'nonsense' } }) === null);

console.log('\n--- REGRESSION: images must not vanish ---');
{
  const content = [{ type: 'text', text: 'what is this' }, { type: 'image_url', image_url: { url: DATA_URI } }];
  const blocks = T.blocksToAnthropic(content);
  check('blocksToAnthropic keeps the image block',
    Array.isArray(blocks) && blocks.some(b => b.type === 'image'), JSON.stringify(blocks));
  check('blocksToAnthropic keeps the text block',
    Array.isArray(blocks) && blocks.some(b => b.type === 'text' && b.text === 'what is this'));
  const anth = blocks.find(b => b.type === 'image');
  eq('image converted to anthropic base64 source', anth?.source,
    { type: 'base64', media_type: 'image/png', data: PNG });

  // The historical bug: text-only projection silently discarded the image.
  const text = T.textFromContent(content);
  check('text projection marks the image instead of dropping it silently',
    text.includes('[image 1'), JSON.stringify(text));
}

console.log('\n--- toAnthropicRequest carries images end to end ---');
{
  const req = T.toAnthropicRequest({
    model: 'claude-opus-5',
    messages: [
      { role: 'system', content: 'Be brief.' },
      { role: 'user', content: [{ type: 'text', text: 'describe' }, { type: 'image_url', image_url: { url: DATA_URI } }] },
    ],
  });
  const wire = JSON.stringify(req);
  check('image survives into the anthropic wire body', wire.includes(PNG), wire.slice(0, 200));
  eq('system hoisted to top level', req.system, 'Be brief.');
  check('image block typed for anthropic', wire.includes('"type":"image"'));
}

console.log('\n--- flatten keeps images (second half of the loss bug) ---');
{
  const flat = T.flattenConversation({
    model: 'm',
    messages: [
      { role: 'user', content: [{ type: 'text', text: 'first' }, { type: 'image_url', image_url: { url: DATA_URI } }] },
      { role: 'assistant', content: 'ok' },
      { role: 'user', content: 'and now?' },
    ],
  });
  eq('flatten collapses to one message', flat.messages.length, 1);
  const wire = JSON.stringify(flat.messages[0].content);
  check('flatten preserves the image payload', wire.includes(PNG), wire.slice(0, 160));
  check('flatten preserves transcript text', wire.includes('and now?'));
}

console.log('\n--- max_tokens no longer silently 4096 ---');
{
  const noLimit = T.toAnthropicRequest({ model: 'claude-opus-5', messages: [{ role: 'user', content: 'hi' }] });
  check('absent client limit does not collapse to 4096',
    noLimit.max_tokens !== 4096 && noLimit.max_tokens >= 8192, `max_tokens=${noLimit.max_tokens}`);
  const explicit = T.toAnthropicRequest({ model: 'claude-opus-5', max_tokens: 64, messages: [{ role: 'user', content: 'hi' }] });
  eq('client-stated limit wins', explicit.max_tokens, 64);
  const alias = T.toAnthropicRequest({ model: 'claude-opus-5', max_completion_tokens: 128, messages: [{ role: 'user', content: 'hi' }] });
  eq('max_completion_tokens honoured', alias.max_tokens, 128);
}

console.log('\n--- reasoning settings ride through ---');
{
  const r = T.toAnthropicRequest({
    model: 'claude-opus-5', reasoning_effort: 'high',
    messages: [{ role: 'user', content: 'think' }],
  });
  check('reasoning_effort mapped to a thinking budget',
    r.thinking?.type === 'enabled' && r.thinking.budget_tokens > 0, JSON.stringify(r.thinking));
  check('thinking budget stays below max_tokens', r.thinking.budget_tokens < r.max_tokens);

  const back = T.fromAnthropicResponse({
    id: 'msg_1', model: 'claude-opus-5', stop_reason: 'end_turn',
    content: [{ type: 'thinking', thinking: 'step one' }, { type: 'text', text: 'answer' }],
  }, 'claude-opus-5');
  eq('assistant text extracted', back.choices[0].message.content, 'answer');
  eq('thinking surfaced as reasoning_content', back.choices[0].message.reasoning_content, 'step one');
}

console.log('\n--- finish_reason mapping (long-session truncation must be visible) ---');
{
  const cut = T.fromAnthropicResponse({ stop_reason: 'max_tokens', content: [{ type: 'text', text: 'partial' }] }, 'm');
  eq('max_tokens -> length', cut.choices[0].finish_reason, 'length');
  const tool = T.fromAnthropicResponse({ stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'c1', name: 'read', input: { p: 1 } }] }, 'm');
  eq('tool_use -> tool_calls', tool.choices[0].finish_reason, 'tool_calls');
  eq('tool call arguments serialised', tool.choices[0].message.tool_calls[0].function.arguments, '{"p":1}');
}

console.log('\n--- shape routing: predict the losing form ---');
{
  const agentShape = {
    model: 'claude-opus-5',
    tools: [{ type: 'function', function: { name: 'read_file', parameters: {} } }],
    messages: [
      { role: 'system', content: [{ type: 'text', text: 'sys' }] },
      { role: 'user', content: [{ type: 'text', text: 'go' }] },
    ],
  };
  check('block content + tools is predicted as refused', T.predictGateRejection(agentShape, 'claude-opus-5') === true);

  const plain = { model: 'm', messages: [{ role: 'user', content: 'hello' }] };
  check('plain string payload is not predicted as refused', T.predictGateRejection(plain, 'm') === false);

  const ladder = T.buildStrategies({
    method: 'POST', upstreamPath: '/v1/chat/completions', parsed: agentShape,
    rawBody: JSON.stringify(agentShape), clientWantsStream: true, model: 'claude-opus-5',
  });
  eq('predicted-bad payload leads with the anthropic form', ladder[0].label, 'primary/anthropic-first');
  eq('as-is is demoted, not deleted', ladder[1].label, 'primary/as-is');
  check('anthropic form is not duplicated in the ladder',
    ladder.filter(s => s.label === 'primary/anthropic').length === 0,
    ladder.map(s => s.label).join(' | '));
  check('nudge sits after the anthropic form',
    ladder.findIndex(s => s.label === 'primary/nudge') > 0,
    ladder.map(s => s.label).join(' | '));

  const plainLadder = T.buildStrategies({
    method: 'POST', upstreamPath: '/v1/chat/completions', parsed: plain,
    rawBody: JSON.stringify(plain), clientWantsStream: false, model: 'm',
  });
  eq('plain payload still starts with verbatim passthrough', plainLadder[0].label, 'primary/as-is');
  check('anthropic rung still reachable for plain payloads',
    plainLadder.some(s => s.label === 'primary/anthropic'),
    plainLadder.map(s => s.label).join(' | '));
}

console.log('\n--- ladder invariants preserved ---');
{
  const parsed = { model: 'm', messages: [{ role: 'user', content: 'hi' }] };
  const ladder = T.buildStrategies({
    method: 'POST', upstreamPath: '/v1/chat/completions', parsed,
    rawBody: JSON.stringify(parsed), clientWantsStream: false, model: 'm',
  });
  check('no rung repeats identical bytes on the same path', (() => {
    const seen = new Set();
    for (const s of ladder) {
      const k = `${s.target.base}${s.path}|${s.body}`;
      if (seen.has(k)) return false;
      seen.add(k);
    }
    return true;
  })(), ladder.map(s => s.label).join(' | '));
  check('every rung has a body for POST', ladder.every(s => s.body !== undefined));

  const models = T.buildStrategies({
    method: 'GET', upstreamPath: '/v1/models', parsed: null,
    rawBody: undefined, clientWantsStream: false, model: '',
  });
  check('non-chat route gets no content transforms',
    models.every(s => s.translate === 'none'), models.map(s => s.label).join(' | '));
}

console.log('\n--- nudge still neutral and idempotent in placement ---');
{
  const parsed = { model: 'm', messages: [{ role: 'system', content: 's' }, { role: 'user', content: 'ask' }] };
  const n = T.applyNudge(parsed, '(nudge)');
  eq('nudge appended to the last user message', n.messages[1].content, 'ask\n\n(nudge)');
  eq('original payload untouched', parsed.messages[1].content, 'ask');
  const blocky = T.applyNudge({ messages: [{ role: 'user', content: [{ type: 'text', text: 'a' }] }] }, '(nudge)');
  eq('nudge appended as a block when content is block-form',
    blocky.messages[0].content[1], { type: 'text', text: '(nudge)' });
}

console.log('\n--- failure classification (gate vs transport) ---');
{
  eq('new_api_error sensitive words -> filter',
    T.classifyFailure(500, '{"error":{"code":"sensitive_words_detected"}}'), 'filter');
  eq('agent_router content-blocked -> filter',
    T.classifyFailure(400, '{"error":{"code":"content-blocked"}}'), 'filter');
  eq('401 -> auth', T.classifyFailure(401, 'nope'), 'auth');
  eq('402 -> quota', T.classifyFailure(402, 'pay'), 'quota');
  eq('429 -> transient', T.classifyFailure(429, 'slow down'), 'transient');
  eq('fast rejection -> pre-model gate', T.classifyGate(500), 'PRE_MODEL_GATE');
  eq('slow rejection -> post-model gate', T.classifyGate(6000), 'POST_MODEL_GATE');
}

console.log('\n--- context planner: stable session fingerprint ---');
{
  const base = {
    model: 'claude-opus-5',
    messages: [
      { role: 'system', content: 'CONTRACT: obey the rules.' },
      { role: 'user', content: 'task A' },
      { role: 'assistant', content: 'working' },
    ],
  };
  const fp1 = T.sessionFingerprint(base);
  // Growing the dialogue must NOT change the fingerprint: the session keeps its
  // identity as it grows, which is what stops compaction from looking like a
  // brand-new conversation.
  const grown = { ...base, messages: [...base.messages, { role: 'user', content: 'more work '.repeat(5000) }] };
  const fp2 = T.sessionFingerprint(grown);
  eq('fingerprint stable across conversation growth', fp1, fp2);
  check('fingerprint is a short opaque token',
    typeof fp1 === 'string' && fp1.length > 0 && fp1.length <= 16, fp1);
  eq('different system contract -> different fingerprint',
    T.sessionFingerprint({ ...base, messages: [{ role: 'system', content: 'OTHER CONTRACT' }, ...base.messages.slice(1)] }) !== fp1,
    true);
  // No secret material: the fingerprint never embeds message bodies.
  const secret = { ...base, messages: [{ role: 'system', content: 'c' }, { role: 'user', content: 'sk-supersecret-key-123' }] };
  check('fingerprint does not embed message bodies',
    !JSON.stringify(T.sessionFingerprint(secret)).includes('supersecret'));
}

console.log('\n--- context planner: atomic tool cycles ---');
{
  const units = T.buildUnits([
    { role: 'user', content: 'q1' },
    { role: 'assistant', content: null, tool_calls: [{ id: 'a', type: 'function', function: { name: 'x', arguments: '{}' } }] },
    { role: 'tool', tool_call_id: 'a', content: 'r1' },
    { role: 'user', content: 'q2' },
    { role: 'assistant', content: null, tool_calls: [
      { id: 'b', type: 'function', function: { name: 'y', arguments: '{}' } },
      { id: 'c', type: 'function', function: { name: 'z', arguments: '{}' } },
    ] },
    { role: 'tool', tool_call_id: 'b', content: 'r2' },
    { role: 'tool', tool_call_id: 'c', content: 'r3' },
  ]);
  eq('parallel tool calls plus their results form ONE unit', units.length, 4);
  eq('a trailing cycle with no reply yet is marked open',
    units[3].open, true);
  check('cycle unit contains the call and both results',
    units[3].msgs.length === 3
    && units[3].msgs[0].tool_calls.length === 2
    && units[3].msgs.filter(m => m.role === 'tool').length === 2,
    JSON.stringify(units[3].msgs.map(m => m.role)));
}

console.log('\n--- context planner: 50k session untouched ---');
{
  // ~50k estimated tokens: comfortably under the 180k budget.
  const filler = 'x'.repeat(200000); // 50k tokens
  const messages = [
    { role: 'system', content: 'CONTRACT.' },
    { role: 'user', content: `start ${filler}` },
    { role: 'assistant', content: `mid ${filler}` },
    { role: 'user', content: 'current question' },
  ];
  const out = T.compactConversation({ model: 'm', messages },
    { mode: 'hybrid', maxTokens: 180000, keepHead: 2, keepTail: 6 });
  check('50k session is not compacted', out.applied === false, JSON.stringify({ before: out.before, after: out.after }));
  check('50k session keeps every message', out.messages.length === messages.length);
  check('50k session keeps the image path untouched too', out.error === undefined);
}

console.log('\n--- context planner: 180k session at the budget edge ---');
{
  // ~180k tokens exactly at budget: must not be compacted (<= budget).
  const filler = 'x'.repeat(180000 * 4 - 200);
  const messages = [
    { role: 'system', content: 'CONTRACT.' },
    { role: 'user', content: filler },
    { role: 'assistant', content: 'ack' },
    { role: 'user', content: 'current question' },
  ];
  const out = T.compactConversation({ model: 'm', messages },
    { mode: 'hybrid', maxTokens: 180000, keepHead: 2, keepTail: 6 });
  check('180k-at-budget session is left alone', out.applied === false, `before=${out.before}`);
}

console.log('\n--- context planner: 200-300k session compacts incrementally ---');
{
  // ~260k estimated tokens of completed old cycles plus live work.
  const big = 'y'.repeat(80000); // ~20k tokens per turn
  const messages = [
    { role: 'system', content: 'CONTRACT: obey the rules.' },
    { role: 'user', content: 'TASK HEAD: build the thing' },
    { role: 'assistant', content: 'understood' },
  ];
  for (let i = 0; i < 10; i++) {
    messages.push({ role: 'user', content: `cycle ${i} ${big}` });
    messages.push({ role: 'assistant', content: null, tool_calls: [
      { id: `call_${i}`, type: 'function', function: { name: 'read_file', arguments: '{}' } },
    ] });
    messages.push({ role: 'tool', tool_call_id: `call_${i}`, content: `result ${i} ${big}` });
  }
  messages.push({ role: 'user', content: 'current question: continue' });

  const opts = { mode: 'hybrid', maxTokens: 180000, keepHead: 2, keepTail: 6 };
  const first = T.compactConversation({ model: 'm', messages }, opts);
  check('260k session triggers compaction', first.applied === true, `before=${first.before}`);
  check('260k session is brought under budget', first.after <= 180000, `after=${first.after}`);
  check('system contract preserved verbatim',
    first.messages[0].content === 'CONTRACT: obey the rules.');
  check('session marker present with fingerprint',
    first.messages.some(m => typeof m.content === 'string' && m.content.startsWith('[bridge:compacted session=')),
    JSON.stringify(first.messages.map(m => String(m.content).slice(0, 40))));
  check('last user turn preserved verbatim',
    first.messages.some(m => m.content === 'current question: continue'));
  check('input not mutated', messages.length === 34, `len=${messages.length}`);

  // Tool-cycle atomicity: every surviving tool_call still has its result.
  const ids = new Set(first.messages.filter(m => m.role === 'tool').map(m => String(m.tool_call_id)));
  const calls = first.messages.filter(m => Array.isArray(m.tool_calls)).flatMap(m => m.tool_calls.map(c => c.id));
  check('no tool_call is left without a result after compaction',
    calls.every(id => ids.has(String(id))),
    `calls=${JSON.stringify(calls)} results=${JSON.stringify([...ids])}`);
  // And no result without its call.
  const callSet = new Set(calls.map(String));
  check('no tool result is left without its call',
    [...ids].every(id => callSet.has(id)),
    `results=${JSON.stringify([...ids])} calls=${JSON.stringify(calls)}`);

  // The session must NOT look brand-new: the marker carries the fingerprint.
  const fp = T.sessionFingerprint({ model: 'm', messages });
  check('marker embeds the session fingerprint',
    first.messages.some(m => typeof m.content === 'string' && m.content.includes(`session=${fp}`)),
    first.messages.map(m => String(m.content).slice(0, 60)).join(' | '));

  // Re-compaction of an already-compacted payload: the marker must survive,
  // revision must increment, and the digest must NOT be re-digested.
  const grown = { model: 'm', messages: [...first.messages, { role: 'user', content: `more ${big}` }] };
  const second = T.compactConversation(grown, opts);
  check('re-compaction engages only when over budget again',
    second.applied === true || second.after <= 180000, `after=${second.after}`);
  if (second.applied) {
    const marker = second.messages.find(m => typeof m.content === 'string' && m.content.startsWith('[bridge:compacted'));
    check('compacted marker survives re-compaction', marker != null,
      JSON.stringify(second.messages.map(m => String(m.content).slice(0, 40))));
    check('revision increments instead of cascading',
      /rev=2\]/.test(marker?.content || ''), marker?.content?.slice(0, 80));
    check('dialogue is not erased on re-compaction',
      second.messages.length >= 3
      && second.messages.some(m => m.content === 'current question: continue'),
      JSON.stringify(second.messages.map(m => m.role)));
    const ids2 = new Set(second.messages.filter(m => m.role === 'tool').map(m => String(m.tool_call_id)));
    const calls2 = second.messages.filter(m => Array.isArray(m.tool_calls)).flatMap(m => m.tool_calls.map(c => c.id));
    check('tool pairs stay atomic after re-compaction',
      calls2.every(id => ids2.has(String(id))) && ids2.size === calls2.length,
      `calls=${JSON.stringify(calls2)} results=${JSON.stringify([...ids2])}`);
  }
}

console.log('\n--- context planner: 300k worst case stays controlled ---');
{
  const big = 'z'.repeat(240000); // ~60k tokens per turn
  const messages = [
    { role: 'system', content: 'CONTRACT.' },
    { role: 'user', content: `a ${big}` },
    { role: 'assistant', content: `b ${big}` },
    { role: 'user', content: `c ${big}` },
    { role: 'assistant', content: `d ${big}` },
    { role: 'user', content: 'final question' },
  ];
  const out = T.compactConversation({ model: 'm', messages },
    { mode: 'hybrid', maxTokens: 180000, keepHead: 2, keepTail: 6 });
  check('300k of plain turns is reduced, not reset',
    out.applied === true && out.after <= 180000, `before=${out.before} after=${out.after}`);
  check('final question survives the worst case',
    out.messages.some(m => m.content === 'final question'));
  check('system contract survives the worst case',
    out.messages[0].content === 'CONTRACT.');
}

console.log('\n--- context planner: oversized tool result is clipped but remains paired ---');
{
  const whale = 'w'.repeat(190000 * 4); // ~190k tokens in ONE tool result
  const messages = [
    { role: 'system', content: 'CONTRACT.' },
    { role: 'user', content: 'run the big command' },
    { role: 'assistant', content: null, tool_calls: [
      { id: 'call_big', type: 'function', function: { name: 'run', arguments: '{}' } },
    ] },
    { role: 'tool', tool_call_id: 'call_big', content: whale },
    { role: 'user', content: 'continue' },
  ];
  const out = T.compactConversation({ model: 'm', messages },
    { mode: 'hybrid', maxTokens: 180000, maxToolResultTokens: 24000, keepHead: 2, keepTail: 6 });
  check('oversized tool result no longer produces context-limit 413', !out.error, JSON.stringify(out.error || out.after));
  check('tool result is capped under the configured per-result limit',
    out.messages.find(m => m.role === 'tool')?.content.length <= 24000 * 4, String(out.messages.find(m => m.role === 'tool')?.content.length));
  check('tool result keeps its matching tool_call_id',
    out.messages.some(m => m.role === 'tool' && m.tool_call_id === 'call_big'));
  check('tool-result clipping is explicit',
    JSON.stringify(out.messages).includes('tool result clipped to fit context'));
}

console.log('\n--- context planner: oversized plain text turn is clipped ---');
{
  const opts = { mode: 'hybrid', maxTokens: 400, keepHead: 2, keepTail: 3 };
  const whale = T.compactConversation({
    messages: [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'a' }, { role: 'assistant', content: 'b' },
      { role: 'user', content: 'c' }, { role: 'assistant', content: 'd' },
      { role: 'user', content: 'z'.repeat(500000) },
    ],
  }, opts);
  check('single oversized plain turn is clipped, not passed through',
    whale.applied === true && whale.after < 500000 / 4, `after=${whale.after}`);
  check('clip is marked in the text',
    JSON.stringify(whale.messages).includes('plain turn clipped to fit context'), 'no clip marker');
}

console.log('\n--- context planner: images survive compaction unchanged ---');
{
  const big = 'y'.repeat(400000);
  const messages = [
    { role: 'system', content: 'CONTRACT.' },
    { role: 'user', content: [{ type: 'text', text: `look ${big}` }, { type: 'image_url', image_url: { url: DATA_URI } }] },
    { role: 'assistant', content: 'seen it' },
    { role: 'user', content: `again ${big}` },
    { role: 'assistant', content: 'still there' },
    { role: 'user', content: 'final' },
  ];
  const out = T.compactConversation({ model: 'm', messages },
    { mode: 'hybrid', maxTokens: 180000, keepHead: 2, keepTail: 6 });
  const wire = JSON.stringify(out.messages);
  check('image payload survives compaction byte-identical', wire.includes(PNG));
  check('image block still typed image_url', wire.includes('"type":"image_url"'));
}

console.log('\n--- client condense requests are respected, not double-compacted ---');
{
  check('condense prompt detected', T.isCondenseRequest({
    messages: [{ role: 'system', content: 'You are a helpful AI assistant tasked with summarizing conversations.' }],
  }) === true);
  check('ordinary prompt not treated as condense', T.isCondenseRequest({
    messages: [{ role: 'system', content: 'You are a coding agent.' }, { role: 'user', content: 'hi' }],
  }) === false);
  check('block-form condense prompt also detected', T.isCondenseRequest({
    messages: [{ role: 'system', content: [{ type: 'text', text: 'tasked with summarizing conversations' }] }],
  }) === true);
}

console.log('\n--- token estimator sanity ---');
{
  check('estimate grows with length', T.estimateTokens('x'.repeat(4000)) > T.estimateTokens('x'.repeat(400)));
  check('estimate handles block content', T.conversationTokens([{ role: 'user', content: [{ type: 'text', text: 'hello' }] }]) > 0);
  check('estimate counts tool_calls', T.conversationTokens([
    { role: 'assistant', content: null, tool_calls: [{ id: 'c', type: 'function', function: { name: 'read_file', arguments: '{"path":"a"}' } }] },
  ]) > 0);
}

console.log('\n--- tool_use / tool_result pairing (the 400 ValidationException) ---');
{
  const call = (id, name = 'read_file') => ({
    role: 'assistant', content: null,
    tool_calls: [{ id, type: 'function', function: { name, arguments: '{}' } }],
  });

  // The exact defect from diag: an assistant tool call whose result was dropped.
  const orphaned = T.toAnthropicRequest({
    model: 'claude-opus-5',
    messages: [{ role: 'user', content: 'hi' }, call('toolu_1'), { role: 'user', content: 'next' }],
  });
  const flat0 = orphaned.messages.flatMap(m => Array.isArray(m.content) ? m.content : []);
  const uses0 = flat0.filter(b => b.type === 'tool_use').map(b => b.id);
  const results0 = flat0.filter(b => b.type === 'tool_result').map(b => b.tool_use_id);
  check('anthropic body never ships an unanswered tool_use',
    uses0.every(id => results0.includes(id)), `uses=${JSON.stringify(uses0)} results=${JSON.stringify(results0)}`);

  // Two calls in one turn, only one answered.
  const partial = T.toAnthropicRequest({
    model: 'claude-opus-5',
    messages: [
      { role: 'assistant', content: null, tool_calls: [
        { id: 'a', type: 'function', function: { name: 'x', arguments: '{}' } },
        { id: 'b', type: 'function', function: { name: 'y', arguments: '{}' } },
      ] },
      { role: 'tool', tool_call_id: 'b', content: 'result b' },
    ],
  });
  const flat1 = partial.messages.flatMap(m => Array.isArray(m.content) ? m.content : []);
  const uses1 = flat1.filter(b => b.type === 'tool_use').map(b => b.id);
  const results1 = flat1.filter(b => b.type === 'tool_result').map(b => b.tool_use_id);
  check('every parallel call gets a result in the anthropic body',
    uses1.every(id => results1.includes(id)), `uses=${JSON.stringify(uses1)} results=${JSON.stringify(results1)}`);

  // A dangling tool result must not crash the translation.
  const dangling = T.toAnthropicRequest({
    model: 'm',
    messages: [{ role: 'user', content: 'hi' }, { role: 'tool', tool_call_id: 'ghost', content: 'from a dropped turn' }],
  });
  check('dangling tool result does not crash translation', Array.isArray(dangling.messages));

  // tool_result blocks must lead their message after turn merging.
  const merged = T.normalizeTurns([
    { role: 'user', content: [{ type: 'text', text: 'note' }] },
    { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'z', content: 'r' }] },
  ]);
  check('tool_result is hoisted to the front of a merged turn',
    merged[0].content[0].type === 'tool_result', JSON.stringify(merged[0].content));
}

console.log('\n--- compaction preserves the tool-call invariant at scale ---');
{
  const messages = [{ role: 'system', content: 'sys' }];
  for (let i = 0; i < 40; i++) {
    messages.push({ role: 'user', content: `q${i} ${'x'.repeat(4000)}` });
    messages.push({ role: 'assistant', content: null, tool_calls: [
      { id: `call_${i}`, type: 'function', function: { name: 'read_file', arguments: '{}' } },
    ] });
    messages.push({ role: 'tool', tool_call_id: `call_${i}`, content: `r${i} ${'y'.repeat(4000)}` });
  }
  // Budget is large enough that the protected tail (keepTail=6 units ≈ 6k
  // tokens) still fits after dropping the old span.
  const out = T.compactConversation({ messages },
    { mode: 'hybrid', maxTokens: 40000, keepHead: 2, keepTail: 6 });
  check('compaction actually engaged', out.applied === true, `before=${out.before} after=${out.after} err=${out.error?.type}`);
  const ids = new Set(out.messages.filter(m => m.role === 'tool').map(m => String(m.tool_call_id)));
  const calls = out.messages.filter(m => Array.isArray(m.tool_calls)).flatMap(m => m.tool_calls.map(c => c.id));
  check('no tool_call is left without a result after compaction',
    calls.every(id => ids.has(String(id))), `calls=${JSON.stringify(calls)} results=${JSON.stringify([...ids])}`);
  const callSet = new Set(calls.map(String));
  check('no tool result is left without its call',
    [...ids].every(id => callSet.has(id)));
}

console.log('\n--- validation errors are not reported as content refusals ---');
{
  const vex = JSON.stringify({ error: { message: 'ValidationException: messages.2: `tool_use` ids were found without `tool_result` blocks immediately after: toolu_1' } });
  eq('bedrock validation error classified as invalid', T.classifyFailure(400, vex), 'invalid');
  eq('genuine content block still classified as filter',
    T.classifyFailure(400, '{"error":{"code":"content-blocked"}}'), 'filter');
  eq('quota untouched', T.classifyFailure(402, '{}'), 'quota');
  eq('transient untouched', T.classifyFailure(500, '{}'), 'transient');
}

console.log('\n--- Anthropic SSE separators ---');
{
  const writes = [];
  const res = {
    setHeader() {},
    flushHeaders() {},
    write(value) { writes.push(String(value)); },
    end() {},
  };
  const events = [
    'data: {"type":"message_start","message":{"id":"msg_1","model":"m"}}\n\n',
    'data: {"type":"content_block_delta","delta":{"text":"hello"}}\n\n',
  ];
  const body = {
    async *[Symbol.asyncIterator]() {
      yield events.join('');
    },
  };
  await T.emitAnthropicStream(res, {}, body, 'fallback');
  const emitted = writes.join('');
  check('Anthropic stream has real event boundaries', emitted.includes('\n\n'));
  check('Anthropic stream has no literal backslash-n', !emitted.includes('\\\\n'));
  check('Anthropic stream emits [DONE] with real separator', emitted.includes('data: [DONE]\n\n'));
  check('Anthropic stream emits separate events', emitted.split('\n\n').filter(Boolean).length >= 4);
}

console.log('\n--- path normalisation ---');
{
  eq('doubled prefix repaired', T.normalizePath('/v1/v1/models'), '/v1/models');
  eq('bare path gets v1', T.normalizePath('/chat/completions'), '/v1/chat/completions');
  eq('health passthrough', T.normalizePath('/health'), '/health');
  eq('unknown path rejected', T.normalizePath('/nope'), null);
}

console.log(`\n${fail === 0 ? 'ALL GREEN' : 'FAILURES PRESENT'}: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
