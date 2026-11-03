#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Installed Yarn Classic integration, source pins, offline use and pure composition."""
import base64
import io
import tarfile
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from urllib.parse import unquote, urlsplit
import os
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
system = subprocess.check_output(['nix','eval','--impure','--raw','--expr','builtins.currentSystem'], text=True).strip()
snapshot = json.loads(subprocess.check_output(['nix','flake','metadata','--json','--no-write-lock-file',str(root)], text=True))['path']
with tempfile.TemporaryDirectory(prefix='yarn-classic-native-composition-') as temporary:
    temporary = Path(temporary)
    subprocess.run(['nix-store','--add-root',str(temporary/'source'),'--realise',snapshot],check=True)
    cli = Path(subprocess.check_output(['nix','build','path:'+snapshot+'#toolchain','--out-link',str(temporary/'cli'),'--print-out-paths'],text=True).strip())/'bin/yarn-classic-purifier'
    env = dict(os.environ, YARN_COMPOSITION_FLAKE=snapshot)
    home = temporary/'home'
    home.mkdir()
    env.update(NO_COLOR='1', HOME=str(home))
    env.pop('FORCE_COLOR',None)
    sdk = Path(subprocess.check_output(['nix','build','--impure','--expr',
        'let f=builtins.getFlake ("path:"+builtins.getEnv "YARN_COMPOSITION_FLAKE"); in f.inputs.nixpkgs.legacyPackages.'+system+'.nodejs',
        '--out-link',str(temporary/'sdk'),'--print-out-paths'],env=env,text=True).strip())
    env['PATH'] = str(sdk/'bin')+':'+env['PATH']
    project = temporary/'project'
    project.mkdir()
    manifest = {'name':'yarn-classic-composed','version':'1.0.0','license':'MIT','main':'index.js','dependencies':{'@fixture/greet':'>=99'},
                'scripts':{'test':'node -e \'const greet=require("@fixture/greet");if(greet("nix")!=="hello Nix")process.exit(1)\''}}
    original = json.dumps(manifest).encode()
    (project/'package.json').write_bytes(original)
    (project/'index.js').write_text('module.exports = require("@fixture/greet");\n')
    def run(*args,**kwargs):
        return subprocess.run([str(arg) for arg in args],cwd=project,env=env,check=True,**kwargs)
    reference = 'path:'+snapshot+'#checks.'+system+'.composition-producer'
    run(cli,'lock','--input',reference)
    lockfile = project/'yarn-classic-purifier.lock.json'
    data = json.loads(lockfile.read_text())
    assert len(data['projectInputs']) == 1
    assert not data['packages']
    before = lockfile.read_bytes(), (project/'yarn.lock').read_bytes()
    run(cli,'lock')
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    run(cli,'prefetch')
    run(cli.parent/'yarn','install','--frozen-lockfile')
    run(cli.parent/'yarn','run','test')
    run(sdk/'bin/node','-e','const greet=require("@fixture/greet");if(greet("nix")!=="hello Nix")process.exit(1)')
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    expression = temporary/'consumer.nix'
    expression.write_text('''{ source, project }:
      let f=builtins.getFlake ("path:"+source);
          pkgs=import f.inputs.nixpkgs {system=builtins.currentSystem;overlays=[f.overlays.default];};
          result=pkgs.yarn-classic-purifier.buildYarnClassicProject {src = /. + project;};
      in assert result.fetches == []; result.tests
    ''')
    run('nix','build','--impure','--file',expression,'--argstr','source',snapshot,
        '--argstr','project',project,'--out-link',temporary/'pure')
    assert (project/'package.json').read_bytes() == original
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    publication = temporary/'publication.nix'
    publication.write_text(expression.read_text().replace('in assert result.fetches == []; result.tests',
        'in result.packages."yarn-classic-composed".projections.npm'))
    repository = Path(subprocess.check_output(['nix','build','--impure','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),
        '--out-link',str(temporary/'publication'),'--print-out-paths'],text=True).strip())
    catalog = Path(subprocess.check_output(['nix','eval','--impure','--raw','--file',str(publication),
        '--argstr','source',snapshot,'--argstr','project',str(project),'catalog'],text=True).strip())
    modules = json.loads(catalog.read_text())['modules']
    provided = next(item for item in modules if item['name'] == '@fixture/greet')
    uploads = {provided['name']:(repository/provided['archive']).read_bytes()}
    put_names = []
    class Registry(BaseHTTPRequestHandler):
        def do_GET(self):
            route = unquote(urlsplit(self.path).path).lstrip('/')
            if route.startswith('tarballs/'):
                body = (repository/route).read_bytes()
            else:
                available = [item for item in modules if item['name'] == route and item['name'] in uploads]
                if not available:
                    self.send_error(404)
                    return
                versions = {item['version']:{**item['package'],'dist':{
                    'integrity':item['integrity'],'tarball':'http://'+self.headers['Host']+'/'+item['archive']}} for item in available}
                body = json.dumps({'name':route,'versions':versions,
                    'dist-tags':{'latest':available[0]['version']}}).encode()
            self.send_response(200)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_PUT(self):
            document = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            put_names.append(document['name'])
            uploads[document['name']] = base64.b64decode(next(iter(document['_attachments'].values()))['data'])
            self.send_response(201)
            self.end_headers()
            self.wfile.write(b'{}')
        def log_message(self,*args): pass
    server = ThreadingHTTPServer(('127.0.0.1',0),Registry)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    url = 'http://127.0.0.1:'+str(server.server_port)+'/'
    (Path(env['HOME'])/'.npmrc').write_text('//127.0.0.1:'+str(server.server_port)+'/:_authToken=local-fixture\n')
    try:
        run(cli,'publish','yarn-classic-composed','--registry',url,'--access','public')
        assert provided['name'] not in put_names
        for item in modules:
            assert uploads[item['name']] == (repository/item['archive']).read_bytes(), (
                item['name'], item['version'], json.load(tarfile.open(fileobj=io.BytesIO(uploads[item['name']])).extractfile('package/package.json'))['version'])
        downstream = temporary/'ordinary'
        downstream.mkdir()
        (downstream/'package.json').write_text('{"name":"ordinary-npm-consumer","private":true}')
        version = next(item['version'] for item in modules if item['name'] == 'yarn-classic-composed')
        subprocess.run([str(sdk/'bin/npm'),'install','--no-audit','--no-fund','--registry',url,'--cache',str(temporary/'ordinary-cache'),
            'yarn-classic-composed@'+version],cwd=downstream,env=env,check=True)
        subprocess.run([str(sdk/'bin/node'),'-e','const greet=require("yarn-classic-composed");if(greet("nix")!=="hello Nix")process.exit(1)'],
            cwd=downstream,env=env,check=True)
    finally:
        server.shutdown()
        server.server_close()
    assert before == (lockfile.read_bytes(), (project/'yarn.lock').read_bytes())
    assert (project/'package.json').read_bytes() == original
    external = temporary/'external'
    external.mkdir()
    (external/'package.json').write_bytes(original)
    native = b'"@fixture/greet@>=99":\n  version "99.0.0"\n  resolved "https://invalid.example/old.tgz"\n  integrity sha512-AAAA\n'
    (external/'yarn.lock').write_bytes(native)
    external_expression = temporary/'external.nix'
    external_expression.write_text(expression.read_text().replace('src = /. + project;',
        'src = /. + project;dependencies=[f.checks.${builtins.currentSystem}.composition-producer];'))
    run('nix','build','--impure','--file',external_expression,'--argstr','source',snapshot,
        '--argstr','project',external,'--out-link',temporary/'external-pure')
    assert (external/'package.json').read_bytes() == original
    assert (external/'yarn.lock').read_bytes() == native
    outside_project = temporary/'outside-project'
    outside_project.mkdir()
    (outside_project/'package.json').write_bytes(original)
    outside_locks = temporary/'outside-locks'
    outside_locks.mkdir()
    outside_native = outside_locks/'yarn.lock'
    outside_native.write_bytes(before[1])
    outside_purifier = outside_locks/'yarn-classic-purifier.lock.json'
    outside_purifier.write_bytes(before[0])
    flags = ['--lockfile',str(outside_purifier),'--tool-lockfile',str(outside_native)]
    for command in ('lock','prefetch'):
        subprocess.run([str(cli),command,*flags],cwd=outside_project,env=env,check=True)
        assert not (outside_project/'yarn.lock').exists()
        assert (outside_project/'package.json').read_bytes() == original
    outside_env = dict(env,YARN_CLASSIC_PURIFIER_LOCKFILE=str(outside_purifier),
        YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE=str(outside_native))
    subprocess.run([str(cli.parent/'yarn'),'install','--frozen-lockfile'],cwd=outside_project,env=outside_env,check=True)
    subprocess.run([str(cli.parent/'yarn'),'run','test'],cwd=outside_project,env=outside_env,check=True)
    assert not (outside_project/'yarn.lock').exists()
    assert (outside_project/'package.json').read_bytes() == original
    assert (outside_purifier.read_bytes(), outside_native.read_bytes()) == before
    addition = temporary/'addition'
    addition.mkdir()
    (addition/'package.json').write_text('{"name":"local-addition","version":"1.0.0","main":"index.js"}')
    (addition/'index.js').write_text('module.exports = 42;')
    run(cli.parent/'yarn','add','../addition')
    changed = json.loads((project/'package.json').read_text())
    assert changed['dependencies']['@fixture/greet'] == '>=99'
    assert changed['dependencies']['local-addition'].endswith('../addition')
    run(cli,'lock')
    assert len(json.loads(lockfile.read_text())['projectInputs']) == 1
    run(cli.parent/'yarn','run','test')
    run(sdk/'bin/node','-e','if(require("local-addition")!==42)process.exit(1)')
    unpurified = temporary/'unpurified'
    unpurified.mkdir()
    fallback = subprocess.run([str(cli.parent/'yarn'),'--version'],cwd=unpurified,env=env,
        text=True,capture_output=True,check=True)
    assert 'yarn.lock' in fallback.stderr and 'impure' in fallback.stderr
    assert fallback.stdout.strip()
print('YARN CLASSIC NATIVE REPOSITORY COMPOSITION PASSED')
