#!/usr/bin/env node
/**
 * PiliPlus 设置同步服务（局域网）
 *
 * 按「配置名」保存 JSON 文件，同账号的多个客户端可以读取/写入任意配置名。
 *
 * 端点（全部带 `x-token` 头，除非 TOKEN 为空）：
 *   GET    /api/profiles                 列出所有配置
 *   GET    /api/profiles/<name>          读取配置
 *   PUT    /api/profiles/<name>          写入配置
 *        body: { dataRaw: "<json 字符串>", baseRev?: number, device?: string }
 *        也接受老客户端的 { data: {...} }（会被 JS 降级类型，见下）
 *        baseRev 与服务端当前 rev 不一致时返回 409 + 服务端当前内容
 *
 * ⚠️ 为什么数据是「字符串」而不是对象：
 *    JavaScript 只有一种 number，没有 int/double 之分。客户端传 1.0（double），
 *    只要过一遍 JSON.parse → JSON.stringify 就变成 1，客户端再解析就成了 int。
 *    Dart 是有 int/double 之分的，于是 `double get defaultTextScale` 读到 int 就抛
 *    `type 'int' is not a subtype of type 'double'`，MaterialApp 构建失败 → 整屏变灰
 *    （实测把 S20 的 dev 版搞成这样）。所以这里把 data 当**不透明字符串**存和返回，
 *    一个字节都不碰。
 *   DELETE /api/profiles/<name>          删除配置
 *   GET    /health                       健康检查
 *
 * 环境变量：
 *   PORT        监听端口，默认 8720
 *   TOKEN       共享口令；留空则不校验（仅限可信局域网）
 *   DATA_DIR    数据目录，默认 ~/.piliplus-settings
 *   HOST        监听地址，默认 0.0.0.0
 *
 * 零依赖，只用 Node 内置模块。
 */
import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const PORT = Number(process.env.PORT || 8720);
const TOKEN = process.env.TOKEN || '';
const HOST = process.env.HOST || '0.0.0.0';
const DATA_DIR =
  process.env.DATA_DIR || path.join(os.homedir(), '.piliplus-settings');

const NAME_RE = /^[A-Za-z0-9_\u4e00-\u9fa5.-]{1,64}$/;

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

async function ensureDir() {
  await fsp.mkdir(DATA_DIR, { recursive: true });
}

function fileOf(name) {
  return path.join(DATA_DIR, `${name}.json`);
}

async function readProfile(name) {
  try {
    const raw = await fsp.readFile(fileOf(name), 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
}

/**
 * 返回给客户端时统一带 dataRaw。
 * 老文件（只有 data 对象）在这里补一个 dataRaw —— 但它的类型已经被 JS 降级过，
 * 补出来的同样有损，客户端要自己按 types 清单纠正（源设备重新上传一次即可恢复）。
 */
function withRaw(p) {
  if (!p) return { dataRaw: null, data: null };
  const dataRaw = typeof p.dataRaw === 'string' ? p.dataRaw : JSON.stringify(p.data ?? {});
  let data = null;
  try {
    data = JSON.parse(dataRaw);
  } catch {
    data = null;
  }
  return { name: p.name, rev: p.rev, updatedAt: p.updatedAt, device: p.device, dataRaw, data };
}

async function writeProfile(name, payload) {
  const tmp = `${fileOf(name)}.tmp`;
  await fsp.writeFile(tmp, JSON.stringify(payload, null, 2), 'utf8');
  await fsp.rename(tmp, fileOf(name));
}

function json(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function readBody(req, limit = 8 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/health') {
      return json(res, 200, { ok: true, dataDir: DATA_DIR, profiles: await listNames() });
    }

    if (TOKEN && req.headers['x-token'] !== TOKEN) {
      return json(res, 401, { error: 'bad token' });
    }

    if (parts[0] !== 'api' || parts[1] !== 'profiles') {
      return json(res, 404, { error: 'not found' });
    }

    // /api/profiles
    if (parts.length === 2) {
      if (req.method === 'GET') {
        const names = await listNames();
        const profiles = [];
        for (const name of names) {
          const p = await readProfile(name);
          profiles.push({
            name,
            rev: p?.rev ?? 0,
            updatedAt: p?.updatedAt ?? 0,
            device: p?.device ?? '',
          });
        }
        profiles.sort((a, b) => b.updatedAt - a.updatedAt);
        return json(res, 200, { profiles });
      }
      return json(res, 405, { error: 'method not allowed' });
    }

    const name = decodeURIComponent(parts[2]);
    if (!NAME_RE.test(name)) {
      return json(res, 400, { error: 'bad profile name' });
    }

    if (req.method === 'GET') {
      const p = await readProfile(name);
      if (!p) return json(res, 404, { error: 'no such profile' });
      return json(res, 200, withRaw(p));
    }

    if (req.method === 'PUT') {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        return json(res, 400, { error: 'bad json body' });
      }
      // 首选 dataRaw（字符串，类型无损）；老客户端只有 data（对象，类型已被 JS 降级）
      let dataRaw;
      if (typeof body?.dataRaw === 'string') {
        dataRaw = body.dataRaw;
        try {
          JSON.parse(dataRaw); // 只做合法性校验，不保留解析结果
        } catch {
          return json(res, 400, { error: 'dataRaw must be valid json' });
        }
      } else if (typeof body?.data === 'object' && body.data !== null) {
        dataRaw = JSON.stringify(body.data);
      } else {
        return json(res, 400, { error: 'need dataRaw (string) or data (object)' });
      }
      const cur = await readProfile(name);
      const curRev = cur?.rev ?? 0;
      if (typeof body.baseRev === 'number' && body.baseRev !== curRev) {
        return json(res, 409, {
          error: 'rev conflict',
          rev: curRev,
          updatedAt: cur?.updatedAt ?? 0,
          device: cur?.device ?? '',
          ...withRaw(cur),
        });
      }
      const next = {
        name,
        rev: curRev + 1,
        updatedAt: Date.now(),
        device: String(body.device ?? '').slice(0, 64),
        dataRaw,
      };
      await writeProfile(name, next);
      log(`PUT ${name} rev=${next.rev} bytes=${dataRaw.length}`);
      return json(res, 200, { name, rev: next.rev, updatedAt: next.updatedAt });
    }

    if (req.method === 'DELETE') {
      try {
        await fsp.unlink(fileOf(name));
      } catch (err) {
        if (err.code !== 'ENOENT') throw err;
      }
      log(`DELETE ${name}`);
      return json(res, 200, { ok: true });
    }

    return json(res, 405, { error: 'method not allowed' });
  } catch (err) {
    log('ERROR', err?.stack || String(err));
    return json(res, 500, { error: String(err?.message || err) });
  }
});

async function listNames() {
  const entries = await fsp.readdir(DATA_DIR, { withFileTypes: true });
  return entries
    .filter((e) => e.isFile() && e.name.endsWith('.json'))
    .map((e) => e.name.slice(0, -5));
}

await ensureDir();
server.listen(PORT, HOST, () => {
  log(`PiliPlus settings server on http://${HOST}:${PORT}`);
  log(`data dir: ${DATA_DIR}  token: ${TOKEN ? 'set' : 'NOT set'}`);
  const nets = os.networkInterfaces();
  for (const [name, addrs] of Object.entries(nets)) {
    for (const a of addrs ?? []) {
      if (a.family === 'IPv4' && !a.internal) {
        log(`LAN: http://${a.address}:${PORT}  (${name})`);
      }
    }
  }
});
