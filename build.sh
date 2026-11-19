#!/bin/zsh
set -eu
cd "${0:A:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --jobs 4 --triple arm64-apple-macosx13.0 --scratch-path .build-arm64
swift build -c release --jobs 4 --triple x86_64-apple-macosx13.0 --scratch-path .build-intel
python3 - <<'PY'
from pathlib import Path
import plistlib, shutil, subprocess
root=Path.cwd(); dist=root/'dist'; app=dist/'独立纯净代理.app'
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
(app/'Contents/Resources').mkdir(exist_ok=True)
def binary(arch, scratch):
    folder=subprocess.check_output(['swift','build','-c','release','--triple',arch+'-apple-macosx13.0',
                                    '--scratch-path',scratch,'--show-bin-path'],text=True).strip()
    return Path(folder)/'ProxyBrowser'
arm=binary('arm64','.build-arm64')
intel=binary('x86_64','.build-intel')
subprocess.run(['lipo','-create',str(arm),str(intel),'-output',str(app/'Contents/MacOS/ProxyBrowser')],check=True)
subprocess.run(['strip','-S',str(app/'Contents/MacOS/ProxyBrowser')],check=True)
info={'CFBundleName':'独立纯净代理','CFBundleDisplayName':'独立纯净代理',
      'CFBundleIdentifier':'net.bravewaves.proxy-browser','CFBundleExecutable':'ProxyBrowser',
      'CFBundlePackageType':'APPL','CFBundleShortVersionString':'2.1.3','CFBundleVersion':'7',
      'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication',
      'CFBundleIconFile':'AppIcon'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
license_candidates=[root/'.build-arm64/checkouts/Yams/LICENSE',root/'.build/checkouts/Yams/LICENSE',root/'Yams-LICENSE.txt']
license_file=next((path for path in license_candidates if path.is_file()),None)
if license_file is None: raise RuntimeError('Yams LICENSE not found')
for source, name in [(license_file,'Yams-LICENSE.txt'),
                     (root/'LICENSE','LICENSE'),
                     (root/'README.md','使用说明.md')]:
    destination=app/'Contents/Resources'/name
    if destination.exists(): destination.chmod(0o644)
    shutil.copyfile(source,destination)
print(app)
PY
xcrun swift MakeIcon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o 'dist/独立纯净代理.app/Contents/Resources/AppIcon.icns'
codesign --force --sign - 'dist/独立纯净代理.app'
codesign --verify --strict 'dist/独立纯净代理.app'
