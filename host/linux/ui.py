# SPDX-License-Identifier: GPL-3.0-only
"""Native GTK frontend; normal app operation only, never invoked by agent fixtures."""
import io
import json
import os
import shlex
import signal
from pathlib import Path
import threading
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gio, GdkPixbuf
import qrcode
from policy import Failure, invitation
from runtime import OwnedHost, Store, addresses, download, open_installer, save_package, cleanup_owned


class LatestProgress:
    """One pending UI callback holds the latest fraction across operation generations."""
    def __init__(self, schedule, deliver):
        self.schedule, self.deliver = schedule, deliver
        self.lock = threading.Lock()
        self.token, self.latest, self.pending = None, None, False

    def begin(self, token):
        with self.lock:
            self.token, self.latest = token, None

    def report(self, token, value):
        with self.lock:
            if token is not self.token: return
            self.latest = value
            if self.pending: return
            self.pending = True
        self.schedule(self.drain)

    def drain(self):
        with self.lock:
            token, value = self.token, self.latest
            self.latest, self.pending = None, False
        if token is not None and value is not None: self.deliver(token, value)
        return False

    def finish(self, token, value=None):
        # Called on the UI thread before the terminal status/new operation. A
        # previously queued drain stays pending and can service the next token.
        with self.lock:
            if token is not self.token: return
            value = self.latest if value is None else value
            self.token, self.latest = None, None
        if value is not None: self.deliver(token, value)


