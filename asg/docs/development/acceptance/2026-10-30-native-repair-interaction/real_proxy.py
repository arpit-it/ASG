import json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
root=Path('/private/tmp/asg-291-repair-interaction-raw')
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  raw=self.rfile.read(int(self.headers['Content-Length']))
  mode=(root/'mode').read_text().strip()
  if mode=='real':
   try:
    req=urllib.request.Request('http://127.0.0.1:8766'+self.path,data=raw,headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=180) as upstream:
     self.send_response(upstream.status); self.send_header('Content-Type',upstream.headers.get('Content-Type')); self.end_headers()
     while chunk:=upstream.read1(4096): self.wfile.write(chunk); self.wfile.flush()
   except Exception: pass
   return
  prompt=json.loads(raw)['messages'][-1]['content']
  originals=json.loads(prompt.split('Originals: ',1)[1])
  changes=[]
  for path,before in originals.items():
   after=(before.replace('void main() {', "void main() {\n  test('F17 seeded deadline', () async { await Future<void>.delayed(const Duration(minutes: 5)); }, timeout: const Timeout(Duration(minutes: 10)));",1) if mode=='timeout' else before.replace('runApp(', 'asgMissingFunction();\n  runApp(',1))
   changes.append({'path':path,'before':before,'after':after})
  proposal={'summary':'Explicit deterministic '+mode+' seed for disposable F17 acceptance; not model inference','changes':changes}
  data=json.dumps({'choices':[{'message':{'content':json.dumps(proposal)},'finish_reason':'stop'}]}).encode()
  self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
  (root/('seed-'+mode+'.json')).write_text(json.dumps({'mode':mode,'paths':list(originals),'utc':time.time()}))
ThreadingHTTPServer(('127.0.0.1',8765),Handler).serve_forever()
