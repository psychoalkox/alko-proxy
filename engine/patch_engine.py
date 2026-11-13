"""Patch supported vinskeeper GTProxy source in-place, with backup and strict anchors.

Run from a clone of ALKO Proxy: python engine/patch_engine.py path/to/GTProxy
Does not download arbitrary executables or patch Windows hosts automatically.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = '#include "alko_bridge.hpp"'
INSTALL = 'alko_bridge::install_emit(*script_engine_);'
INIT = 'alko_bridge::Bridge alko_bridge;'
WEB_SERVER = 'std::make_unique<WebServer>(config_, dispatcher_, *client_, *server_)'
LEGACY_POLL = 'alko_bridge.poll(*script_engine_);'
POLL = ('alko_bridge.poll(*script_engine_, server_->is_connected(), client_->is_connected(),\n'
        '                         web_server_->bootstrap_state());')


def patch_connection(folder: Path) -> None:
    diff = ROOT / 'engine' / 'native_connection.patch'
    if subprocess.run(['git', 'apply', '--reverse', '--check', str(diff)], cwd=folder,
                      capture_output=True).returncode == 0:
        return
    subprocess.run(['git', 'apply', '--check', str(diff)], cwd=folder, check=True)
    subprocess.run(['git', 'apply', str(diff)], cwd=folder, check=True)


def patch_core(source: str) -> str:
    source = source.replace(WEB_SERVER, WEB_SERVER.replace(', *server_', ''), 1)
    if INCLUDE in source:
        if POLL in source:
            return source
        if LEGACY_POLL not in source:
            raise ValueError('Unknown existing ALKO bridge integration')
        return source.replace(LEGACY_POLL, POLL, 1)
    assert '#include "core.hpp"' in source, 'Unknown upstream core.hpp include'
    assert 'script_loader_->load_all();' in source, 'Unknown script loader API'
    assert 'while (running_) {' in source, 'Unknown run loop'
    assert 'script_scheduler_->update(elapsed);' in source, 'Unknown scheduler API'
    source = source.replace('#include "core.hpp"', '#include "core.hpp"\n' + INCLUDE, 1)
    source = source.replace('script_loader_->load_all();', INSTALL + '\n    script_loader_->load_all();', 1)
    source = source.replace('while (running_) {', INIT + '\n    while (running_) {', 1)
    source = source.replace('script_scheduler_->update(elapsed);', 'script_scheduler_->update(elapsed);\n        ' + POLL, 1)
    return source


def patch(folder: Path):
    core = folder / 'src' / 'core' / 'core.cpp'
    if not core.exists():
        raise FileNotFoundError(f'Not an enhanced GTProxy checkout: {core}')
    patch_connection(folder)
    original = core.read_text(encoding='utf-8')
    patched = patch_core(original)
    if original != patched:
        backup = core.with_suffix('.cpp.alko-backup')
        if not backup.exists():
            shutil.copy2(core, backup)
        core.write_text(patched, encoding='utf-8')
    shutil.copy2(ROOT / 'engine' / 'alko_bridge.hpp', folder / 'src' / 'core' / 'alko_bridge.hpp')
    scripts = folder / 'scripts'
    scripts.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'engine' / 'alko_features.lua', scripts / 'alko_features.lua')
    config = folder / 'config.json'
    if config.exists():
        data = json.loads(config.read_text(encoding='utf-8'))
    else:
        data = {'server': {'address': 'www.growtopia1.com', 'port': 16999},
                'client': {'game_version': '5.61', 'protocol': 225, 'dns_server': 'cloudflare'},
                'log': {'print_message': False, 'print_game_update_packet': False, 'print_variant': False, 'print_extra': False},
                'command': {'prefix': '/'}}
    # These upstream config fields do not select the live wire protocol.
    # Disable payload logging when setting up a build.
    for key in ('print_message', 'print_game_update_packet', 'print_variant', 'print_extra'):
        data.setdefault('log', {})[key] = False
    config.write_text(json.dumps(data, indent=2), encoding='utf-8')
    print('ALKO native patch installed. v5.61 compatibility remains unverified. Build and test.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python engine/patch_engine.py PATH_TO_GTPROXY_CHECKOUT')
    patch(Path(sys.argv[1]).expanduser().resolve())
