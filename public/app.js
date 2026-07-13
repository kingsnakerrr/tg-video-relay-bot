const $ = (s) => document.querySelector(s);
const setup = $('#setup'), login = $('#login'), shell = $('#app'), gallery = $('#gallery'), queue = $('#queue');
let period = 'month', page = 1, total = 0, loaded = 0;
const isAdminPath = location.pathname.startsWith('/admin');
let currentRole = null;

async function api(url, options = {}) {
  const res = await fetch(url, options);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const error=new Error(data.error || '请求失败'); error.status=res.status; throw error; }
  return data;
}
function toast(message) { const el = $('#toast'); el.textContent = message; el.classList.add('show'); clearTimeout(toast.t); toast.t = setTimeout(() => el.classList.remove('show'), 1800); }
function formatBytes(n) { if (!n) return '0 B'; const u=['B','KB','MB','GB']; const i=Math.min(3,Math.floor(Math.log(n)/Math.log(1024))); return `${(n/1024**i).toFixed(i?1:0)} ${u[i]}`; }
function formatDate(s) { return new Intl.DateTimeFormat('zh-CN',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}).format(new Date(s)); }
function escapeHtml(s){ const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }

async function boot() {
  setup.classList.add('hidden'); login.classList.add('hidden'); shell.classList.add('hidden');
  try {
    const status=await api('/api/status');
    if(isAdminPath && status.role!=='admin') return showLogin(true);
    if(isAdminPath && !status.configured){const front=new URL(location.origin);front.port='7078';if(!$('#setup-url').value)$('#setup-url').value=front.origin;setup.classList.remove('hidden');return}
    if(!isAdminPath && !status.configured) return showLogin(false,'系统等待管理员完成网盘配置。');
    if(!status.role) return showLogin(false);
    const me = await api('/api/me'); currentRole=me.role; $('#max-size').textContent = me.maxUploadMb; $('#ttl').value = String(me.defaultTtlDays); $('#role-badge').innerHTML=`<i></i>${me.role==='admin'?'管理员':'账号 '+escapeHtml(me.username)}`; $('#open-settings').classList.toggle('hidden',me.role!=='admin'); shell.classList.remove('hidden'); loadImages(true);
  } catch { login.classList.remove('hidden'); }
}
function showLogin(admin,message=''){$('#username').value=admin?'admin':'';$('#username').readOnly=admin;$('#login-title').innerHTML=admin?'后台管理，<br><span>一切尽在掌握。</span>':'你的图片，<br><span>干净地抵达。</span>';$('#login-subtitle').textContent=message||(admin?'使用安装时生成的管理员账号密码登录。':'输入前端账号和密码，进入私人图床。');login.classList.remove('hidden');setTimeout(()=>admin?$('#password').focus():$('#username').focus(),50)}
$('#setup-json-file').onchange=async()=>{const file=$('#setup-json-file').files[0];if(file)$('#setup-json').value=await file.text()};
$('#setup-form').addEventListener('submit',async e=>{e.preventDefault();const error=$('#setup-error');error.textContent='正在连接 Google 团队盘…';let serviceAccount;try{serviceAccount=JSON.parse($('#setup-json').value)}catch{error.textContent='服务账号 JSON 格式不正确';return}try{const data=await api('/api/setup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({appUrl:$('#setup-url').value,adminUrl:location.origin,sharedDriveId:$('#setup-drive').value,folderId:$('#setup-folder').value,serviceAccount})});toast(`已连接：${data.drive.name}`);boot()}catch(err){error.textContent=err.message}});
$('#login-form').addEventListener('submit', async e => { e.preventDefault(); $('#login-error').textContent=''; try { await api(isAdminPath?'/api/admin-login':'/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:$('#username').value,password:$('#password').value})}); $('#password').value=''; boot(); } catch(err){ $('#login-error').textContent=err.message; } });
$('#logout').addEventListener('click', async()=>{await api('/api/logout',{method:'POST'}); location.reload()});
$('#open-settings').addEventListener('click',async()=>{try{const s=await api('/api/settings');$('#settings-url').value=s.appUrl;$('#settings-drive').value=s.sharedDriveId;$('#settings-folder').value=s.folderId;$('#settings-ttl').value=String(s.defaultTtlDays);$('#settings-email').textContent=s.serviceAccountEmail?`当前：${s.serviceAccountEmail}`:'尚未保存密钥';$('#settings-json').value='';$('#current-password').value='';$('#new-password').value='';$('#settings-error').textContent='';await loadUsers();$('#settings-dialog').showModal()}catch(err){toast(err.message)}});
$('#close-settings').onclick=()=>$('#settings-dialog').close();
$('#settings-form').addEventListener('submit',async e=>{e.preventDefault();const body={appUrl:$('#settings-url').value,sharedDriveId:$('#settings-drive').value,folderId:$('#settings-folder').value,defaultTtlDays:Number($('#settings-ttl').value)};if($('#settings-json').value.trim()){try{body.serviceAccount=JSON.parse($('#settings-json').value)}catch{$('#settings-error').textContent='新的服务账号 JSON 格式不正确';return}}if($('#new-password').value){body.currentPassword=$('#current-password').value;body.newPassword=$('#new-password').value}$('#settings-error').textContent='正在测试连接…';try{const data=await api('/api/settings',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});$('#settings-dialog').close();toast(`设置已保存 · ${data.drive.name}`);$('#ttl').value=String(body.defaultTtlDays)}catch(err){ $('#settings-error').textContent=err.message }});
async function loadUsers(){const data=await api('/api/users');$('#user-list').innerHTML=data.items.length?data.items.map(u=>`<div><span><b>${escapeHtml(u.username)}</b><small>${formatDate(u.createdAt)}</small></span><button type="button" data-user-id="${u.id}">删除</button></div>`).join(''):'<p class="form-help">还没有前端账号，请先创建一个。</p>';$('#user-list').querySelectorAll('button').forEach(b=>b.onclick=async()=>{if(!confirm('删除这个前端账号？其现有登录会立即失效。'))return;await api(`/api/users/${b.dataset.userId}`,{method:'DELETE'});loadUsers()})}
$('#save-user').onclick=async()=>{const username=$('#new-user').value,password=$('#new-user-password').value;if(!username||!password)return toast('请填写前端账号和密码');try{await api('/api/users',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password})});$('#new-user').value='';$('#new-user-password').value='';toast('前端账号已保存');loadUsers()}catch(err){toast(err.message)}};

async function loadImages(reset=false) {
  if(reset){page=1;loaded=0;gallery.innerHTML='<div class="empty">正在从团队盘整理记录…</div>'}
  try{
    const data=await api(`/api/images?period=${period}&page=${page}&limit=24`); total=data.total;
    if(reset) gallery.innerHTML=''; data.items.forEach(addCard); loaded+=data.items.length;
    $('#stat-count').textContent=data.total.toLocaleString(); $('#stat-size').textContent=formatBytes(data.bytes); $('#stat-views').textContent=data.views.toLocaleString();
    $('#load-more').classList.toggle('hidden',loaded>=total);
    if(!data.items.length&&reset) gallery.innerHTML='<div class="empty">这个时间段还没有图片，第一张就从上面开始。</div>';
  }catch(err){ if(err.message==='请先登录') return boot(); gallery.innerHTML=`<div class="empty">${escapeHtml(err.message)}</div>`; }
}
function addCard(item){
  const el=document.createElement('article'); el.className='image-card'; el.dataset.id=item.id;
  el.innerHTML=`<div class="image-preview"><img src="${item.url}" loading="lazy" alt=""><span class="views">${item.views} views</span></div><div class="image-info"><p class="image-name" title="${escapeHtml(item.name)}">${escapeHtml(item.name)}</p><p class="image-meta">${item.width||'?'} × ${item.height||'?'} · ${formatBytes(item.size)} · ${formatDate(item.createdAt)}</p><div class="card-actions"><button class="copy">复制链接</button>${currentRole==='admin'?'<button class="delete" title="删除图片">删除</button>':''}</div></div>`;
  el.querySelector('.copy').onclick=()=>copy(item.url);
  if(el.querySelector('.delete'))el.querySelector('.delete').onclick=async()=>{ if(!confirm(`永久删除“${item.name}”？团队盘原文件也会删除。`))return; try{await api(`/api/images/${item.id}`,{method:'DELETE'});el.remove();total--;$('#stat-count').textContent=total;toast('已永久删除')}catch(err){toast(err.message)} };
  gallery.append(el);
}
async function copy(text){ try{await navigator.clipboard.writeText(text);toast('链接已复制')}catch{const ta=document.createElement('textarea');ta.value=text;document.body.append(ta);ta.select();document.execCommand('copy');ta.remove();toast('链接已复制')} }
$('#periods').addEventListener('click',e=>{const b=e.target.closest('button');if(!b)return;period=b.dataset.period;$('#periods .active').classList.remove('active');b.classList.add('active');loadImages(true)});
$('#load-more').onclick=()=>{page++;loadImages(false)};

const drop=$('#dropzone'), input=$('#file-input');
$('#choose-file').onclick=e=>{e.stopPropagation();input.click()}; drop.onclick=e=>{if(!e.target.closest('button'))input.click()};
drop.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();input.click()}};
['dragenter','dragover'].forEach(n=>drop.addEventListener(n,e=>{e.preventDefault();drop.classList.add('drag')})); ['dragleave','drop'].forEach(n=>drop.addEventListener(n,e=>{e.preventDefault();drop.classList.remove('drag')}));
drop.addEventListener('drop',e=>upload([...e.dataTransfer.files])); input.onchange=()=>{upload([...input.files]);input.value=''};
document.addEventListener('paste',e=>{if(shell.classList.contains('hidden')||['INPUT','TEXTAREA'].includes(document.activeElement?.tagName))return;const files=[...e.clipboardData.items].filter(i=>i.kind==='file'&&i.type.startsWith('image/')).map(i=>i.getAsFile()).filter(Boolean);if(files.length)upload(files)});

async function upload(files){
  files=files.filter(f=>f.type.startsWith('image/')); if(!files.length)return toast('没有找到可上传的图片');
  for(const file of files){
    const row=document.createElement('div');row.className='queue-item';const local=URL.createObjectURL(file);row.innerHTML=`<img src="${local}" alt=""><div><p>${escapeHtml(file.name||'粘贴的图片')}</p><small>${formatBytes(file.size)} · 正在送往团队盘</small></div><div class="progress"><i></i></div>`;queue.prepend(row);
    const fd=new FormData();fd.append('ttlDays',$('#ttl').value);fd.append('file',file,file.name||`pasted-${Date.now()}.png`);
    try{const data=await api('/api/upload',{method:'POST',body:fd});const item=data.items[0];row.classList.add('done');row.querySelector('small').textContent='上传完成 · 链接已就绪';row.querySelector('.progress').outerHTML=`<div class="queue-actions"><button class="markdown">Markdown</button><button class="primary">复制链接</button></div>`;row.querySelector('.primary').onclick=()=>copy(item.url);row.querySelector('.markdown').onclick=()=>copy(`![${item.name}](${item.url})`);setTimeout(()=>URL.revokeObjectURL(local),5000);loadImages(true)}catch(err){row.querySelector('small').textContent=err.message;row.querySelector('.progress').remove();row.style.borderLeft='4px solid var(--orange)'}
  }
}
boot();
