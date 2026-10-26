# SPDX-License-Identifier: GPL-3.0-only
"""Pure Linux host policy. No GTK import, network, process, or user-state reads."""
import ipaddress
import json
import hashlib
import re
import secrets
import urllib.parse

MAX_INVITATION = 1536


class Failure(Exception):
    """Only authored keys cross the UI error boundary."""
    messages = {
        'session': 'Ubuntu 24.04 LTS amd64의 로그인한 X11 세션에서 실행하세요. 로그인 화면에서 사용자를 선택한 뒤 톱니바퀴 → Ubuntu on Xorg로 로그인하세요. Wayland·헤드리스는 아직 지원하지 않습니다.',
        'install': '안내된 공식 Sunshine 패키지를 설치하세요. 이미 다른 버전이 있다면 직접 확인하세요. 기존 설치를 자동 교체하지 않습니다.',
        'credentials': '최초 공유 전에 웹 관리자 이름(영문·숫자·_·-)과 16~128바이트 비밀번호를 입력하세요. 기존 계정 파일이 손상됐다면 설정을 백업하고 확인하세요. 자동 초기화하지 않습니다.',
        'input': '키보드·마우스 입력 권한이 없습니다. 공식 Sunshine 설치 후 로그아웃·로그인 또는 재부팅하고 다시 시도하세요. input 그룹이나 광범위한 장치 권한은 자동 부여하지 않습니다.',
        'containment': '공유 프로세스를 안전하게 종료하는 데 필요한 Linux 실행 제한을 적용하지 못해 시작을 중단했습니다. Ubuntu 24.04 LTS amd64의 지원 커널에서 실행하고, 관리되는 환경이라면 관리자에게 seccomp 사용 정책을 확인하세요. 보안 제한을 해제하지 마세요.',
        'existing': 'Sunshine이 이미 실행 중이거나 기본 포트를 사용 중입니다. 기존 Sunshine과 사용자 서비스를 직접 종료한 뒤 다시 시도하세요.',
        'storage': '앱 전용 폴더의 소유자·권한·사용 잠금을 확인하지 못했습니다. 다른 창을 닫고 다시 시도하세요. 계속 실패하면 README의 저장소 복구 안내에 따라 전체 폴더를 백업하고 확인하세요. 기존 설정·페어링을 자동으로 가져오거나 지우지 않습니다.',
        'download': '공식 Sunshine 다운로드의 크기·해시를 확인하지 못했습니다. 인터넷 연결을 확인하고 다시 받으세요.',
        'download_collision': '기존 다운로드 파일의 크기·해시 또는 권한을 확인하지 못했습니다. README의 다운로드 복구 안내에 따라 downloads 안의 해당 sunshine-버전-ubuntu24.04-amd64.deb 파일만 별도로 확인하고 옮긴 뒤 다시 받으세요. 앱이 자동으로 지우거나 덮어쓰지 않습니다.',
        'cancel': '작업을 취소했습니다.',
        'configuration': 'PC 이름·주소·앱 저장 경로를 확인하세요. 이름에 제어 문자나 # [ ] =를 사용할 수 없습니다.',
        'name_length': 'PC 이름이 너무 깁니다. 한글은 42자 이내, 영문·숫자는 64자 이내로 줄여 다시 시도하세요.',
        'no_address': '연결 QR에 사용할 LAN 또는 Tailscale IPv4 주소를 찾지 못했습니다. Wi-Fi·유선 LAN 또는 Tailscale에 연결한 뒤 다시 만드세요. IPv6만 있는 연결과 컨테이너·링크 로컬 주소는 QR 주소로 제안하지 않습니다.',
        'export_destination': '설치 패키지 사본을 저장하지 못했습니다. 쓰기 권한과 새 파일 저장·이름 변경을 지원하는 다른 로컬 폴더를 선택하세요. 기존 파일은 덮어쓰지 않습니다.',
        'exit': '공유 프로세스가 종료되었습니다. X11 세션·GPU 인코더·입력 권한·포트 충돌을 확인하고 다시 시작하세요.',
        'operation': '작업을 완료하지 못했습니다. 설치·권한·네트워크 상태를 확인하고 다시 시도하세요.',
        'collision': '같은 이름의 파일이 있습니다. 다른 이름으로 저장하세요.',
    }
    def __init__(self, key):
        self.key = key if key in self.messages else 'operation'
        super().__init__(self.messages[self.key])


