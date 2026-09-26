import test from 'node:test';
import assert from 'node:assert/strict';
import {createApp} from '../server.js';
import WebSocket from 'ws';

const nextMessage = socket => new Promise((resolve, reject) => {
 socket.once('message', raw => resolve(JSON.parse(raw.toString())));
 socket.once('error', reject);
});
test('room authorization, synchronized strokes and undo',async()=>{
 const server=createApp();await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base=`http://127.0.0.1:${server.address().port}`;
 const post=async(path,data)=>{const r=await fetch(base+'/api/'+path,{method:'POST',body:JSON.stringify(data)});return {status:r.status,data:await r.json()};};
 const controller=new AbortController();
 try{
  const {data:{code}}=await post('create',{});assert.match(code,/^\d{6}$/);
  const {data:{id}}=await post('join',{code});
  assert.equal((await post('event',{code,id:'invalid',event:{type:'clear'}})).status,403);
  assert.equal((await post('join',{code:'no-room'})).status,404);
  const stroke={id:'s1',points:[[.1,.2,.5],[.2,.3,.7]],color:'#253342',width:4};
  assert.equal((await post('event',{code,id,event:{type:'stroke',stroke:{...stroke,points:[[2,0,0]]}}})).status,400);
  assert.equal((await post('event',{code,id,event:{type:'stroke',stroke}})).status,200);
  const {data:{id:viewer}}=await post('join',{code});
  const response=await fetch(`${base}/api/events?code=${code}&id=${viewer}`,{signal:controller.signal});
  const reader=response.body.getReader();const first=new TextDecoder().decode((await reader.read()).value);assert.ok(first.includes('s1'));assert.ok(first.includes('peers'));
  await post('event',{code,id,event:{type:'undo'}});
  const next=new TextDecoder().decode((await reader.read()).value);assert.ok(next.includes('"strokes":[]'));
  controller.abort();
 }finally{controller.abort();server.closeAllConnections();await new Promise(r=>server.close(r));}
});

test('native clients exchange strokes and screen frames over WebSocket',async()=>{
 const server=createApp();await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base=`http://127.0.0.1:${server.address().port}`;
 const post=async(path,data)=>{const r=await fetch(base+'/api/'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});return r.json();};
 let sender,receiver;
 try{
  const {code}=await post('create',{});
  const first=await post('join',{code});
  const second=await post('join',{code});
  sender=new WebSocket(`ws://127.0.0.1:${server.address().port}/ws?code=${code}&id=${first.id}`);
  receiver=new WebSocket(`ws://127.0.0.1:${server.address().port}/ws?code=${code}&id=${second.id}`);
  await Promise.all([new Promise(r=>sender.once('open',r)),new Promise(r=>receiver.once('open',r))]);
  await new Promise(r=>setTimeout(r,20));

  const stroke={type:'stroke',stroke:{id:'native-1',points:[[.1,.2,.3],[.4,.5,.8]],color:'#5965df',width:4}};
  const strokeReceived=new Promise((resolve,reject)=>{receiver.on('message',raw=>{const message=JSON.parse(raw);if(message.type==='stroke')resolve(message);});receiver.once('error',reject);});
  sender.send(JSON.stringify(stroke));
  assert.equal((await strokeReceived).stroke.id,'native-1');

  const frameReceived=new Promise((resolve,reject)=>{receiver.on('message',raw=>{const message=JSON.parse(raw);if(message.type==='frame')resolve(message);});receiver.once('error',reject);});
  sender.send(JSON.stringify({type:'frame',image:'data:image/jpeg;base64,/9j/2Q=='}));
  assert.equal((await frameReceived).image,'data:image/jpeg;base64,/9j/2Q==');
 }finally{
  sender?.close();receiver?.close();server.closeAllConnections();await new Promise(r=>server.close(r));
 }
});

test('board and screen layers erase and clear independently',async()=>{
 const server=createApp();await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base=`http://127.0.0.1:${server.address().port}`;
 const post=async(path,data)=>{const r=await fetch(base+'/api/'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});return {status:r.status,data:await r.json()};};
 try{
  const {data:{code}}=await post('create',{});const {data:{id}}=await post('join',{code});
  const stroke={points:[[.2,.2,.5],[.3,.3,.5]],color:'#253342',width:4};
  assert.equal((await post('event',{code,id,event:{type:'stroke',stroke:{...stroke,id:'board-stroke',layer:'board'}}})).status,200);
  assert.equal((await post('event',{code,id,event:{type:'stroke',stroke:{...stroke,id:'screen-stroke',layer:'screen'}}})).status,200);
  assert.equal((await post('event',{code,id,event:{type:'erase',layer:'screen',point:[.21,.21],radius:.03}})).status,200);
  const {data:{id:viewer}}=await post('join',{code});const controller=new AbortController();const response=await fetch(`${base}/api/events?code=${code}&id=${viewer}`,{signal:controller.signal});const reader=response.body.getReader();const state=new TextDecoder().decode((await reader.read()).value);controller.abort();assert.ok(state.includes('board-stroke'));assert.ok(!state.includes('screen-stroke'));
  assert.equal((await post('event',{code,id,event:{type:'background',image:'data:image/png;base64,iVBORw0KGgo='}})).status,200);
  assert.equal((await post('event',{code,id,event:{type:'clear',layer:'board'}})).status,200);
 }finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
});
