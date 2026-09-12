/**
 * TTS 模块二进制通道验证脚本
 *
 * 目的：证明模块通过 base64 取回音频时字节级无损，而旧的文本解码路径会毁掉音频。
 * 用法：node scripts/verify-tts-module.js [host] [port]
 *
 * 前置：本机可访问目标 TTS 服务（默认 192.168.89.43:8774）。
 */
const http = require('http');
const crypto = require('crypto');

const HOST = process.argv[2] || '192.168.89.43';
const PORT = Number(process.argv[3] || 8774);

function md5(buf) {
  return crypto.createHash('md5').update(buf).digest('hex');
}

/** 复刻 ModuleApi.doHttp 的分流判定：Content-Type 前缀 + 魔数 */
function looksBinary(contentType, buf) {
  const ct = (contentType || '').toLowerCase().split(';')[0].trim();
  if (ct.startsWith('audio/') || ct.startsWith('image/') ||
      ct.startsWith('video/') || ct === 'application/octet-stream' ||
      ct === 'application/zip' || ct === 'application/ogg') {
    return true;
  }
  if (buf.length >= 4) {
    if (buf.slice(0, 4).toString('ascii') === 'RIFF') return true;
    if (buf.slice(0, 4).toString('ascii') === 'OggS') return true;
    if (buf.slice(0, 4).toString('ascii') === 'fLaC') return true;
    if (buf.slice(0, 3).toString('ascii') === 'ID3') return true;
    if (buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0) return true;
    if (buf[0] === 0x89 && buf.slice(1, 4).toString('ascii') === 'PNG') return true;
    if (buf[0] === 0xff && buf[1] === 0xd8) return true;
  }
  return false;
}

function httpGetRaw(url) {
  return new Promise((resolve) => {
    http.get(url, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({
        status: res.statusCode,
        buf: Buffer.concat(chunks),
        contentType: res.headers['content-type'],
      }));
    }).on('error', (e) => resolve({ status: 0, error: e.message, buf: Buffer.alloc(0) }));
  });
}

(async () => {
  const text = process.env.TTS_TEST_TEXT || '你好';
  const voice = process.env.TTS_TEST_VOICE || 'sougou_xiyue';
  const url = `http://${HOST}:${PORT}/forward?text=${encodeURIComponent(text)}` +
              `&voice=${encodeURIComponent(voice)}`;

  console.log('目标:', url);
  console.log('URL 字节长度:', Buffer.byteLength(url), '(模块守卫上限 7000)');
  if (Buffer.byteLength(url) > 7000) {
    console.log('  -> 超过守卫生效点，模块会拒绝并提示用户调小单句字数');
  }
  console.log();

  const r = await httpGetRaw(url);
  if (r.status !== 200) {
    console.log('请求失败:', r.error || `HTTP ${r.status}`);
    process.exit(1);
  }

  const binary = looksBinary(r.contentType, r.buf);
  console.log('HTTP', r.status, '| Content-Type:', r.contentType);
  console.log('响应字节数:', r.buf.length);
  console.log('响应 MD5: ', md5(r.buf));
  console.log('判定为二进制:', binary, binary ? '(走 base64，不做文本解码)' : '(走文本)');
  console.log();

  console.log('── 新路径：base64 直传 ──');
  const b64 = r.buf.toString('base64');
  const roundTrip = Buffer.from(b64, 'base64');
  console.log('  base64 长度:', b64.length);
  console.log('  回解字节数:', roundTrip.length);
  console.log('  回解 MD5: ', md5(roundTrip));
  const intact = md5(roundTrip) === md5(r.buf);
  console.log('  字节级一致:', intact ? '是 ✓' : '否 ✗');
  console.log();

  console.log('── 旧路径：bufferedReader().readText() ──');
  const broken = Buffer.from(r.buf.toString('utf8'), 'utf8');
  console.log('  解码后字节数:', broken.length);
  console.log('  解码后 MD5: ', md5(broken));
  console.log('  字节级一致:', md5(broken) === md5(r.buf) ? '是 ✓' : '否 ✗（音频已损坏）');
  console.log();

  console.log('=== 结论 ===');
  console.log(intact
    ? '二进制通道可用：音频通过 base64 往返后字节级无损。'
    : '二进制通道异常：需要检查 Content-Type 分流逻辑。');
})();
