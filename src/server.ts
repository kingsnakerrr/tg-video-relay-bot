import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { Readable } from 'node:stream';
import path from 'node:path';
import Fastify, { type FastifyRequest } from 'fastify';
import cookie from '@fastify/cookie';
import multipart from '@fastify/multipart';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import sharp from 'sharp';
import { config } from './config.js';
import db, { getSetting, isConfigured, setSetting, type ImageRow } from './db.js';
import { deleteFromDrive, downloadFromDrive, getServiceAccountEmail, saveServiceAccount, uploadToDrive, verifyDriveAccess } from './drive.js';

const app = Fastify({ logger: true, trustProxy: config.trustProxy, bodyLimit: config.maxUploadBytes + 1024 * 1024 });
await app.register(cookie, { secret: config.cookieSecret, hook: 'onRequest' });
await app.register(rateLimit, { global: false });
await app.register(multipart, {
  limits: { fileSize: config.maxUploadBytes, files: 20, fields: 10 },
});
await app.register(fastifyStatic, { root: path.resolve('public'), wildcard: false });

const supported = new Set(['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif']);
const sessionName = 'drivepic_session';

function hashPassword(password: string) {
  const salt = crypto.randomBytes(16).toString('hex');
  return `${salt}:${crypto.scryptSync(password, salt, 64).toString('hex')}`;
}

function verifyHash(password: string, stored: string | null) {
  if (!stored) return false;
  const [salt, expected] = stored.split(':');
  if (!salt || !expected) return false;
  const actual = crypto.scryptSync(password, salt, 64);
  const expectedBuffer = Buffer.from(expected, 'hex');
  return actual.length === expectedBuffer.length && crypto.timingSafeEqual(actual, expectedBuffer);
}

if (!getSetting('admin_password_hash')) {
  setSetting('admin_password_hash', hashPassword(config.initialAdminPassword));
}

function cleanAppUrl(value: string) {
  const parsed = new URL(value.trim());
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('访问域名必须以 http:// 或 https:// 开头');
  if (parsed.pathname !== '/' || parsed.search || parsed.hash) throw new Error('访问域名不能包含路径或参数');
  return parsed.origin;
}

function getSession(request: FastifyRequest) {
  const raw = request.cookies[sessionName];
  if (!raw) return null;
  const unsigned = request.unsignCookie(raw);
  if (!unsigned.valid || !unsigned.value) return null;
  const parts = unsigned.value.split(':');
  if (parts[0] === 'admin' && Number(parts[1]) > Date.now() - 30 * 24 * 3600 * 1000) return { role: 'admin' as const, userId: null };
  if (parts[0] === 'user' && Number(parts[2]) > Date.now() - 30 * 24 * 3600 * 1000) {
    const user = db.prepare('SELECT id, username FROM users WHERE id = ? AND enabled = 1').get(Number(parts[1])) as { id: number; username: string } | undefined;
    if (user) return { role: 'user' as const, userId: user.id, username: user.username };
  }
  return null;
}

async function requireAdmin(request: FastifyRequest, reply: any) {
  if (getSession(request)?.role !== 'admin') return reply.code(401).send({ error: '请先登录管理员后台' });
  if (!['GET', 'HEAD', 'OPTIONS'].includes(request.method)) {
    const origin = request.headers.origin;
    const adminUrl = getSetting('admin_url') || getSetting('app_url');
    if (isConfigured() && origin && adminUrl && origin !== adminUrl) return reply.code(403).send({ error: '请求来源不可信，请从配置的后台地址访问' });
  }
}

async function requireUser(request: FastifyRequest, reply: any) {
  if (!isConfigured()) return reply.code(428).send({ error: '系统尚未完成网盘配置' });
  if (!getSession(request)) return reply.code(401).send({ error: '请先登录' });
}

function publicItem(row: ImageRow) {
  const safeName = encodeURIComponent(row.original_name.replace(/[\\/]/g, '_'));
  const url = `${getSetting('app_url')}/i/${row.token}/${safeName}`;
  return {
    id: row.id, name: row.original_name, mimeType: row.mime_type, width: row.width,
    height: row.height, size: row.size, createdAt: row.created_at, expiresAt: row.expires_at,
    views: row.views, url,
  };
}

function startFor(period: string) {
  const now = new Date();
  if (period === 'today') now.setHours(0, 0, 0, 0);
  else if (period === 'week') {
    const day = now.getDay() || 7;
    now.setDate(now.getDate() - day + 1); now.setHours(0, 0, 0, 0);
  } else if (period === 'month') {
    now.setDate(1); now.setHours(0, 0, 0, 0);
  } else return null;
  return now.toISOString();
}

app.get('/health', async () => ({ ok: true }));

