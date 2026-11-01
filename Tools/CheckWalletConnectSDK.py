#!/usr/bin/env python3
"""Compile unchanged production SDK modules in a host-only, dependency-minimal harness.
No wallet storage, simulator, signing, or real network endpoints are used here.
"""
import json
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
sdk=root/'Vendor/Reown/Sources'
graph={'Commons':[], 'JSONRPC':['Commons'], 'WalletConnectUtils':['JSONRPC'],
       'WalletConnectKMS':['WalletConnectUtils'], 'WalletConnectJWT':['WalletConnectKMS'],
       'HTTPClient':['OathDiagnostics'], 'WalletConnectRelay':['WalletConnectJWT','OathDiagnostics'],
       'WalletConnectNetworking':['HTTPClient','WalletConnectRelay'],
       'Events':['WalletConnectUtils','WalletConnectNetworking'],
       'WalletConnectPairing':['WalletConnectNetworking','Events','OathDiagnostics']}
with tempfile.TemporaryDirectory(prefix='oath-sdk-validation-') as temporary:
 work=Path(temporary)
 targets=[]
 for name,deps in graph.items():
  dest=work/'Sources'/name
  shutil.copytree(sdk/name,dest,ignore=shutil.ignore_patterns('._*'))
  resources=[]
  for f in dest.rglob('*'):
   if f.is_file() and f.suffix!='.swift':
    if f.name=='PackageConfig.json':resources.append('.copy("PackageConfig.json")')
    else:f.unlink()
  targets.append('.target(name: '+json.dumps(name)+', dependencies: '+json.dumps(deps)+', resources: ['+','.join(resources)+'])')
 schema=work/'Sources/Schemas';schema.mkdir()
 for file in ['Events/InitEvent.swift','Events/MessageEvent.swift','WalletConnectVerify/VerifyContextFactory.swift','WalletConnectVerify/VerifyContext.swift','WalletConnectVerify/OriginVerifier.swift','WalletConnectVerify/Register/VerifyService.swift','WalletConnectVerify/Register/VerifyResponse.swift','WalletConnectSign/Auth/Types/AuthRequestParams.swift','WalletConnectSign/Namespace.swift','WalletConnectPairing/Types/AppMetadata.swift']:
  source=sdk/file
  if not source.exists():
   candidates=list(sdk.rglob(source.name));assert len(candidates)==1, (source.name, candidates);source=candidates[0]
  contents=source.read_text()
  if source.name=='Namespace.swift': contents=contents.split('enum Namespace {')[0]
  (schema/source.name).write_text('import WalletConnectNetworking\nimport HTTPClient\nimport OathDiagnostics\n'+contents)
 session=(sdk/'WalletConnectSign/Session.swift').read_text().split('\nextension Session {')[0]
 (schema/'Session.swift').write_text('import WalletConnectNetworking\n'+session)
 (schema/'Support.swift').write_text('enum WCSession { static let defaultTimeToLive: Int64 = 604800 }\nenum Request { static let minTtl: Double = 300; static let maxTtl: Double = 604800 }\n')
 targets.append('.target(name: "Schemas", dependencies: ["WalletConnectNetworking", "HTTPClient", "OathDiagnostics"])')
 tests=work/'Tests/SDKTests';shutil.copytree(root/'Tools/WalletConnectSDKValidation',tests,ignore=shutil.ignore_patterns('._*'))
 shutil.copy(root/'Vendor/Reown/Tests/WalletConnectUtilsTests/WalletConnectURITests.swift', tests/'WalletConnectURITests.swift')
 for fixture in ['KeyManagementServiceMock.swift','NetworkingInteractorMock.swift']:
  candidates=list((root/'Vendor/Reown/Tests').rglob(fixture)); assert len(candidates)==1
  shutil.copy(candidates[0],tests/fixture)
 targets.append('.testTarget(name: "SDKTests", dependencies: ["Schemas", "HTTPClient", "WalletConnectNetworking", "WalletConnectKMS", "WalletConnectRelay", "WalletConnectPairing", "Events", "OathDiagnostics"])')
 (work/'Package.swift').write_text('// swift-tools-version: 6.1\nimport PackageDescription\nlet package=Package(name:"SDKValidation",platforms:[.macOS(.v14)],dependencies:[.package(path:'+json.dumps(str(root/'Packages/OathDiagnostics'))+')],targets:['+','.join(targets)+'],swiftLanguageModes:[.v5])\n')
 result=subprocess.run(['swift','test','--package-path',str(work),'--scratch-path','/tmp/oath-sdk-warning-host']+sys.argv[1:],timeout=240)
 raise SystemExit(result.returncode)
