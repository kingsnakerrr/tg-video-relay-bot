import fs from 'node:fs/promises';
import { GoogleAuth } from 'google-auth-library';
import { config } from './config.js';
import { getSetting } from './db.js';

type ServiceAccount = { client_email?: string; private_key?: string; project_id?: string; type?: string };

async function credentials() {
  let raw: string;
  try { raw = await fs.readFile(config.serviceAccountFile, 'utf8'); }
  catch { throw new Error('尚未保存 Google 服务账号 JSON'); }
  let parsed: ServiceAccount;
  try { parsed = JSON.parse(raw); } catch { throw new Error('服务账号 JSON 格式不正确'); }
  if (parsed.type !== 'service_account' || !parsed.client_email || !parsed.private_key) throw new Error('这不是有效的 Google 服务账号密钥');
  return parsed;
}

async function accessToken() {
  const auth = new GoogleAuth({ credentials: await credentials(), scopes: ['https://www.googleapis.com/auth/drive'] });
  const client = await auth.getClient();
  const token = await client.getAccessToken();
  if (!token.token) throw new Error('无法获取 Google API 访问令牌');
  return token.token;
}

function ids() {
  const sharedDriveId = getSetting('shared_drive_id');
  const folderId = getSetting('folder_id');
  if (!sharedDriveId || !folderId) throw new Error('请先配置团队盘 ID 和目录 ID');
  return { sharedDriveId, folderId };
}

export async function saveServiceAccount(value: unknown) {
  if (!value || typeof value !== 'object') throw new Error('服务账号 JSON 格式不正确');
  const account = value as ServiceAccount;
  if (account.type !== 'service_account' || !account.client_email || !account.private_key) throw new Error('这不是有效的 Google 服务账号密钥');
  await fs.writeFile(config.serviceAccountFile, JSON.stringify(account, null, 2), { encoding: 'utf8', mode: 0o600 });
  return account.client_email;
}

export async function getServiceAccountEmail() {
  try { return (JSON.parse(await fs.readFile(config.serviceAccountFile, 'utf8')) as ServiceAccount).client_email || null; }
  catch { return null; }
}

export async function uploadToDrive(buffer: Buffer, name: string, mimeType: string) {
  const { folderId } = ids();
  const boundary = `drivepic_${crypto.randomUUID()}`;
  const metadata = JSON.stringify({ name, parents: [folderId] });
  const head = Buffer.from(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n--${boundary}\r\nContent-Type: ${mimeType}\r\n\r\n`);
  const body = Buffer.concat([head, buffer, Buffer.from(`\r\n--${boundary}--`)]);
  const response = await fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true&fields=id,name,size,mimeType', {
    method: 'POST', headers: { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': `multipart/related; boundary=${boundary}` }, body,
  });
  if (!response.ok) throw new Error(`Google Drive 上传失败：${response.status} ${await response.text()}`);
  return await response.json() as { id: string };
}

export async function downloadFromDrive(fileId: string, range?: string) {
  const headers: Record<string, string> = { Authorization: `Bearer ${await accessToken()}` };
  if (range) headers.Range = range;
  return fetch(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media&supportsAllDrives=true`, { headers });
}

export async function deleteFromDrive(fileId: string) {
  const response = await fetch(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?supportsAllDrives=true`, { method: 'DELETE', headers: { Authorization: `Bearer ${await accessToken()}` } });
  if (!response.ok && response.status !== 404) throw new Error(`Google Drive 删除失败：${response.status}`);
}

export async function verifyDriveAccess() {
  const { sharedDriveId, folderId } = ids();
  const token = await accessToken();
  const drive = await fetch(`https://www.googleapis.com/drive/v3/drives/${encodeURIComponent(sharedDriveId)}?fields=id,name`, { headers: { Authorization: `Bearer ${token}` } });
  if (!drive.ok) throw new Error(`无法访问团队盘（${drive.status}）。请确认服务账号已加入团队盘。`);
  const folder = await fetch(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(folderId)}?supportsAllDrives=true&fields=id,name,mimeType,driveId`, { headers: { Authorization: `Bearer ${token}` } });
  if (!folder.ok) throw new Error(`无法访问目标目录（${folder.status}）。请检查目录 ID。`);
  const folderInfo = await folder.json() as { name: string; mimeType: string; driveId?: string };
  if (folderInfo.mimeType !== 'application/vnd.google-apps.folder' || folderInfo.driveId !== sharedDriveId) throw new Error('目标目录不在所选团队盘中');
  const driveInfo = await drive.json() as { id: string; name: string };
  return { ...driveInfo, folderName: folderInfo.name };
}
