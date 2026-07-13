import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const dataDir = path.resolve(process.env.DATA_DIR || 'data');
fs.mkdirSync(dataDir, { recursive: true });

function persistentSecret() {
  const file = path.join(dataDir, '.cookie-secret');
  if (process.env.COOKIE_SECRET?.trim()) return process.env.COOKIE_SECRET.trim();
  try { return fs.readFileSync(file, 'utf8').trim(); }
  catch {
    const secret = crypto.randomBytes(48).toString('base64url');
    fs.writeFileSync(file, secret, { encoding: 'utf8', mode: 0o600 });
    return secret;
  }
}

function persistentAdminPassword() {
  const file = path.join(dataDir, '.admin-password');
  try { return fs.readFileSync(file, 'utf8').trim(); }
  catch {
    const password = crypto.randomBytes(18).toString('base64url');
    fs.writeFileSync(file, password, { encoding: 'utf8', mode: 0o600 });
    return password;
  }
}

export const config = {
  port: Number(process.env.PORT || 3000),
  cookieSecret: persistentSecret(),
  initialAdminPassword: persistentAdminPassword(),
  maxUploadBytes: Number(process.env.MAX_UPLOAD_MB || 25) * 1024 * 1024,
  trustProxy: process.env.TRUST_PROXY !== 'false',
  dataDir,
  serviceAccountFile: path.join(dataDir, 'google-service-account.json'),
};
