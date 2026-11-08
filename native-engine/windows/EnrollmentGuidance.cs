// SPDX-License-Identifier: GPL-3.0-only
using System;

namespace Knot.NativePreview
{
    internal enum EnrollmentFailure { Authentication, StaleCandidate, Protocol, Expired, Closed, Setup, Unavailable, Delivery }
    internal sealed class EnrollmentAttemptException : Exception
    {
        internal readonly EnrollmentFailure Failure;
        internal readonly string WireCode;
        internal EnrollmentAttemptException(EnrollmentFailure failure, string wireCode) { Failure = failure; WireCode = wireCode; }
    }
    internal static class EnrollmentGuidance
    {
        internal const string RegisteredWaiting = "일회용 번호는 끝났어요. 등록된 Mac은 ‘내 PC’에서 연결할 수 있어요. 새 Mac은 공유를 중지한 뒤 다시 시작해 등록해주세요.";
        internal const string Ready = "Mac: 주변 PC 찾기 → 이 PC 선택 → 8자리 번호 입력. 표시한 공유 범위가 허용되며 추가 승인은 없어요.";
        internal static EnrollmentFailure Classify(ProtocolException error)
        {
            if (error.Code == "expired") return EnrollmentFailure.Expired;
            if (error.Code == "closed") return EnrollmentFailure.Closed;
            // Only a confirmation tag failure is classified as Authentication
            // by the call site. Other cryptographic/protocol errors stay neutral.
            return EnrollmentFailure.Protocol;
        }
        internal static string For(EnrollmentFailure failure)
        {
            switch (failure)
            {
                case EnrollmentFailure.Authentication: return "연결번호를 확인하지 못했어요. Mac에서 번호를 다시 입력해주세요.";
                case EnrollmentFailure.StaleCandidate: return "PC 선택 정보가 바뀌었어요. Mac에서 ‘주변 PC 찾기’를 다시 누르고 이 PC를 선택해주세요.";
                case EnrollmentFailure.Expired: return "연결 시도 시간이 끝났어요. 번호가 남아 있으면 다시 연결하고, 번호가 사라졌으면 새로 공유해주세요.";
                case EnrollmentFailure.Closed: return "연결 준비가 중지됐어요. 다시 연결하려면 새로 공유해주세요.";
                case EnrollmentFailure.Setup: return "보안 연결 구성요소를 불러오지 못했어요. 설치 파일과 Windows 보안의 차단 알림을 확인한 뒤 다시 공유해주세요.";
                case EnrollmentFailure.Unavailable: return "연결번호가 만료됐거나 시도 횟수를 모두 사용했어요. 새 번호로 다시 공유해주세요.";
                case EnrollmentFailure.Delivery: return "번호는 확인했지만 연결 정보를 전달하지 못했어요. 화면 공유를 중지한 뒤 새 번호로 다시 공유해주세요.";
                default: return "연결 형식을 확인하지 못했어요. Mac에서 PC를 다시 선택하고 두 기기의 Knot Native Preview 버전을 확인해주세요.";
            }
        }
    }
}
