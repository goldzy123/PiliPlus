#!/usr/bin/env node
/**
 * PiliPlus 视频总结服务（局域网）
 *
 * 干什么：B 站官方的 AI 结论接口（/x/web-interface/view/conclusion/get）
 * 只对 B 站自己生成过的视频有货，大部分视频是空的。这个服务补上那一块 ——
 * app 把**字幕文本**丢过来，这里用 DSH 默认的模型（opencode-go / deepseek-v4.1-flash）
 * 生成一份总结；没有字幕的时候退化成「yt-dlp 抓音频 → FunASR 转写 → 总结」。
 * 结果落盘缓存，下次同一个视频直接返回。
 *
 * 为什么把 LLM 放在 Mac 上而不是手机里：手机端不存 API key，
 * 也不用为了总结在手机上跑一次大模型请求（费电、慢）。
 *
 * 端点（TOKEN 为空时不校验）：
 *   POST /api/summary            生成/取总结
 *        body: { bvid, cid, title?, upName?, subtitleText?, force? }
 *        有 subtitleText → 直接总结；没有 → 走音频转写
 *   GET  /api/summary/<bvid>_<cid>   只取缓存，没有返回 404
 *   GET  /health                 健康检查
 *
 * 环境变量：
 *   PORT        默认 8721
 *   TOKEN       共享口令，留空不校验
 *   HOST        默认 0.0.0.0
 *   DATA_DIR    缓存目录，默认 ~/.piliplus-summaries
 *   MODEL       LLM 模型，默认 deepseek-v4.1-flash
 *   LLM_BASE    OpenAI 兼容端点，默认 https://opencode.ai/zen/go/v1
 *   ASR_PY      转写用的 python（语言日程 的 venv），没有就跳过音频转写
 *
 * 零依赖，只用 Node 内置模块。
 */
import http from 'node:http';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const PORT = Number(process.env.PORT || 8721);
const TOKEN = process.env.TOKEN || '';
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR = process.env.DATA_DIR || path.join(os.homedir(), '.piliplus-summaries');
const MODEL = process.env.MODEL || 'deepseek-v4.1-flash';
const LLM_BASE = (process.env.LLM_BASE || 'https://opencode.ai/zen/go/v1').replace(/\/$/, '');
const ASR_PY = process.env.ASR_PY || path.join(os.homedir(), 'nana/ai/dsh/语言日程/.venv/bin/python');
const ASR_SCRIPT = path.join(path.dirname(new URL(import.meta.url).pathname), 'transcribe.py');

const log = (...a) => console.log(new Date().toISOString(), ...a);

/** 从 DSH 的凭据文件里取 key（明文存在 refs 下）。 */
async function apiKey() {
  if (process.env.OPENCODE_GO_API_KEY) return process.env.OPENCODE_GO_API_KEY;
  try {
    const raw = await fsp.readFile(path.join(os.homedir(), '.dsh/.credentials.yaml'), 'utf8');
    const m = raw.match(/^\s*OPENCODE_GO_API_KEY\s*:\s*(\S+)\s*$/m);
    if (m) return m[1];
  } catch {}
  return '';
}

function cacheFile(bvid, cid) {
  return path.join(DATA_DIR, `${bvid}_${cid}.json`);
}

async function readCache(bvid, cid) {
  try {
    return JSON.parse(await fsp.readFile(cacheFile(bvid, cid), 'utf8'));
  } catch {
    return null;
  }
}

async function writeCache(bvid, cid, payload) {
  await fsp.mkdir(DATA_DIR, { recursive: true });
  const f = cacheFile(bvid, cid);
  await fsp.writeFile(`${f}.tmp`, JSON.stringify(payload, null, 2), 'utf8');
  await fsp.rename(`${f}.tmp`, f);
}

const SYS_PROMPT = `你是视频内容总结助手。用户会给你一段视频的标题、UP主和字幕全文。
请输出 Markdown，结构固定为：
## 一句话
（一句话说清这个视频讲了什么）

## 要点
（3-8 条，每条一行，尽量带上视频里出现的具体数字/名称/结论，不要空话）

## 适合谁看
（一句话）

要求：只依据字幕内容，不要编造；字幕是语音识别的可能有错别字，遇到明显同音错字按上下文纠正后使用；
不要复述"视频中说到"这类废话，直接给结论。`;