app.get('/api/status', async (request) => ({
  configured: isConfigured(),
  role: getSession(request)?.role || null,
}));

app.post('/api/setup', { preHandler: requireAdmin, config: { rateLimit: { max: 10, timeWindow: '15 minutes' } } }, async (request, reply) => {
  if (isConfigured()) return reply.code(409).send({ error: '首次配置已经完成，请登录后在设置中修改' });
  const body = request.body as { appUrl?: string; adminUrl?: string; sharedDriveId?: string; folderId?: string; serviceAccount?: unknown } | null;
  if (!body) return reply.code(400).send({ error: '没有收到配置' });
  if (!body.sharedDriveId?.trim() || !body.folderId?.trim()) return reply.code(400).send({ error: '请填写团队盘 ID 和目标目录 ID' });
  let appUrl: string; let adminUrl: string;
  try { appUrl = cleanAppUrl(body.appUrl || ''); adminUrl = cleanAppUrl(body.adminUrl || ''); } catch (error: any) { return reply.code(400).send({ error: error.message }); }
  try {
    await saveServiceAccount(body.serviceAccount);
    setSetting('app_url', appUrl);
    setSetting('admin_url', adminUrl);
    setSetting('shared_drive_id', body.sharedDriveId.trim());
    setSetting('folder_id', body.folderId.trim());
    setSetting('default_ttl_days', '0');
    const drive = await verifyDriveAccess();
    setSetting('setup_complete', '1');
    return { ok: true, drive };
  } catch (error: any) { return reply.code(400).send({ error: error.message }); }
});

app.post('/api/admin-login', { config: { rateLimit: { max: 8, timeWindow: '15 minutes' } } }, async (request, reply) => {
  const body = request.body as { username?: string; password?: string } | null;
  if (body?.username !== 'admin' || !body.password || !verifyHash(body.password, getSetting('admin_password_hash'))) {
    await new Promise((resolve) => setTimeout(resolve, 350));
    return reply.code(401).send({ error: '管理员账号或密码不正确' });
  }
  reply.setCookie(sessionName, `admin:${Date.now()}`, {
    path: '/', httpOnly: true, secure: request.protocol === 'https', sameSite: 'strict', signed: true, maxAge: 30 * 24 * 3600,
  });
  return { ok: true };
});

app.post('/api/login', { config: { rateLimit: { max: 8, timeWindow: '15 minutes' } } }, async (request, reply) => {
  if (!isConfigured()) return reply.code(428).send({ error: '请先完成首次配置' });
  const body = request.body as { username?: string; password?: string } | null;
  const user = body?.username ? db.prepare('SELECT id, username, password_hash FROM users WHERE username = ? AND enabled = 1').get(body.username.trim()) as { id: number; username: string; password_hash: string } | undefined : undefined;
  if (!user || !body?.password || !verifyHash(body.password, user.password_hash)) {
    await new Promise((resolve) => setTimeout(resolve, 350));
    return reply.code(401).send({ error: '账号或密码不正确' });
  }
  reply.setCookie(sessionName, `user:${user.id}:${Date.now()}`, {
    path: '/', httpOnly: true, secure: request.protocol === 'https', sameSite: 'strict', signed: true, maxAge: 30 * 24 * 3600,
  });
  return { ok: true };
});

app.post('/api/logout', async (_request, reply) => {
  reply.clearCookie(sessionName, { path: '/' });
  return { ok: true };
});

app.get('/api/me', async (request, reply) => {
  if (!isConfigured()) return reply.code(428).send({ configured: false });
  const session = getSession(request);
  if (!session) return reply.code(401).send({ authenticated: false });
  return { authenticated: true, role: session.role, username: 'username' in session ? session.username : 'admin', maxUploadMb: config.maxUploadBytes / 1024 / 1024, defaultTtlDays: Number(getSetting('default_ttl_days') || 0) };
});

app.get('/api/settings', { preHandler: requireAdmin }, async () => ({
  appUrl: getSetting('app_url'), sharedDriveId: getSetting('shared_drive_id'), folderId: getSetting('folder_id'),
  serviceAccountEmail: await getServiceAccountEmail(), defaultTtlDays: Number(getSetting('default_ttl_days') || 0),
}));

