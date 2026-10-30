import argparse, json, subprocess
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('output',type=Path); a=p.parse_args()
r=Path(__file__).resolve().parents[2]; out=a.output.resolve(); out.mkdir(parents=True,exist_ok=True)
for source in ['OathAtmosphere/Shared/OathStackedSheetPresenter.swift', 'OathAtmosphere/Scanner/OathWalletConnectPresentation.swift', 'Tools/WalletConnectPresentationRegression/App.swift']:
    (out/Path(source).name).write_text((r/source).read_text())
spec={'name':'WalletConnectPresentationProbe','options':{'deploymentTarget':{'iOS':'26.0'}},'settings':{'base':{'SWIFT_VERSION':'6.0','CODE_SIGNING_ALLOWED':False}},'targets':{'WalletConnectPresentationProbe':{'type':'application','platform':'iOS','sources':[str(out)],'settings':{'base':{'PRODUCT_BUNDLE_IDENTIFIER':'org.oathwallet.tests.wcpresentation','GENERATE_INFOPLIST_FILE':True,'INFOPLIST_KEY_UILaunchScreen_Generation':True,'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':True,'TARGETED_DEVICE_FAMILY':'1'}}}}}
(out/'project.json').write_text(json.dumps(spec));subprocess.run(['xcodegen','generate','--spec',str(out/'project.json'),'--project',str(out)],check=True)