class Window(Gtk.Window):
    def __init__(self, pin):
        super().__init__(title='Knot · 이 Linux 공유')
        self.pin, self.store, self.package = pin, None, None
        self.host, self.cancel = OwnedHost(), threading.Event()
        self.busy, self.running, self.closing = False, False, False
        self.operation_kind = None
        self.operation_token = None
        self.generation = 0
        self.qr_bytes, self.link_text = None, ''
        self.set_default_size(740, 700)
        self.set_border_width(24)
        self.connect('delete-event', self.on_close)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self.signal_close)
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14); self.add(layout)
        scroll = Gtk.ScrolledWindow(); scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        layout.pack_start(scroll, True, True, 0)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14); scroll.add(body)
        def label(text):
            item = Gtk.Label(label=text, xalign=0); item.set_line_wrap(True); item.set_selectable(True)
            body.pack_start(item, False, False, 0); return item
        title = label('이 Linux를 다른 컴퓨터에서 열기'); title.set_markup('<big><b>이 Linux를 다른 컴퓨터에서 열기</b></big>')
        label('Ubuntu 24.04 LTS amd64 · 로그인한 X11 데스크톱\nMac·Windows에서 같은 Wi-Fi 또는 이미 연결된 Tailscale로 접속합니다. Wayland·로그인 화면·헤드리스·파일 전송은 아직 지원하지 않습니다.')
        label('1. 공식 Sunshine 설치\n아래에서 고정 버전 패키지를 받은 뒤 시스템 설치 프로그램을 직접 여세요. 설치 인증은 Ubuntu가 처리합니다. Sunshine 앱/사용자 서비스는 따로 시작하지 마세요. 기존 Sunshine은 자동 교체하거나 종료하지 않습니다.')
        self.download_button = Gtk.Button(label='공식 Sunshine 받기'); body.pack_start(self.download_button, False, False, 0)
        self.download_button.connect('clicked', lambda _: self.run(self.get_package, self.got_package, kind='download'))
        self.install_button = Gtk.Button(label='받은 패키지를 시스템 설치 프로그램으로 열기'); body.pack_start(self.install_button, False, False, 0)
        self.install_button.connect('clicked', lambda _: self.run(lambda: open_installer(self.pin, self.package), lambda _: self.status.set_text('Ubuntu 설치 창에서 완료하세요. 설치 뒤 공유 시작을 누르면 설치 버전·바이너리·입력 권한을 확인합니다.')))
        self.export_button = Gtk.Button(label='검증된 설치 패키지 사본 저장…'); body.pack_start(self.export_button, False, False, 0)
        self.export_button.connect('clicked', lambda _: self.export_package())
        label('설치 창이 열리지 않으면 아래 명령으로 보호된 원본을 직접 설치하세요. 패키지 사본은 별도로 저장할 수 있습니다. 이 명령은 복사용이며 앱이 실행하지 않습니다.')
        self.install_command = Gtk.Entry(); self.install_command.set_editable(False)
        self.install_command.get_accessible().set_name('직접 설치 명령, 복사용')
        body.pack_start(self.install_command, False, False, 0)
        self.progress = Gtk.ProgressBar(); body.pack_start(self.progress, False, False, 0)
        self.progress.get_accessible().set_name('Sunshine 패키지 다운로드 진행률')
        self.download_progress = LatestProgress(GLib.idle_add, lambda token, value:
            self.progress.set_fraction(value) if self.operation_token is token and not self.closing and not self.cancel.is_set() else None)
        label('2. 이 Linux 공유 시작\n최초 공유 전에 웹 관리자 계정을 준비합니다. 아래 비밀번호는 평문 저장하거나 QR에 넣지 않습니다. 기존 계정이 있으면 유지하며 아래 입력으로 변경하지 않습니다. 화면과 키보드·마우스의 원격 제어를 허용합니다.')
        self.admin_name = Gtk.Entry(); self.admin_name.set_text('deskbridge'); self.admin_name.set_max_length(64)
        self.admin_name.get_accessible().set_name('최초 Sunshine 웹 관리자 이름, 영문 숫자 밑줄 하이픈'); body.pack_start(self.admin_name, False, False, 0)
        self.admin_password = Gtk.Entry(); self.admin_password.set_visibility(False); self.admin_password.set_max_length(128)
        self.admin_password.set_placeholder_text('최초 웹 관리자 비밀번호 · 16~128바이트')
        self.admin_password.get_accessible().set_name('최초 Sunshine 웹 관리자 비밀번호, 16~128바이트'); body.pack_start(self.admin_password, False, False, 0)
        self.name = Gtk.Entry(); self.name.set_placeholder_text('연결 QR에 표시할 PC 이름'); self.name.set_text('Linux Desktop')
        self.name.get_accessible().set_name('연결 QR에 표시할 PC 이름')
        self.name.set_max_length(64); body.pack_start(self.name, False, False, 0)
        self.start_button = Gtk.Button(label='이 Linux 공유 시작'); body.pack_start(self.start_button, False, False, 0)
        self.start_button.connect('clicked', lambda _: self.start())
        self.stop_button = Gtk.Button(label='공유 중지'); body.pack_start(self.stop_button, False, False, 0)
        self.stop_button.connect('clicked', lambda _: self.run(self.host.stop, lambda _: self.stopped()))
        self.web_button = Gtk.Button(label='이 컴퓨터의 Sunshine 웹 설정 / PIN 열기'); body.pack_start(self.web_button, False, False, 0)
        self.web_button.connect('clicked', lambda _: self.open_web())
        label('웹 설정에서 위 관리자 계정으로 로그인하세요. localhost의 자체 서명 인증서는 주소를 직접 확인하세요. 클라이언트에서 PIN을 만들고 이 컴퓨터의 PIN 페이지에 입력합니다. 웹 설정은 로컬 요청만 허용하며 화면 전송 암호화는 필수로 고정합니다.')
        label('3. Mac의 Linux 화면 / Windows의 Linux 열기에서 접속\n주소·QR은 기기 신원을 증명하지 않습니다. PIN과 저장된 인증서를 별도로 확인합니다. Tailscale 주소도 이 Linux에 이미 할당돼 있어야 합니다.')
        self.refresh_button = Gtk.Button(label='내 주소와 연결 QR 만들기 / 새로 고침'); body.pack_start(self.refresh_button, False, False, 0)
        self.refresh_button.connect('clicked', lambda _: self.refresh())
        self.link = Gtk.Entry(); self.link.set_editable(False); self.link.set_placeholder_text('공유 시작 후 연결 링크가 표시됩니다. 직접 선택해서 복사하세요.'); body.pack_start(self.link, False, False, 0)
        self.link.get_accessible().set_name('이 Linux의 연결 링크')
        self.qr = Gtk.Image(); body.pack_start(self.qr, False, False, 0)
        self.qr.get_accessible().set_name('Linux 연결 QR')
        self.qr.get_accessible().set_description('위 연결 링크와 같은 PC 이름 및 주소 안내입니다. 접속 권한은 별도 PIN으로 확인하세요.')
        self.save_button = Gtk.Button(label='QR PNG 저장…'); body.pack_start(self.save_button, False, False, 0)
        self.save_button.connect('clicked', lambda _: self.save_qr())
        self.status = Gtk.Label(label='공유가 꺼져 있습니다. 다운로드·설치·공유 시작은 각각 직접 선택하세요.', xalign=0)
        self.status.set_line_wrap(True); self.status.set_selectable(True); layout.pack_start(self.status, False, False, 0)
        self.cancel_button = Gtk.Button(label='진행 중인 다운로드 취소'); layout.pack_start(self.cancel_button, False, False, 0)
        self.cancel_button.connect('clicked', lambda _: self.cancel.set())
        label('방화벽을 자동 변경하지 않습니다. 필요한 Sunshine 포트를 신뢰하는 LAN/Tailscale에서만 허용하세요. 공유 프로세스 실행만으로 화면·오디오·입력의 성공을 확인했다고 표시하지 않습니다.')
        self.show_all(); self.controls()

    def storage(self):
        if self.store is None:
            self.store = Store(Path.home() / '.local/share/deskbridge-linux-v1')
        return self.store

    def controls(self):
        for button in (self.download_button, self.start_button, self.refresh_button):
            button.set_sensitive(not self.busy and not self.closing and (not self.running or button == self.refresh_button))
        self.install_button.set_sensitive(self.package is not None and not self.busy and not self.running and not self.closing)
        self.export_button.set_sensitive(self.package is not None and not self.busy and not self.running and not self.closing)
        self.stop_button.set_sensitive(self.running and not self.busy and not self.closing)
        self.web_button.set_sensitive(self.running and not self.closing)
        self.save_button.set_sensitive(self.qr_bytes is not None and not self.busy and not self.closing)
        self.name.set_sensitive(not self.running and not self.busy and not self.closing)
        self.admin_name.set_sensitive(not self.running and not self.busy and not self.closing)
        self.admin_password.set_sensitive(not self.running and not self.busy and not self.closing)
        self.cancel_button.set_sensitive(self.busy and self.operation_kind == 'download' and not self.closing)

    def run(self, work, completed, kind=None):
        if self.busy or self.closing: return
        token = object(); self.operation_token = token
        if kind == 'download': self.download_progress.begin(token)
        self.busy = True; self.operation_kind = kind; self.cancel.clear(); self.controls()
        def execute():
            result, failure = None, None
            try: result = work()
            except Exception as error:
                failure = str(error) if isinstance(error, Failure) else str(Failure('operation'))
                if getattr(error, 'cleanup_failed', False):
                    failure += ' 임시 패키지 사본을 정리하지 못했습니다. 선택한 저장 폴더에서 숨김 파일을 표시하고 .deskbridge-package-로 시작하는 임시 사본을 확인하세요.'
            GLib.idle_add(finish, result, failure)
        def finish(result, failure):
            if self.operation_token is not token: return False
            if kind == 'download': self.download_progress.finish(token, 1.0 if failure is None else None)
            self.operation_token = None
            self.busy = False; self.operation_kind = None
            if self.closing: self.shutdown(); return False
            if failure: self.status.set_text(failure)
            else:
                try: completed(result)
                except Exception: self.status.set_text(str(Failure('operation')))
            self.controls(); return False
        threading.Thread(target=execute, daemon=False).start()

    def get_package(self):
        token = self.operation_token
        return download(self.pin, self.storage(), self.cancel, lambda value: self.download_progress.report(token, value))

    def got_package(self, package):
        self.package = package
        self.install_command.set_text('sudo apt install ' + shlex.quote(str(package)))
        self.status.set_text('공식 패키지의 크기와 SHA256을 확인했습니다. 시스템 설치 프로그램 열기 또는 패키지 사본 저장을 선택하세요. 설치·공유는 아직 시작하지 않았습니다.')

    def export_package(self):
        if self.busy or self.closing or self.package is None: return
        dialog = Gtk.FileChooserDialog(title='검증된 Sunshine 패키지 사본 저장', parent=self, action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons('취소', Gtk.ResponseType.CANCEL, '저장', Gtk.ResponseType.OK)
        dialog.set_current_name(self.package.name)
        try:
            if dialog.run() == Gtk.ResponseType.OK:
                destination = dialog.get_filename()
                self.run(lambda: save_package(self.pin, self.package, destination), self.exported_package)
        finally: dialog.destroy()

    def exported_package(self, destination):
        # Export destinations may be shared or replaceable. Privileged install
        # guidance continues to name the private, verified managed source.
        self.status.set_text('설치 패키지 사본을 저장했습니다. 아래 설치 명령은 보호된 원본을 사용합니다. 설치 후 이 Linux 공유 시작을 누르세요.')

    def start(self):
        name = self.name.get_text()
        username, password = self.admin_name.get_text(), self.admin_password.get_text()
        def work(): self.host.start(self.pin, self.storage(), name, username, password)
        def completed(_):
            self.admin_password.set_text('')
            self.running = True; self.generation += 1
            self.status.set_text('관리자 인증을 준비하고 공유 프로세스를 시작했습니다. 웹 설정에 로그인해 PIN을 승인하고, 클라이언트에서 실제 화면·입력·오디오를 확인하세요.')
            self.monitor(self.generation)
        self.run(work, completed)

    def monitor(self, epoch):
        def check():
            while epoch == self.generation:
                try:
                    if not self.host.alive():
                        GLib.idle_add(exited, False); return
                except Exception:
                    GLib.idle_add(exited, self.host.child is not None); return
                threading.Event().wait(1)
        def exited(uncertain):
            if epoch == self.generation:
                self.running = uncertain
                self.status.set_text('공유 상태를 확인하지 못했습니다. 공유가 실행 중일 수 있으니 공유 중지로 정리한 뒤 다시 시도하세요.' if uncertain else str(Failure('exit')))
                self.controls()
            return False
        threading.Thread(target=check, daemon=True).start()

    def stopped(self):
        self.generation += 1; self.running = False
        self.status.set_text('이 앱이 실행한 공유를 중지했습니다. 페어링과 개인 설정은 유지됩니다.')

    def refresh(self):
        if not self.running: self.status.set_text('먼저 이 Linux 공유를 시작하세요.'); return
        name = self.name.get_text()
        def work():
            values = addresses()
            text = invitation(name, values)
            code = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=5, border=4)
            code.add_data(text); code.make(fit=True)
            output = io.BytesIO(); code.make_image(fill_color='black', back_color='white').save(output, format='PNG')
            return text, output.getvalue()
        def completed(result):
            self.link_text, self.qr_bytes = result; self.link.set_text(self.link_text)
            loader = GdkPixbuf.PixbufLoader.new_with_type('png'); loader.write(self.qr_bytes); loader.close()
            pixbuf = loader.get_pixbuf()
            if pixbuf.get_width() > 420:
                pixbuf = pixbuf.scale_simple(420, 420, GdkPixbuf.InterpType.NEAREST)
            self.qr.set_from_pixbuf(pixbuf)
            self.status.set_text('이 컴퓨터의 주소 안내를 만들었습니다. QR에는 PC 이름·IPv4 주소·Linux 표시만 포함됩니다. 접속 권한은 별도 PIN으로 확인하세요.')
        self.run(work, completed)

    def save_qr(self):
        if self.busy or self.closing or self.qr_bytes is None: return
        dialog = Gtk.FileChooserDialog(title='연결 QR PNG 저장', parent=self, action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons('취소', Gtk.ResponseType.CANCEL, '저장', Gtk.ResponseType.OK)
        dialog.set_current_name('Knot-Linux-connection.png')
        try:
            if dialog.run() == Gtk.ResponseType.OK:
                try: Store.write_new(dialog.get_filename(), self.qr_bytes); self.status.set_text('연결 QR PNG를 저장했습니다. 파일에 접속 비밀은 포함하지 않습니다.')
                except FileExistsError: self.status.set_text(str(Failure('collision')))
                except Exception: self.status.set_text(str(Failure('operation')))
        finally: dialog.destroy()

    def open_web(self):
        try: Gio.AppInfo.launch_default_for_uri('https://localhost:47990', None)
        except Exception: self.status.set_text('브라우저에서 https://localhost:47990 을 직접 여세요.')

    def on_close(self, *_):
        if self.closing: return True
        self.closing = True; self.cancel.set(); self.controls()
        if not self.busy: self.shutdown()
        return True

    def signal_close(self):
        self.on_close(); return True

    def shutdown(self):
        self.status.set_text('이 앱이 실행한 공유를 정리하는 중입니다…')
        self.generation += 1
        def work():
            cleanup_owned(self.host, self.store, lambda: GLib.idle_add(Gtk.main_quit),
                          lambda: GLib.idle_add(self.shutdown_failed))
        threading.Thread(target=work, daemon=False).start()

    def shutdown_failed(self):
        self.closing = False
        self.running = self.host.child is not None
        self.status.set_text('공유 정리를 완료하지 못했습니다. 공유가 계속 실행 중일 수 있습니다. 공유 중지를 다시 누르고 직접 실행 상태를 확인하세요. 창과 설정 잠금을 유지합니다.')
        self.controls()
        if self.running: self.monitor(self.generation)
        return False


def main(pin_path):
    os.umask(0o077)
    with open(pin_path, encoding='utf-8') as stream: pin = json.load(stream)
    Window(pin)
    Gtk.main()
