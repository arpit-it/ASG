import json,hashlib,time
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=Path('/private/tmp/asg-291-current-deadline')
ops=['resolve','analyze','test','build']
plan={'version':4,'adapter':'flutter-starter','tasks':[{'id':op,'operation':op,'dependencies':[] if i==0 else [ops[i-1]],'boardTaskId':'TACTUAL'} for i,op in enumerate(ops)]}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_POST(self):
  request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  prompt=request['messages'][-1]['content']
  if 'Originals: ' in prompt:
   originals=json.loads(prompt.split('Originals: ',1)[1]); changes=[]
   for path,before in originals.items():
    if path!='test/generated_app_test.dart':raise ValueError('Only explicitly approved test file')
    after=before.replace('void main() {',"void main() {\n  test('F17 explicit deadline seed', () async { await Future<void>.delayed(const Duration(minutes: 5)); }, timeout: const Timeout(Duration(minutes: 10)));",1)
    assert after!=before
    changes.append({'path':path,'beforeSha256':hashlib.sha256(before.encode()).hexdigest(),'after':after})
   content=json.dumps({'summary':'Deterministic disposable deadline seed; no model inference','changes':changes})
   (root/'seed-observed.json').write_text(json.dumps({'observedAt':time.time(),'paths':list(originals)}))
  else:
   content='Explicit deterministic fixture Plan, not model inference. Generate and verify the fixed Flutter web starter baseline, then review only test/generated_app_test.dart for the approved five-minute async deadline seed. All checks map to TACTUAL. Preserve working baseline; never promote timed-out candidates.\n```asg-build\n'+json.dumps(plan)+'\n```'
  body=json.dumps({'choices':[{'message':{'content':content},'finish_reason':'stop'}]}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1',8765),Handler).serve_forever()