async function summarize({ title, upName, text }) {
  const key = await apiKey();
  if (!key) throw new Error('没有找到 OPENCODE_GO_API_KEY（看 ~/.dsh/.credentials.yaml）');
  // 字幕可能很长，粗截一下，保留开头和结尾
  const limit = 60000;
  const body = text.length > limit
    ? `${text.slice(0, limit * 0.7)}\n\n……（中间省略）……\n\n${text.slice(-limit * 0.3)}`
    : text;
  const res = await fetch(`${LLM_BASE}/chat/completions`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${key}`,
      'x-opencode-session': '04B149FD-C50B-4289-8454-27C8CA79CD3F',
    },
    body: JSON.stringify({
      model: MODEL,
      temperature: 0.3,
      messages: [
        { role: 'system', content: SYS_PROMPT },
        {
          role: 'user',
          content: `标题：${title || '(未知)'}\nUP主：${upName || '(未知)'}\n\n字幕全文：\n${body}`,
        },
      ],
    }),
  });
  if (!res.ok) {
    throw new Error(`LLM ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const data = await res.json();
  const out = data?.choices?.[0]?.message?.content;
  if (!out) throw new Error('LLM 没返回内容');
  return out.trim();
}

/** 没字幕时的兜底：yt-dlp 抓音频 → FunASR 转写。 */
async function transcribeFromUrl(bvid, cid) {
  const url = `https://www.bilibili.com/video/${bvid}${cid ? `?p=1` : ''}`;
  const tmp = path.join(os.tmpdir(), `piliplus_asr_${bvid}_${cid}`);
  await fsp.mkdir(tmp, { recursive: true });
  const audio = path.join(tmp, 'audio.m4a');
  await execFileAsync('yt-dlp', [
    '-f', 'bestaudio', '--no-playlist', '-o', audio, url,
  ], { timeout: 180000 });
  const { stdout } = await execFileAsync(ASR_PY, [ASR_SCRIPT, audio], {
    timeout: 1800000,
    maxBuffer: 64 * 1024 * 1024,
  });
  return stdout.trim();
}

function json(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function readBody(req, limit = 16 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('payload too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

    if (url.pathname === '/health') {
      return json(res, 200, {
        ok: true,
        model: MODEL,
        base: LLM_BASE,
        hasKey: !!(await apiKey()),
        dataDir: DATA_DIR,
      });
    }

    if (TOKEN && req.headers['x-token'] !== TOKEN) {
      return json(res, 401, { error: 'bad token' });
    }

    // GET /api/summary/<bvid>_<cid>
    const m = url.pathname.match(/^\/api\/summary\/([^/]+)$/);
    if (m && req.method === 'GET') {
      const [bvid, cid] = decodeURIComponent(m[1]).split('_');
      const hit = await readCache(bvid, cid || '');
      if (!hit) return json(res, 404, { error: 'no cache' });
      return json(res, 200, { ...hit, cached: true });
    }

    if (url.pathname === '/api/summary' && req.method === 'POST') {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        return json(res, 400, { error: 'bad json' });
      }
      const { bvid, cid = '', title = '', upName = '', subtitleText = '', force = false } = body || {};
      if (!bvid) return json(res, 400, { error: 'need bvid' });

      if (!force) {
        const hit = await readCache(bvid, cid);
        if (hit) return json(res, 200, { ...hit, cached: true });
      }

      let text = subtitleText;
      let source = 'subtitle';
      if (!text) {
        try {
          text = await transcribeFromUrl(bvid, cid);
          source = 'asr';
        } catch (e) {
          return json(res, 200, {
            ok: false,
            reason: 'no_subtitle',
            detail: String(e?.message || e).slice(0, 200),
          });
        }
      }
      if (!text || text.trim().length < 30) {
        return json(res, 200, { ok: false, reason: 'text_too_short' });
      }

      const summary = await summarize({ title, upName, text });
      const payload = {
        bvid, cid, title, upName,
        source,
        chars: text.length,
        summary,
        at: Date.now(),
        model: MODEL,
      };
      await writeCache(bvid, cid, payload);
      log(`summary ${bvid}_${cid} source=${source} chars=${text.length}`);
      return json(res, 200, { ...payload, cached: false });
    }

    return json(res, 404, { error: 'not found' });
  } catch (err) {
    log('ERROR', err?.stack || String(err));
    return json(res, 500, { error: String(err?.message || err) });
  }
});

server.listen(PORT, HOST, () => {
  log(`PiliPlus summary server on http://${HOST}:${PORT}`);
  log(`model: ${MODEL}  base: ${LLM_BASE}  cache: ${DATA_DIR}`);
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family === 'IPv4' && !a.internal) log(`LAN: http://${a.address}:${PORT}  (${name})`);
    }
  }
});
