#!/usr/bin/env python3
"""Upload or verify manifest-ordered iPhone screenshots in an App Store draft.

Uses the same local App Store Connect credentials as assign-testflight.py.
ASC_KEY_PATH selects a key when multiple keys exist. No credentials or account
IDs are stored in this helper. Only PREPARE_FOR_SUBMISSION drafts are changed.
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import time
import urllib.request

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('asc', root / 'ios/scripts/assign-testflight.py')
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app-id', required=True)
parser.add_argument('--version', default='1.0')
parser.add_argument('--verify-only', action='store_true', help='Check files, checksums, processing and order without changing the draft')
args = parser.parse_args()
app = args.app_id
copy = json.loads((root / 'docs/brand/app-store.json').read_text())

def request(method, path, body=None):
    status, result = asc.request(method, path, body)
    asc.require_ok(status, result, method + ' ' + path)
    return result

manifest = json.loads((root / 'docs/brand/screenshots/manifest.json').read_text())
versions = request('GET', f'/v1/apps/{app}/appStoreVersions?limit=20')['data']
version = next(v for v in versions if v['attributes']['versionString'] == args.version and v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION')
localizations = request('GET', f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")['data']
localization = next(l for l in localizations if l['attributes']['locale'] == copy['locale'])
sets = request('GET', f"/v1/appStoreVersionLocalizations/{localization['id']}/appScreenshotSets")['data']
ordered = []
for display, files in [(manifest['displayType'], manifest['files'])]:
    matches = [s for s in sets if s['attributes']['screenshotDisplayType'] == display]
    if args.verify_only and not matches:
        raise SystemExit('Expected iPhone screenshot set is missing')
    screenshot_set = matches[0] if matches else request('POST', '/v1/appScreenshotSets', {'data': {
        'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': display},
        'relationships': {'appStoreVersionLocalization': {'data': {
            'type': 'appStoreVersionLocalizations', 'id': localization['id']}}}}})['data']
    existing = request('GET', f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots")['data']
    for filename in files:
        path = root / 'docs/brand/screenshots' / filename
        data = path.read_bytes()
        checksum = hashlib.md5(data).hexdigest()
        matches = [s for s in existing if s['attributes']['fileName'] == filename
                   and s['attributes'].get('sourceFileChecksum') == checksum]
        if matches:
            screenshot = matches[0]
        else:
            if args.verify_only:
                raise SystemExit('Missing screenshot or mismatched checksum: ' + filename)
            screenshot = request('POST', '/v1/appScreenshots', {'data': {
                'type': 'appScreenshots', 'attributes': {'fileName': filename, 'fileSize': len(data)},
                'relationships': {'appScreenshotSet': {'data': {
                    'type': 'appScreenshotSets', 'id': screenshot_set['id']}}}}})['data']
            for operation in screenshot['attributes']['uploadOperations']:
                headers = {h['name']: h['value'] for h in operation['requestHeaders']}
                offset, length = operation['offset'], operation['length']
                req = urllib.request.Request(operation['url'], data=data[offset:offset + length],
                                             headers=headers, method=operation['method'])
                with urllib.request.urlopen(req, timeout=60) as response:
                    assert 200 <= response.status < 300
            screenshot = request('PATCH', '/v1/appScreenshots/' + screenshot['id'], {'data': {
                'type': 'appScreenshots', 'id': screenshot['id'], 'attributes': {
                    'uploaded': True, 'sourceFileChecksum': checksum}}})['data']
        ordered.append({'type': 'appScreenshots', 'id': screenshot['id']})
        for attempt in range(30):
            screenshot = request('GET', '/v1/appScreenshots/' + screenshot['id'])['data']
            state = screenshot['attributes']['assetDeliveryState']
            if state['state'] == 'COMPLETE':
                print('Verified screenshot:', display, filename, flush=True)
                break
            if state['state'] == 'FAILED':
                raise SystemExit('Screenshot processing failed: ' + str(state))
            time.sleep(2)
        else:
            raise SystemExit('Screenshot processing still pending: ' + filename)
    if not args.verify_only:
        request('PATCH', f"/v1/appScreenshotSets/{screenshot_set['id']}/relationships/appScreenshots", {'data': ordered})
    final = request('GET', f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots")['data']
    assert [s['attributes']['fileName'] for s in final] == files
    print('Verified screenshot order:', ', '.join(files), flush=True)
print('iPhone draft screenshots verified.', flush=True)
