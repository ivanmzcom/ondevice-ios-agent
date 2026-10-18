#!/usr/bin/env python3
"""Offline allowlist and redaction-safe scan. Never prints matched values."""
import argparse,hashlib,json,re,struct,sys
from pathlib import Path
RULES={
 'private_path':re.compile('/'+'Users/'+r'[^\s"\'<>]+|\$\(HOME\)/\.hermes/'),
 'credential':re.compile(r'sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{16,}|-----BEGIN [A-Z ]*(?:PRIVATE KEY|CERTIFICATE)-----|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
 'device_id':re.compile(r'(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b'),
 'team':re.compile(r'DEVELOPMENT_TEAM\s*[=:]\s*"?[A-Z0-9]{10}'),
 'email':re.compile(r'\b[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}\b'),
 'account_literal':re.compile(r'(?i)(?:access_token|refresh_token|api_key|password|secret)\s*[=:]\s*["\'][A-Za-z0-9_.-]{12,}["\']'),
}
FORBIDDEN={'.git','.github','.build','target','DerivedData','node_modules','xcuserdata','logs','screenshots','captures','__pycache__'}
BAD_SUFFIX={'.p12','.p8','.pem','.key','.cer','.mobileprovision','.ipa','.a','.o','.dylib','.so','.log','.png','.jpg','.jpeg','.sqlite','.db','.crate'}
# The only binary file allowed: the original geometric placeholder icon (see README).
# Exact path, SHA-256, PNG signature and IHDR are all required; any other binary is a finding.
EXPECTED_BINARY={'runner/WebDriverAgentRunner/Assets.xcassets/AppIcon.appiconset/icon-1024.png':
 {'sha256':'f949904ea4f5d04ab83c95b1d6e8de37a425ab46227f0fb120b928b47948d7ab','width':1024,'height':1024,'bit_depth':8,'color_type':2}}
# Local-only prerequisite that must never be part of the distributable tree.
WITHHELD_PREFIXES=('runner/PrivateHeaders/',)
def png_ok(b,spec):
 if hashlib.sha256(b).hexdigest()!=spec['sha256'] or b[:8]!=b'\x89PNG\r\n\x1a\n' or b[12:16]!=b'IHDR':return False
 w,h,depth,ctype=struct.unpack('>IIBB',b[16:26])
 return (w,h,depth,ctype)==(spec['width'],spec['height'],spec['bit_depth'],spec['color_type'])
def asset_refs(root,findings):
 for c in root.rglob('Contents.json'):
  if '.xcassets' not in c.as_posix():continue
  for img in json.loads(c.read_text()).get('images',[]):
   if 'filename' in img and not (c.parent/img['filename']).is_file():
    findings.append({'path':c.relative_to(root).as_posix(),'rule':'asset_reference_missing'})
def check_prerequisite(directory,root):
 spec=json.loads((root/'runner/PrivateHeaders.expected.json').read_text());base=Path(directory).resolve()
 want={f['path'][len(spec['local_directory']):]:f for f in spec['files']}
 have={p.relative_to(base).as_posix():p for p in base.rglob('*') if p.is_file()} if base.is_dir() else {}
 bad=[r for r,f in want.items() if r in have and hashlib.sha256(have[r].read_bytes()).hexdigest()!=f['sha256']]
 return {'expected':len(want),'present':len(have.keys()&want.keys()),'missing':sorted(want.keys()-have.keys()),'unexpected':sorted(have.keys()-want.keys()),'hash_mismatch':sorted(bad),
  'ok':not bad and want.keys()==have.keys(),'note':'hash check only; says nothing about your right to use these files'}
def scan(root):
 root=root.resolve();manifest=root/'EXPORT_MANIFEST.json'
 expected=json.loads(manifest.read_text());expected={x['path']:x for x in expected}
 actual={};findings=[]
 for p in sorted(root.rglob('*')):
  rel=p.relative_to(root).as_posix()
  if p.is_symlink():findings.append({'path':rel,'rule':'symlink'});continue
  if not p.is_file():continue
  if rel=='EXPORT_MANIFEST.json':continue
  actual[rel]=p
  if rel.startswith(WITHHELD_PREFIXES):findings.append({'path':rel,'rule':'withheld_prerequisite_present'})
  if rel not in expected:findings.append({'path':rel,'rule':'not_allowlisted'})
  elif hashlib.sha256(p.read_bytes()).hexdigest()!=expected[rel]['sha256']:findings.append({'path':rel,'rule':'hash_mismatch'})
  if set(p.relative_to(root).parts)&FORBIDDEN or (p.suffix.lower() in BAD_SUFFIX and rel not in EXPECTED_BINARY) or p.name.lower() in {'pairing.plist','.env','auth.json','credentials.json'}:
   findings.append({'path':rel,'rule':'forbidden_file'})
  b=p.read_bytes()
  if rel in EXPECTED_BINARY and not set(p.relative_to(root).parts)&FORBIDDEN:
   if not png_ok(b,EXPECTED_BINARY[rel]):findings.append({'path':rel,'rule':'unexpected_binary'})
   continue
  try:s=b.decode('utf-8')
  except UnicodeDecodeError:findings.append({'path':rel,'rule':'binary'});continue
  if '\0' in s:findings.append({'path':rel,'rule':'nul_byte'})
  for i,line in enumerate(s.splitlines(),1):
   for rule,pat in RULES.items():
    matches=list(pat.finditer(line))
    if not matches:continue
    if rule=='email':
     # Public author addresses in mandatory licenses/source headers are retained,
     # as is the explicitly synthetic example.invalid test address.
     if rel.startswith(('licenses/','runner/')) or all(m.group().endswith(('@example.invalid','@example.com')) for m in matches):continue
    findings.append({'path':rel,'line':i,'rule':rule})
 asset_refs(root,findings)
 for missing in sorted(expected.keys()-actual.keys()):findings.append({'path':missing,'rule':'missing_file'})
 return {'files':len(actual),'allowlist_entries':len(expected),'findings':findings,'clean':not findings,'scope':'allowlist/hash/heuristic scan; not legal clearance or exhaustive secret detection'}
def self_test():
 cases={'private_path':'/'+'Users/'+'sample/file','credential':'sk-'+'x'*20,'device_id':'00000000-'+'0'*16,'team':'DEVELOPMENT_TEAM = '+'A'*10,'email':'sample'+'@'+'sample.invalid','account_literal':'api_key = "'+'x'*16+'"'}
 assert all(RULES[k].search(v) for k,v in cases.items())
 assert not RULES['credential'].search('SYNTHETIC TEST VALUE')
 good=b'\x89PNG\r\n\x1a\n'+b'\x00\x00\x00\x0dIHDR'+struct.pack('>IIBB',1024,1024,8,2)
 spec=dict(EXPECTED_BINARY[next(iter(EXPECTED_BINARY))],sha256=hashlib.sha256(good).hexdigest())
 assert png_ok(good,spec) and not png_ok(good+b'x',spec) and not png_ok(good.replace(b'IHDR',b'IHDX'),dict(spec,sha256=hashlib.sha256(good.replace(b'IHDR',b'IHDX')).hexdigest()))
 return len(cases)+2
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('root',nargs='?',default='.');ap.add_argument('--self-test',action='store_true');ap.add_argument('--check-prerequisite',metavar='DIR');args=ap.parse_args()
 if args.check_prerequisite:r=check_prerequisite(args.check_prerequisite,Path(args.root).resolve());print(json.dumps(r,indent=2));sys.exit(0 if r['ok'] else 1)
 if args.self_test:print(json.dumps({'self_tests_passed':self_test()}));sys.exit(0)
 result=scan(Path(args.root));print(json.dumps(result,indent=2));sys.exit(0 if result['clean'] else 1)
