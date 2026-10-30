// Isolated loopback WebSocket peer. No app data, tokens or signing requests.
const fs = require('node:fs');
const http = require('node:http');
const WebSocketServer = require('ws').Server;
const server = http.createServer();
const websocket = new WebSocketServer({ noServer: true });
server.on('upgrade', (request, socket, head) => {
  const upgrade = () => {
    if (socket.destroyed) return;
    websocket.handleUpgrade(request, socket, head, peer => websocket.emit('connection', peer));
  };
  if (request.url === '/delayed') setTimeout(upgrade, 300); else upgrade();
});
websocket.on('connection', peer => peer.on('message', bytes => {
  if (bytes.toString() === 'terminate-public-fixture') peer.terminate();
  else if (/^close-public-fixture:(1000|1001|1008|1011|4001|4010|4011)$/.test(bytes.toString())) {
    peer.close(Number(bytes.toString().split(':')[1]), 'private-close-reason-fixture');
  }
  else peer.send(bytes.toString());
}));
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.env.OATH_SOCKET_PORT_FILE, String(server.address().port)));
