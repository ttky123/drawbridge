import http from 'node:http';
import { randomInt, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { WebSocket, WebSocketServer } from 'ws';

export function createApp() {
  const rooms = new Map();
  const wss = new WebSocketServer({ noServer: true, maxPayload: 6000000 });
  const send = (res, data) => res.write(`data: ${JSON.stringify(data)}\n\n`);
  const sendSocket = (socket, data) => {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(data));
  };
  const broadcast = (room, data, except) => {
    for (const [id, res] of room.streams) if (id !== except) send(res, data);
    for (const [id, socket] of room.sockets) if (id !== except) sendSocket(socket, data);
  };
  const participantIds = room => [...new Set([...room.streams.keys(), ...room.sockets.keys()])];
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const json = (status, data) => { res.writeHead(status, {'Content-Type':'application/json'}); res.end(JSON.stringify(data)); };
    try {
      if (url.pathname === '/api/network') return json(200, {urls: Object.values(networkInterfaces()).flat().filter(n => n.family === 'IPv4' && !n.internal).map(n => `http://${n.address}:${server.address().port}`)});
      if (req.method === 'POST' && url.pathname.startsWith('/api/')) {
        let raw = ''; for await (const chunk of req) { raw += chunk; if (raw.length > 6000000) return json(413, {error:'요청이 너무 큽니다.'}); }
        const body = JSON.parse(raw || '{}');
        if (url.pathname === '/api/create') {
          let code; do { code = String(randomInt(100000, 1000000)); } while (rooms.has(code));
          rooms.set(code, {members:new Set(), streams:new Map(), sockets:new Map(), strokes:[], active:new Map(), frame:null, background:null, updated:Date.now()});
          return json(200, {code});
        }
        const room = rooms.get(body.code);
        if (!room) return json(404, {error:'방을 찾을 수 없습니다. 연결 코드를 확인하세요.'});
        room.updated = Date.now();
        if (url.pathname === '/api/join') {
          if(room.members.size >= 8) return json(409, {error:'최대 8대까지 연결할 수 있습니다.'});
          const id = randomUUID(); room.members.add(id); return json(200, {id});
        }
        if (!room.members.has(body.id)) return json(403, {error:'연결을 다시 시작하세요.'});
        if (url.pathname === '/api/event') {
          const event = body.event;
          if (!event || typeof event.type !== 'string') return json(400, {error:'잘못된 이벤트'});
          if (event.type === 'stroke') {
            const s = event.stroke;
            if (!s || typeof s.id !== 'string' || !Array.isArray(s.points) || s.points.length > 4096 || !/^#[0-9a-f]{6}$/i.test(s.color) || !Number.isFinite(s.width) || s.width < 0.1 || s.width > 40 || (s.style && !['pen','marker','highlighter'].includes(s.style)) || (s.layer && !['board','screen'].includes(s.layer)) || !s.points.every(p => Array.isArray(p) && p.length === 3 && p.every(Number.isFinite) && p.every(v => v >= 0 && v <= 1))) return json(400, {error:'잘못된 필기 데이터'});
            const key = `${body.id}:${s.id}`;
            if (!room.active.has(key) && room.strokes.length >= 5000) return json(409, {error:'필기가 가득 찼습니다. PNG로 저장한 뒤 지워 주세요.'});
            if (!room.active.has(key)) { room.active.set(key, {...s, layer:s.layer || 'board', owner:body.id}); room.strokes.push(room.active.get(key)); }
            else Object.assign(room.active.get(key), s);
            broadcast(room, {type:'stroke', stroke:room.active.get(key)}, body.id);
          } else if (event.type === 'clear') {
            const layer=['board','screen'].includes(event.layer)?event.layer:'board';room.strokes=room.strokes.filter(s=>(s.layer||'board')!==layer);room.active=new Map(room.strokes.map(s=>[`${s.owner}:${s.id}`,s]));broadcast(room, {type:'state', strokes:room.strokes});
          } else if (event.type === 'erase') {
            const point=event.point, radius=event.radius,layer=['board','screen'].includes(event.layer)?event.layer:'board';
            if(!Array.isArray(point)||point.length!==2||!point.every(Number.isFinite)||!point.every(v=>v>=0&&v<=1)||!Number.isFinite(radius)||radius<0.001||radius>0.2) return json(400,{error:'잘못된 지우개 데이터'});
            const before=room.strokes.length;
            room.strokes=room.strokes.filter(s=>(s.layer||'board')!==layer||!s.points.some(p=>Math.hypot(p[0]-point[0],p[1]-point[1])<=radius));
            if(room.strokes.length!==before){room.active=new Map(room.strokes.map(s=>[`${s.owner}:${s.id}`,s]));broadcast(room,{type:'state',strokes:room.strokes});}
          } else if(event.type === 'undo') {
            const layer=['board','screen'].includes(event.layer)?event.layer:'board';const index = room.strokes.findLastIndex(s => s.owner === body.id && (s.layer||'board')===layer);
            if(index >= 0) { const [s] = room.strokes.splice(index,1); room.active.delete(`${s.owner}:${s.id}`); broadcast(room, {type:'state', strokes:room.strokes}); }
          } else if (event.type === 'frame') {
            if(typeof event.image !== 'string' || event.image.length > 1400000 || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(event.image)) return json(400,{error:'잘못된 화면 데이터'});
            room.frame = {type:'frame',image:event.image,from:body.id};
            broadcast(room,room.frame,body.id);
          } else if (event.type === 'background') {
            if(typeof event.image!=='string'||event.image.length>5500000||!/^data:image\/(jpeg|png);base64,[A-Za-z0-9+/=]+$/.test(event.image)) return json(400,{error:'잘못된 배경 이미지'});
            room.background={type:'background',image:event.image,from:body.id};broadcast(room,room.background,body.id);
          } else if (event.type === 'background-clear') {
            room.background=null;broadcast(room,{type:'background-clear',from:body.id},body.id);
          } else if (['offer','answer','ice','share-stop'].includes(event.type)) {
            if(event.type === 'share-stop') room.frame=null;
            if(event.target && room.streams.has(event.target)) send(room.streams.get(event.target), {...event, from:body.id});
            else if(event.target && room.sockets.has(event.target)) sendSocket(room.sockets.get(event.target), {...event, from:body.id});
            else if(event.type === 'share-stop') broadcast(room, {...event, from:body.id}, body.id);
          } else return json(400, {error:'지원하지 않는 이벤트'});
          return json(200, {ok:true});
        }
        return json(404, {error:'Not found'});
      }
      if(req.method === 'GET' && url.pathname === '/api/events') {
        const room = rooms.get(url.searchParams.get('code')); const id = url.searchParams.get('id');
        if(!room?.members.has(id)) return json(403, {error:'연결을 다시 시작하세요.'});
        room.streams.get(id)?.end();
        res.writeHead(200, {'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive','X-Accel-Buffering':'no'});
        room.streams.set(id,res); send(res,{type:'state',strokes:room.strokes}); if(room.frame) send(res,room.frame); if(room.background) send(res,room.background);
        broadcast(room, {type:'peers', ids:participantIds(room)});
        const timer=setInterval(()=>{res.write(': ping\n\n'); room.updated=Date.now();},15000);
        req.on('close',()=>{clearInterval(timer); if(room.streams.get(id)===res) room.streams.delete(id); broadcast(room,{type:'peers',ids:participantIds(room)});}); return;
      }
      const files = {'/':'index.html','/app.js':'app.js','/style.css':'style.css'};
      if(req.method !== 'GET' || !files[url.pathname]) return json(404,{error:'Not found'});
      const file=files[url.pathname]; const content=await readFile(new URL(`./public/${file}`,import.meta.url));
      res.writeHead(200, {'Content-Type':file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html','X-Content-Type-Options':'nosniff'});res.end(content);
    } catch { if(!res.headersSent) json(400,{error:'요청을 처리하지 못했습니다.'}); else res.end(); }
  });
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    const code = url.searchParams.get('code');
    const id = url.searchParams.get('id');
    const room = rooms.get(code);
    if (url.pathname !== '/ws' || !room?.members.has(id)) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, {room, code, id}));
  });
  wss.on('connection', (socket, {room, code, id}) => {
    room.sockets.get(id)?.close(1000, 'replaced');
    room.sockets.set(id, socket);
    room.updated = Date.now();
    sendSocket(socket, {type:'state', strokes:room.strokes});
    if(room.frame) sendSocket(socket, room.frame);
    if(room.background) sendSocket(socket, room.background);
    broadcast(room, {type:'peers', ids:participantIds(room)});
    socket.on('message', async raw => {
      try {
        const event = JSON.parse(raw.toString());
        const response = await fetch(`http://127.0.0.1:${server.address().port}/api/event`, {
          method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code,id,event})
        });
        if(!response.ok) {
          const result = await response.json();
          sendSocket(socket, {type:'error', message:result.error || '이벤트 전송 실패'});
        }
      } catch {
        sendSocket(socket, {type:'error', message:'잘못된 이벤트'});
      }
    });
    socket.on('close', () => {
      if(room.sockets.get(id) === socket) room.sockets.delete(id);
      broadcast(room, {type:'peers', ids:participantIds(room)});
    });
  });
  const cleanup=setInterval(()=>{for(const [code,r] of rooms) if(!r.streams.size && !r.sockets.size && Date.now()-r.updated>86400000) rooms.delete(code);},60000);cleanup.unref();
  server.on('close',()=>{clearInterval(cleanup);wss.close();}); return server;
}
if(process.argv[1] === fileURLToPath(import.meta.url)) createApp().listen(Number(process.env.PORT || 3000),'0.0.0.0',()=>console.log(`Drawbridge → http://localhost:${process.env.PORT || 3000}\n같은 Wi-Fi의 태블릿에서 앱에 표시된 연결 주소를 여세요.`));