def valid_name(name):
    import unicodedata
    return (isinstance(name, str) and bool(name) and name == name.strip() and
            len(name.encode('utf-16-le')) // 2 <= 64 and len(name.encode('utf-8')) <= 128 and
            not any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs') for c in name))


def validate_name(name):
    try:
        if isinstance(name, str) and (len(name.encode('utf-16-le')) // 2 > 64 or len(name.encode('utf-8')) > 128):
            raise Failure('name_length')
        if not valid_name(name): raise Failure('configuration')
    except UnicodeError:
        raise Failure('configuration') from None


def web_credentials(username, password, salt=None):
    import unicodedata
    salt = salt or secrets.token_hex(16)
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', username) or not 16 <= len(password.encode()) <= 128 or any(unicodedata.category(c) == 'Cc' for c in password):
        raise Failure('credentials')
    # Pinned util::hex reverses the digest bytes, then emits uppercase hex.
    digest = hashlib.sha256((password + salt).encode()).digest()[::-1].hex().upper()
    return json.dumps(dict(username=username, password=digest, salt=salt), sort_keys=True).encode()


def validate_web_credentials(data):
    try:
        value = json.loads(data)
        if (not isinstance(value, dict) or not isinstance(value.get('username'), str) or not 1 <= len(value['username'].encode()) <= 256 or
            not isinstance(value.get('salt'), str) or not 1 <= len(value['salt'].encode()) <= 256 or
            not isinstance(value.get('password'), str) or not re.fullmatch(r'[0-9A-F]{64}', value['password'])):
            raise ValueError()
    except (ValueError, TypeError, UnicodeError): raise Failure('credentials') from None


def address(value):
    try:
        ip = ipaddress.IPv4Address(value)
    except (ValueError, TypeError):
        raise Failure('configuration') from None
    allowed = ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10', '169.254.0.0/16')
    if str(ip) != value or not any(ip in ipaddress.IPv4Network(n) for n in allowed):
        raise Failure('configuration')
    return value


def invitation(name, addresses):
    validate_name(name)
    if not addresses: raise Failure('no_address')
    if len(addresses) > 8 or len(set(addresses)) != len(addresses):
        raise Failure('configuration')
    values = [('v', '2'), ('name', name)] + [('address', address(a)) for a in addresses] + [('platform', 'linux')]
    text = 'deskbridge://connect?' + urllib.parse.urlencode(values, quote_via=urllib.parse.quote, safe='')
    if len(text.encode()) > MAX_INVITATION:
        raise Failure('configuration')
    return text


def select_addresses(data):
    """Bounded iproute2 metadata, not a scan or a Tailscale peer list."""
    if len(data) > 262144:
        raise Failure('operation')
    rows = json.loads(data)
    if not isinstance(rows, list) or len(rows) > 128:
        raise Failure('operation')
    found = set()
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('flags'), list) or 'UP' not in row['flags']:
            continue
        name = row.get('ifname', '')
        if not isinstance(name, str) or name.startswith(('docker', 'br-', 'veth', 'virbr', 'lxc', 'cni', 'podman')) or 'NO-CARRIER' in row['flags']:
            continue
        info = row.get('addr_info', [])
        if not isinstance(info, list) or len(info) > 128:
            raise Failure('operation')
        for entry in info:
            if not isinstance(entry, dict) or entry.get('family') != 'inet':
                continue
            try:
                value = address(entry.get('local'))
                if not value.startswith('169.254.'):
                    found.add(value)
            except Failure:
                pass
    # Retain one representative per LAN/VPN range before filling extra slots.
    ordered = sorted(found, key=lambda a: (a.startswith('100.'), int(ipaddress.IPv4Address(a))))
    chosen, ranges = [], set()
    for value in ordered:
        group = value.split('.')[0]
        if group not in ranges:
            chosen.append(value); ranges.add(group)
    chosen.extend(v for v in ordered if v not in chosen)
    return chosen[:8]


def validate_session(os_release, machine, uid, env):
    if uid == 0 or os_release.get('ID') != 'ubuntu' or os_release.get('VERSION_ID') != '24.04' or machine != 'x86_64':
        raise Failure('session')
    if env.get('XDG_SESSION_TYPE') != 'x11' or env.get('WAYLAND_DISPLAY') or not env.get('DISPLAY'):
        raise Failure('session')


def arguments(root, name):
    text = str(root)
    validate_name(name)
    if any(c in name for c in '#[]=') or any(c in text for c in '\r\n\x00#[]=') or not text.startswith('/'):
        raise Failure('configuration')
    paths = {'file_apps': 'apps.json', 'file_state': 'state.json', 'credentials_file': 'web-credentials.json',
             'pkey': 'credentials/cakey.pem', 'cert': 'credentials/cacert.pem'}
    return [text + '/sunshine.conf'] + [k + '=' + text + '/' + v for k, v in sorted(paths.items())] + [
        'sunshine_name=' + name, 'lan_encryption_mode=2', 'wan_encryption_mode=2', 'upnp=disabled',
        'origin_web_ui_allowed=pc', 'address_family=ipv4', 'system_tray=disabled', 'controller=disabled',
        'capture=x11', 'log_path=/dev/null', 'port=47989']


def child_environment(env, root):
    # No loader hooks, Sunshine config overrides, migration or inherited shell PATH.
    keys = ('HOME', 'USER', 'LOGNAME', 'DISPLAY', 'XAUTHORITY', 'XDG_RUNTIME_DIR',
            'DBUS_SESSION_BUS_ADDRESS', 'PULSE_SERVER', 'LANG', 'LC_ALL')
    result = {k: env[k] for k in keys if k in env and '\x00' not in env[k]}
    result.update(PATH='/usr/bin:/bin', XDG_SESSION_TYPE='x11', XDG_CONFIG_HOME=str(root) + '/xdg')
    return result


def allowed_download_url(value):
    try:
        u = urllib.parse.urlsplit(value)
        return (u.scheme == 'https' and u.hostname in ('github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com')
                and not u.username and not u.password and u.port in (None, 443) and not u.fragment)
    except ValueError:
        return False
