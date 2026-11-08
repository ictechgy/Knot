// SPDX-License-Identifier: GPL-3.0-only
using System;

namespace Knot.NativePreview
{
    internal enum HostViewPhase { Idle, Invitation, Request, Preparing, Sharing, Stopping, Stopped, Failed, RegisteredWaiting }

    // Presentation-only data: no invitation capability, certificate private key,
    // host lifecycle object, or network action is stored in a view snapshot.
    internal sealed class HostViewSnapshot
    {
        internal readonly HostViewPhase Phase;
        internal readonly bool HasAddress, RunPresent, CanCopy, EnrollmentMode;
        internal readonly string Pin, ViewerLabel, ObservedAddress, Status;
        internal HostViewSnapshot(HostViewPhase phase, bool hasAddress, bool runPresent, string pin, string label, string address, string status, bool canCopy = true, bool enrollmentMode = false)
        {
            Phase = phase; HasAddress = hasAddress; RunPresent = runPresent; CanCopy = canCopy;
            EnrollmentMode = enrollmentMode;
            Pin = pin ?? ""; ViewerLabel = label ?? ""; ObservedAddress = address ?? ""; Status = status ?? "";
        }
    }

    internal static class PreviewCopy
    {
        internal const string CertificateConversionAction = "호환 인증서로 전환하고 공유";
        internal const string CertificateConversionTitle = "Mac 연결용 인증서를 전환해주세요";
        internal const string CertificateConversionDisclosure = "이전 인증서의 키 또는 유효기간은 Mac 보안 기준에 맞지 않아요. 아래 버튼을 누르면 호환 인증서로 교체하고 공유를 시작해요.\r\n등록한 Mac은 초기화되므로 새 8자리 번호로 다시 등록해야 해요.";
        internal const string CertificateRenewalAction = "만료 인증서 갱신하고 공유";
        internal const string CertificateRenewalTitle = "공유 인증서가 만료됐어요";
        internal const string CertificateRenewalDisclosure = "아래 버튼을 누르면 이전 Mac 등록을 모두 해제하고 새 인증서를 만들어요.\r\nMac에서도 이전 PC를 지운 뒤 새 8자리 번호로 다시 등록해주세요.";
        internal static string Privacy(bool enrollment, bool files)
        {
            string scope = files ? "화면·입력, 표시한 공유 폴더와 직접 끈 탐색기 항목을 허용해요." : "화면과 입력을 허용해요.";
            return enrollment ? scope + " 번호를 아는 Mac과 등록된 Mac이 접속할 수 있어요. Mac에서 ‘내 PC로 등록’을 선택하면 이후 번호 없이 접속해요. 연결 안내에서 등록을 해제할 수 있어요." :
                scope + " 이 연결은 Windows에서 직접 허용해야 해요. 중지하면 이번 연결 권한을 종료해요.";
        }
        internal const string ShareTitle = "이 Windows의 화면을 Mac으로 공유";
        internal const string Onboarding = "1  이 Windows에서 ‘화면 공유 시작’\r\n2  Mac에서 ‘주변 PC 찾기’ → 이 PC 선택\r\n3  선택한 PC의 8자리 번호를 Mac에 입력";
        internal const string NumberTitle = "Mac에서 이 PC를 먼저 선택하세요";
        internal const string NumberInstruction = "‘주변 PC 찾기’에서 아래 PC를 선택한 다음,\r\n다음 화면에 이 8자리 번호를 입력하세요.";
        internal const string NumberLifetime = "공유 시작 후 2분 · 1회용. 번호를 아는 Mac 한 대에 이번 공유 권한을 허용해요.";
        internal static string DiscoveryName(string value)
        {
            // Pass this exact validated value to HostServer as well as the UI.
            // Discovery names are identification hints, never a trust decision.
            try { EnrollmentProtocol.ValidName(value); return value; }
            catch (ProtocolException) { return "Windows PC"; }
        }
        internal static string Phase(HostViewPhase phase)
        {
            switch (phase)
            {
                case HostViewPhase.RegisteredWaiting: return "등록된 Mac 대기 중";
                case HostViewPhase.Invitation: return "연결 코드 준비됨";
                case HostViewPhase.Request: return "연결 요청 도착";
                case HostViewPhase.Preparing: return "화면 준비 중";
                case HostViewPhase.Sharing: return "화면 전송 중";
                case HostViewPhase.Stopping: return "공유 종료 중";
                case HostViewPhase.Stopped: return "공유 종료됨";
                case HostViewPhase.Failed: return "확인이 필요해요";
                default: return "공유 전";
            }
        }
        internal static string Status(string text)
        {
            switch (text)
            {
                case "Invitation ready. Expires in 120 seconds. Waiting for a viewer.":
                    return "Mac에서 연결 코드를 입력한 뒤, 이 PC에서 요청을 허용해주세요.";
                case "Viewer is waiting for your approval. No capture or input has started.":
                    return "연결할 Mac을 확인해주세요. 아직 화면과 입력은 공유되지 않았어요.";
                case "Approved. Initializing the primary SDR display and hardware encoder.":
                    return "연결을 허용했어요. Windows 화면과 인코더를 준비하고 있어요.";
                case "Invitation expired. Click Share for a fresh invitation.":
                    return "연결 코드가 만료됐어요. 새 코드를 만들어주세요.";
                case "Invitation authentication failed. Click Share for a fresh invitation.":
                    return "연결 코드를 확인하지 못했어요. 새 코드로 다시 연결해주세요.";
                case "Host declined the viewer request. Click Share for a fresh invitation.":
                    return "연결 요청을 거절했어요. 다시 연결하려면 새 코드를 만들어주세요.";
                case "Hardware H.264 encoding is unavailable or failed. Check the graphics driver and encoder availability; then create a fresh invitation.":
                    return "선택한 화질의 하드웨어 인코더를 사용할 수 없어요. 그래픽 드라이버를 확인하거나 호환 모드로 다시 시작해주세요.";
                case "Display unsupported. Use a logged-in, unlocked primary SDR display without rotation or HDR.":
                    return "로그인된 기본 SDR 가로 화면이 필요해요. HDR과 화면 회전을 확인해주세요.";
                case "The graphics device was lost or could not be initialized. Check the display and graphics driver; then create a fresh invitation.":
                    return "그래픽 장치를 준비하지 못했어요. 화면과 드라이버를 확인해주세요.";
                case "Desktop capture could not continue. Check that the primary desktop is available; then create a fresh invitation.":
                    return "Windows 화면을 가져오지 못했어요. 기본 화면이 켜져 있고 잠금이 풀렸는지 확인해주세요.";
                case "Remote input could not be applied safely. Sharing stopped; create a fresh invitation.":
                    return "원격 입력을 안전하게 적용하지 못해 공유를 중지했어요. 새 코드로 연결해주세요.";
                case "Input rate exceeded the bounded allowance (500 envelopes/second average, burst 1000). Sharing stopped; create a fresh invitation.":
                    return "입력 요청이 너무 많아 공유를 중지했어요. 새 코드로 연결해주세요.";
                case "Session timed out. Click Share for a fresh invitation.":
                    return "연결 대기 시간이 끝났어요. 새 코드를 만들어주세요.";
                case "Connection ended. Waiting to reconnect a registered device.":
                    return "연결이 끝났어요. 등록된 Mac의 재연결을 기다리고 있어요.";
                case "Session stopped. Check the host before reconnecting.":
                    return "안전하게 연결을 계속할 수 없어 공유를 중지했어요. Windows의 공유 상태를 확인해주세요.";
                case "Session stopped. Click Share for a fresh invitation.":
                case "Connection ended. Create a new invitation.":
                    return "연결이 종료됐어요. 다시 연결하려면 새 코드를 만들어주세요.";
                case "TLS authentication failed. Create a new invitation.":
                    return "연결 인증을 확인하지 못했어요. 새 코드와 인증서 지문을 확인해주세요.";
                case "Native preview could not start. Check the bundled media engine and supported SDR display.":
                    return "화면 공유를 시작하지 못했어요. 지원되는 SDR 화면과 설치 파일을 확인해주세요.";
                default:
                    // This only translates the authored success notice. Lifecycle
                    // decisions never inspect this string or the claimed name.
                    if (text != null && text.StartsWith("Sharing with claimed viewer label (UNVERIFIED): ", StringComparison.Ordinal))
                        return "화면을 전송하고 있어요. 중지하면 이번 연결의 권한이 끝나요.";
                    return text ?? "";
            }
        }
    }
}