app.put('/api/settings', { preHandler: requireAdmin }, async (request, reply) => {
  const body = request.body as { appUrl?: string; sharedDriveId?: string; folderId?: string; serviceAccount?: unknown; defaultTtlDays?: number; currentPassword?: string; newPassword?: string } | null;
  if (!body) return reply.code(400).send({ error: '没有收到设置' });
  if (body.newPassword) {
    if (!body.currentPassword || !verifyHash(body.currentPassword, getSetting('admin_password_hash'))) return reply.code(403).send({ error: '当前管理员密码不正确' });
    if (body.newPassword.length < 10) return reply.code(400).send({ error: '新密码至少需要 10 位' });
  }
  const old = {
    appUrl: getSetting('app_url') || '', sharedDriveId: getSetting('shared_drive_id') || '',
    folderId: getSetting('folder_id') || '', ttl: getSetting('default_ttl_days') || '0',
    serviceAccount: await fs.readFile(config.serviceAccountFile, 'utf8').catch(() => null),
  };
  try {
    if (body.appUrl !== undefined) setSetting('app_url', cleanAppUrl(body.appUrl));
    if (body.sharedDriveId !== undefined) setSetting('shared_drive_id', body.sharedDriveId.trim());
    if (body.folderId !== undefined) setSetting('folder_id', body.folderId.trim());
    if (body.defaultTtlDays !== undefined) setSetting('default_ttl_days', String(Math.max(0, Math.min(3650, Number(body.defaultTtlDays) || 0))));
    if (body.serviceAccount) await saveServiceAccount(body.serviceAccount);
    const drive = await verifyDriveAccess();
    if (body.newPassword) {
      setSetting('admin_password_hash', hashPassword(body.newPassword));
      await fs.writeFile(path.join(config.dataDir, '.admin-password'), body.newPassword, { encoding: 'utf8', mode: 0o600 });
    }
    return { ok: true, drive };
  } catch (error: any) {
    setSetting('app_url', old.appUrl); setSetting('shared_drive_id', old.sharedDriveId);
    setSetting('folder_id', old.folderId); setSetting('default_ttl_days', old.ttl);
    if (old.serviceAccount) await fs.writeFile(config.serviceAccountFile, old.serviceAccount, { encoding: 'utf8', mode: 0o600 });
    return reply.code(400).send({ error: error.message });
  }
});

app.get('/api/users', { preHandler: requireAdmin }, async () => ({
  items: db.prepare('SELECT id, username, enabled, created_at AS createdAt FROM users ORDER BY created_at DESC').all(),
}));

app.post('/api/users', { preHandler: requireAdmin }, async (request, reply) => {
  const body = request.body as { username?: string; password?: string } | null;
  const username = body?.username?.trim() || '';
  if (!/^[\p{L}\p{N}_.-]{3,32}$/u.test(username) || username.toLowerCase() === 'admin') return reply.code(400).send({ error: '前端账号需为 3–32 位文字、数字、点、横线或下划线，且不能使用 admin' });
  if (!body?.password || body.password.length < 8) return reply.code(400).send({ error: '前端密码至少需要 8 位' });
  db.prepare(`INSERT INTO users (username, password_hash, enabled, created_at) VALUES (?, ?, 1, ?)
    ON CONFLICT(username) DO UPDATE SET password_hash=excluded.password_hash, enabled=1`)
    .run(username, hashPassword(body.password), new Date().toISOString());
  return { ok: true };
});

app.delete('/api/users/:id', { preHandler: requireAdmin }, async (request, reply) => {
  const { id } = request.params as { id: string };
  const result = db.prepare('DELETE FROM users WHERE id = ?').run(Number(id));
  if (!result.changes) return reply.code(404).send({ error: '前端账号不存在' });
  return { ok: true };
});

