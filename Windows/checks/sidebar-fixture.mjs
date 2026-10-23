// Local-only sidebar acceptance fixture. No real Codex page is touched.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const html = String.raw`<!doctype html><html class="dark" lang="zh"><meta charset="utf-8"><title>PetsPet 侧栏本地验收</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#191919;color:#eee;font:15px 'Segoe UI',sans-serif}header{padding:20px;height:76px}button{padding:7px 14px;margin:0 6px 5px 0}main{display:flex;gap:22px;margin:0 20px}.shell{position:relative;width:344px;height:600px;background:#242424;border-radius:10px;display:flex}.rail{position:relative;width:52px;flex:none}.sidebar-item{position:absolute;bottom:20px;left:10px}.sidebar-item button{padding:0;border:0}.rounded-full{display:block;background:#609c99;width:32px;height:32px;border-radius:50%;color:white;line-height:32px}.sidebar{position:relative;width:292px;height:600px}.scroll{position:absolute;inset:15px 0 12px;overflow-y:auto}.row{height:42px;padding:12px;border-radius:6px}.row:nth-child(even){background:#303030}section{max-width:650px}pre{white-space:pre-wrap;line-height:1.8}h2{margin-top:0}.light{background:#fff;color:#222}.light .shell{background:#eee}.light .row:nth-child(even){background:#e4e4e4}
</style><header><button id="test">运行侧栏检查</button><button id="collapse">折叠 / 展开</button><button id="theme">深 / 浅色</button><button id="destroy">移除组件</button></header>
<main><div class="shell"><nav data-app-navigation-rail class="rail"><div class="sidebar-item"><button aria-label="测试账号"><span class="rounded-full" aria-hidden="true">EA</span></button></div></nav><aside data-sidebar-navigation-root class="sidebar"><div data-app-action-sidebar-scroll class="scroll"></div></aside></div><section><h2>侧栏本地验收页面</h2><p>固定演示数据，不是实际聊天或账号。</p><p>竖向组件位于 EA 头像正上方，不覆盖聊天列表；数字始终正向。</p><pre id="result">等待检查</pre></section></main>
<script src="/Sidebar.js"></script><script>
const root=document.querySelector('aside'), scroll=document.querySelector('.scroll'), output=document.querySelector('#result');
for(let i=1;i<=30;i++){let e=document.createElement('div');e.className='row';e.textContent='演示对话 '+i;scroll.append(e)}
const png=async name=>'data:image/png;base64,'+await fetch('/png?name='+name).then(r=>r.text());
const key='__petsPetWindowsQuotaV1';let payload;
const ready=Promise.all([png('dark'),png('light')]).then(([dark,light])=>{payload={dark,light,width:64,height:128,appearance:'dark'};window[key].configure(payload);scroll.scrollTop=scroll.scrollHeight});
const pause=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
const installed=()=>document.querySelector('[data-petspet-windows="quota"]');
const reinstall=async()=>{if(!window[key]){const text=await fetch('/Sidebar.js').then(r=>r.text());(0,eval)(text)}};
let testing=false;let heartbeat=setInterval(()=>{if(!testing&&window[key]&&payload)window[key].configure(payload)},2000);
document.querySelector('#collapse').onclick=()=>{root.hidden=!root.hidden};
document.querySelector('#theme').onclick=()=>{payload.appearance=payload.appearance==='dark'?'light':'dark';document.body.classList.toggle('light');window[key]?.configure(payload)};
document.querySelector('#destroy').onclick=()=>{clearInterval(heartbeat);window[key]?.destroy();output.textContent='已移除组件'};
document.querySelector('#test').onclick=async()=>{
 await ready;await reinstall();testing=true;let results=[];const check=(condition,name)=>{results.push({passed:!!condition,name});if(!condition)throw Error(name)};
 const rail=document.querySelector('.rail');
 try{
 root.hidden=false;rail.hidden=false;window[key].configure(payload);await pause();let slot=installed(),avatar=document.querySelector('.rounded-full');
 check(slot?.isConnected,'正常挂载');
 let rect=slot.querySelector('img').getBoundingClientRect(),account=avatar.getBoundingClientRect(),nav=rail.getBoundingClientRect();
 check(Math.abs(rect.bottom-account.top+10)<1,'位于头像上方并留10像素间隔');
 check(Math.abs((rect.left+rect.right)/2-(account.left+account.right)/2)<1,'与头像水平居中');
 check(rect.left>=nav.left&&rect.right<=nav.right,'不超出导航栏');
 check(Math.abs(rect.height/rect.width-2)<.01,'竖向比例正确');
 check(getComputedStyle(slot).pointerEvents==='none','鼠标穿透');
 check(!document.querySelector('[data-petspet-windows="spacer"]'),'聊天列表没有额外留白');
 check(rect.right<=root.getBoundingClientRect().left,'不遮挡聊天列表');
 root.hidden=true;await pause();check(!!installed(),'聊天列表折叠后仍跟随头像');
 root.hidden=false;rail.hidden=true;await pause();check(!installed(),'头像导航栏隐藏时隐藏组件');
 rail.hidden=false;await pause();check(!!installed(),'头像恢复后组件恢复');
 payload={...payload,width:40.96,height:81.92};window[key].configure(payload);await pause();
 check(Math.abs(installed().querySelector('img').getBoundingClientRect().height-81.92)<.1,'保留64%自定义大小');
 window[key].configure({...payload,dark:'https://example.com/forbidden.png'});await pause();check(!installed(),'拒绝网络图片');
 window[key].configure(payload);window[key].destroy();await pause();
 check(!installed()&&!window[key],'退出时清理组件');
 await reinstall();window[key].configure(payload);await pause();check(!!installed(),'重新连接恢复');
 output.textContent='全部 '+results.length+' 项通过\n'+results.map(r=>'✓ '+r.name).join('\n');
 }catch(e){output.textContent='检查失败：'+e.message+'\n'+JSON.stringify(results)}
 testing=false;await fetch('/result',{method:'POST',body:JSON.stringify(results)});
};
</script></html>`;
const server=http.createServer((req,res)=>{
 res.setHeader('Content-Type','text/html; charset=utf-8');
 if(req.url==='/Sidebar.js'){res.setHeader('Content-Type','text/javascript; charset=utf-8');res.end(fs.readFileSync(path.join(root,'Sidebar.js')));}
 else if(req.url.startsWith('/png?')){const theme=new URL(req.url,'http://127.0.0.1').searchParams.get('name');if(!['dark','light'].includes(theme)){res.writeHead(400).end();return}res.end(fs.readFileSync(path.join(root,'验收截图','视觉样本','样本_'+theme+'_sidebar_2.0.png')).toString('base64'));}
 else if(req.url==='/result'&&req.method==='POST'){let data='';req.on('data',c=>{data+=c;if(data.length>10000)req.destroy()});req.on('end',()=>{fs.writeFileSync(path.join(root,'data','sidebar-dom-check.json'),data);res.end('ok')})}
 else res.end(html);
});
server.listen(39223,'127.0.0.1',()=>console.log('Sidebar fixture http://127.0.0.1:39223'));

// Optional CDP transport fixture. Binds only the production loopback port, and
// never forwards traffic. Start explicitly with --cdp when the port is unused.
if(process.argv.includes('--cdp')){
 const cdp=http.createServer((req,res)=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify([{type:'page',url:'app://-/index.html',webSocketDebuggerUrl:'ws://127.0.0.1:39222/devtools/page/fixture'}]))});
 cdp.on('upgrade',(req,socket)=>{
  const accept=crypto.createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');
  let buffer=Buffer.alloc(0),message=[];
  const send=value=>{let data=Buffer.from(JSON.stringify(value));let head=Buffer.from([0x81,data.length]);socket.write(Buffer.concat([head,data]))};
  socket.on('error',()=>{});
  socket.on('data',chunk=>{buffer=Buffer.concat([buffer,chunk]);while(buffer.length>=2){const first=buffer[0];let size=buffer[1]&127,offset=2;if(size===126){if(buffer.length<4)return;size=buffer.readUInt16BE(2);offset=4}else if(size===127){if(buffer.length<10)return;size=Number(buffer.readBigUInt64BE(2));offset=10}if(size>2000000){socket.destroy();return}const masked=!!(buffer[1]&128);if(buffer.length<offset+(masked?4:0)+size)return;const mask=masked?buffer.subarray(offset,offset+4):null;offset+=masked?4:0;let frame=Buffer.from(buffer.subarray(offset,offset+size));buffer=buffer.subarray(offset+size);if(mask)for(let i=0;i<frame.length;i++)frame[i]^=mask[i%4];if((first&15)===8){socket.end();return}message.push(frame);if(first&128){const request=JSON.parse(Buffer.concat(message));message=[];send({method:'Runtime.testEvent'});const cleanup=request.params.expression.includes('removed:');send({id:request.id,result:{result:{type:'object',value:cleanup?{removed:true}:{mounted:true}}}})}}});
 });cdp.listen(39222,'127.0.0.1',()=>console.log('CDP transport fixture 127.0.0.1:39222'));
}
