/**
 * TTS 模块逻辑离线验证
 *
 * 用真实抓取的响应（/voices 的 data.catalog 结构 + /forward 的 WAV 字节）
 * 驱动 tts-enhance.js 的两个关键逻辑：
 *   1. 动态音色列表对 data.catalog 字典结构的解析
 *   2. 二进制响应走 base64 且字节无损
 *
 * 用法：node scripts/test-tts-module-logic.js <wav文件> <voicesJson文件>
 */
const fs = require('fs');
const crypto = require('crypto');

const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');

// ── 模拟宿主环境 ──
const hooks = {};
const logs = [];
let config = {};

const MoRead = {
  hook: (e, cb) => { hooks[e] = cb; },
  log: (m) => { logs.push(m); },
  configGet: (k, d) => (k in config ? String(config[k]) : String(d ?? '')),
  configSet: (k, v) => { config[k] = v; },
  configSave: () => {},
  configReload: () => {},
  storageGet: (k, d) => String(d ?? ''),
  storageSet: () => {},
  storageRemove: () => {},
  httpGet: () => null,
  httpPost: () => null,
  httpGetBase64: () => null,
  httpPostBase64: () => null,
  bytesLength: (b64) => {
    if (!b64) return 0;
    let pad = 0;
    if (b64.slice(-1) === '=') pad++;
    if (b64.slice(-2, -1) === '=') pad++;
    return Math.floor((b64.length * 3) / 4) - pad;
  },
  guessAudioType: (b64) => {
    if (!b64 || b64.length < 8) return 'audio/mpeg';
    if (b64.indexOf('UklGR') === 0) return 'audio/wav';
    if (b64.indexOf('T2dnUw') === 0) return 'audio/ogg';
    if (b64.indexOf('ZkxhQ') === 0) return 'audio/flac';
    return 'audio/mpeg';
  },
};

global.MoRead = MoRead;

// ── 加载模块 ──
const src = fs.readFileSync(__dirname + '/../modules/tts-enhance.js', 'utf8');
const fn = new Function('MoRead', src);

console.log('═══════════════════════════════════════════════');
console.log(' 测试 1：URL 超长守卫');
console.log('═══════════════════════════════════════════════');
config = {
  enableCustomTTS: 'true',
  ttsMode: 'universal',
  ttsEndpoint: 'http://192.168.89.43:8774/forward',
  universalMethod: 'GET',
  universalUrlTemplate: '',
  universalHeaders: '{}',
  maxUrlBytes: '7000',
};
Object.keys(hooks).forEach((k) => delete hooks[k]);
logs.length = 0;
fn(MoRead);

const synth = hooks['tts.synthesize'];
if (!synth) { console.log('✗ tts.synthesize hook 未注册'); process.exit(1); }

// 短文本：应通过守卫（随后因无网络失败，但会到达请求阶段）
logs.length = 0;
synth({ text: '你好', voice: 'sougou_xiyue' });
const shortGuardLog = logs.find((l) => l.indexOf('URL 超长') >= 0);
console.log('短文本(2字)     → 被守卫拦截:', shortGuardLog ? '是 ✗ 不该拦' : '否 ✓');

// 长文本：应触发守卫
logs.length = 0;
const longText = '夜色下的临江城灯火阑珊，张伟站在窗前，手里拿着一份刚到的文件。'.repeat(120);
const r = synth({ text: longText, voice: 'sougou_xiyue' });
const longGuardLog = logs.find((l) => l.indexOf('URL 超长') >= 0);
console.log(`长文本(${longText.length}字) → 被守卫拦截:`, longGuardLog ? '是 ✓' : '否 ✗', '| 返回:', r);
if (longGuardLog) console.log('   日志:', longGuardLog.replace(/^\[[^\]]*\]\s*/, ''));

console.log();
console.log('═══════════════════════════════════════════════');
console.log(' 测试 2：二进制音频经模块后字节无损');
console.log('═══════════════════════════════════════════════');
const wavPath = process.argv[2] || (process.env.HOME + '/tts_out.wav');
const rawWav = fs.readFileSync(wavPath);
console.log('样本:', rawWav.length, '字节, MD5', md5(rawWav));

// 让模块的 httpGet 返回真实二进制响应
MoRead.httpGet = (url) => ({
  status: 200,
  body: '',
  ok: true,
  json: null,
  base64: rawWav.toString('base64'),
  contentType: 'audio/x-wav',
});

config = {
  enableCustomTTS: 'true',
  ttsMode: 'universal',
  ttsEndpoint: 'http://192.168.89.43:8774/forward',
  universalMethod: 'GET',
  universalUrlTemplate: 'http://192.168.89.43:8774/forward?text={{text}}&voice={{voice}}',
  universalHeaders: '{}',
  maxUrlBytes: '7000',
};
Object.keys(hooks).forEach((k) => delete hooks[k]);
logs.length = 0;
fn(MoRead);
const synth2 = hooks['tts.synthesize'];
const out = synth2({ text: '你好', voice: 'sougou_xiyue' });
const parsed = JSON.parse(out);
const returned = Buffer.from(parsed.audio, 'base64');
console.log('模块返回 mediaType:', parsed.mediaType);
console.log('模块返回字节数:', returned.length);
console.log('模块返回 MD5:  ', md5(returned));
console.log('字节级一致:', md5(returned) === md5(rawWav) ? '是 ✓ 音频完好' : '否 ✗');
logs.filter((l) => l.indexOf('合成成功') >= 0).forEach((l) => console.log('日志:', l));

console.log();
console.log('═══════════════════════════════════════════════');
console.log(' 测试 3：动态音色解析 data.catalog 字典结构');
console.log('═══════════════════════════════════════════════');
const voicesJsonPath = process.argv[3];
if (voicesJsonPath && fs.existsSync(voicesJsonPath)) {
  const real = JSON.parse(fs.readFileSync(voicesJsonPath, 'utf8'));
  console.log('真实响应顶层键:', Object.keys(real).join(', '));
  console.log('data 下的键:', Object.keys(real.data).join(', '));
  console.log('catalog 分类数:', Object.keys(real.data.catalog).length);
  console.log('总音色数(data.count):', real.data.count);

  MoRead.httpGet = () => ({
    status: 200, body: JSON.stringify(real), ok: true,
    json: JSON.stringify(real), base64: null, contentType: 'application/json',
  });
  config = {
    enableCustomVoices: 'true',
    voicesSource: 'dynamic',
    dynamicVoicesUrl: 'http://192.168.89.43:8774/voices',
    dynamicVoicesExtract: 'data.catalog',
    dynamicVoiceIdField: 'id',
    dynamicVoiceNameField: 'name',
    dynamicVoicesHeaders: '{}',
  };
  Object.keys(hooks).forEach((k) => delete hooks[k]);
  logs.length = 0;
  fn(MoRead);
  const vh = hooks['tts.voices'];
  if (!vh) {
    console.log('✗ tts.voices hook 未注册');
    logs.forEach((l) => console.log('  ', l));
  } else {
    const list = JSON.parse(vh({}));
    console.log('解析出音色数:', list.length, '/ 期望', real.data.count);
    console.log('匹配度:', list.length === real.data.count ? '✓ 完整' : `✗ 差 ${real.data.count - list.length}`);
    console.log('前 3 条:');
    list.slice(0, 3).forEach((v) => console.log('   ', JSON.stringify(v)));
  }
} else {
  console.log('(未提供 voices JSON，跳过)');
}