app.post('/api/upload', { preHandler: requireUser, config: { rateLimit: { max: 60, timeWindow: '1 minute' } } }, async (request, reply) => {
  const results = [];
  let ttlDays = Number(getSetting('default_ttl_days') || 0);
  const parts = request.parts();
  for await (const part of parts) {
    if (part.type === 'field') {
      if (part.fieldname === 'ttlDays') ttlDays = Math.max(0, Math.min(3650, Number(part.value) || 0));
      continue;
    }
    const buffer = await part.toBuffer();
    if (!supported.has(part.mimetype)) return reply.code(415).send({ error: `不支持 ${part.mimetype}，请上传 JPG、PNG、WebP、GIF 或 AVIF` });
    let meta;
    try { meta = await sharp(buffer, { animated: true }).metadata(); }
    catch { return reply.code(415).send({ error: `${part.filename} 不是有效图片` }); }
    if (!meta.format) return reply.code(415).send({ error: `${part.filename} 不是有效图片` });

    const driveName = `${new Date().toISOString().slice(0, 10)}/${crypto.randomUUID()}-${part.filename.replace(/[^\p{L}\p{N}._-]+/gu, '_')}`;
    const drive = await uploadToDrive(buffer, driveName, part.mimetype);
    const now = new Date();
    const expiresAt = ttlDays ? new Date(now.getTime() + ttlDays * 86400_000).toISOString() : null;
    const token = crypto.randomBytes(24).toString('base64url');
    const info = db.prepare(`INSERT INTO images
      (token, drive_file_id, original_name, mime_type, width, height, size, created_at, expires_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
        token, drive.id, part.filename, part.mimetype, meta.width || null, meta.height || null,
        buffer.length, now.toISOString(), expiresAt,
      );
    const row = db.prepare('SELECT * FROM images WHERE id = ?').get(info.lastInsertRowid) as ImageRow;
    results.push(publicItem(row));
  }
  if (!results.length) return reply.code(400).send({ error: '没有收到图片文件' });
  return { items: results };
});

app.get('/api/images', { preHandler: requireUser }, async (request) => {
  const { period = 'month', page = '1', limit = '24' } = request.query as Record<string, string>;
  const start = startFor(period);
  const perPage = Math.max(1, Math.min(100, Number(limit) || 24));
  const offset = (Math.max(1, Number(page) || 1) - 1) * perPage;
  const where = `deleted_at IS NULL${start ? ' AND created_at >= ?' : ''}`;
  const params = start ? [start] : [];
  const rows = db.prepare(`SELECT * FROM images WHERE ${where} ORDER BY created_at DESC LIMIT ? OFFSET ?`).all(...params, perPage, offset) as ImageRow[];
  const count = db.prepare(`SELECT COUNT(*) AS n, COALESCE(SUM(size),0) AS bytes, COALESCE(SUM(views),0) AS views FROM images WHERE ${where}`).get(...params) as { n: number; bytes: number; views: number };
  return { items: rows.map(publicItem), total: count.n, bytes: count.bytes, views: count.views, page: Math.floor(offset / perPage) + 1, limit: perPage };
});

app.delete('/api/images/:id', { preHandler: requireAdmin }, async (request, reply) => {
  const { id } = request.params as { id: string };
  const row = db.prepare('SELECT * FROM images WHERE id = ? AND deleted_at IS NULL').get(Number(id)) as ImageRow | undefined;
  if (!row) return reply.code(404).send({ error: '图片不存在' });
  await deleteFromDrive(row.drive_file_id);
  db.prepare('UPDATE images SET deleted_at = ? WHERE id = ?').run(new Date().toISOString(), row.id);
  return { ok: true };
});

app.get('/i/:token/*', { config: { rateLimit: { max: 240, timeWindow: '1 minute' } } }, async (request, reply) => {
  const { token } = request.params as { token: string };
  const row = db.prepare('SELECT * FROM images WHERE token = ? AND deleted_at IS NULL').get(token) as ImageRow | undefined;
  if (!row || (row.expires_at && new Date(row.expires_at) <= new Date())) return reply.code(404).type('text/plain').send('Image not found');
  const remote = await downloadFromDrive(row.drive_file_id, request.headers.range);
  if (!remote.ok && remote.status !== 206) return reply.code(remote.status).type('text/plain').send('Image temporarily unavailable');
  db.prepare('UPDATE images SET views = views + 1, last_viewed_at = ? WHERE id = ?').run(new Date().toISOString(), row.id);
  reply.code(remote.status).type(row.mime_type);
  reply.header('X-Content-Type-Options', 'nosniff');
  reply.header('Content-Disposition', `inline; filename*=UTF-8''${encodeURIComponent(row.original_name)}`);
  reply.header('Cache-Control', row.expires_at ? 'public, max-age=3600' : 'public, max-age=86400, stale-while-revalidate=604800');
  for (const header of ['content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
    const value = remote.headers.get(header); if (value) reply.header(header, value);
  }
  if (!remote.body) return reply.send();
  return reply.send(Readable.fromWeb(remote.body as any));
});

app.setNotFoundHandler((request, reply) => {
  if (request.url.startsWith('/api/') || request.url.startsWith('/i/')) return reply.code(404).send({ error: 'Not found' });
  return reply.sendFile('index.html');
});

app.setErrorHandler((error: any, _request, reply) => {
  app.log.error(error);
  if (error.code === 'FST_REQ_FILE_TOO_LARGE') return reply.code(413).send({ error: `图片超过 ${config.maxUploadBytes / 1024 / 1024}MB` });
  return reply.code(error.statusCode || 500).send({ error: error.statusCode && error.statusCode < 500 ? error.message : '服务器暂时开小差了' });
});

app.listen({ host: '0.0.0.0', port: config.port }).then(async () => {
  if (!isConfigured()) {
    app.log.warn('First run: sign in at /admin with the generated admin credentials, then configure Google Drive.');
    return;
  }
  try { const drive = await verifyDriveAccess(); app.log.info(`Connected to Shared Drive: ${drive.name}`); }
  catch (error) { app.log.error(error, 'Google Drive check failed; open Settings to correct the configuration'); }
});
