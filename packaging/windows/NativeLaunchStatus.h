/* SPDX-License-Identifier: GPL-3.0-only
 * Pure launch diagnostics: only authored text and a bounded 32-bit status leave
 * this boundary. A child exit is never interpreted as a Windows API failure. */
#ifndef KNOT_NATIVE_LAUNCH_STATUS_H
#define KNOT_NATIVE_LAUNCH_STATUS_H
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

typedef enum {
    DB_LAUNCH_PREPARE, DB_LAUNCH_START_FAILED, DB_LAUNCH_WAIT_FAILED,
    DB_LAUNCH_WAIT_UNEXPECTED, DB_LAUNCH_EXIT_QUERY_FAILED, DB_LAUNCH_CHILD_EXIT
} db_launch_stage;
typedef struct { db_launch_stage stage; uint32_t code; } db_launch_result;
typedef enum {
    DB_LAUNCH_UNKNOWN, DB_LAUNCH_SIGNATURE, DB_LAUNCH_APP_POLICY,
    DB_LAUNCH_SECURITY_SOFTWARE, DB_LAUNCH_IMAGE_FORMAT
} db_launch_category;
#define DB_LAUNCH_MESSAGE_CAP 768

static db_launch_category db_launch_classify(db_launch_result result) {
    if (result.stage!=DB_LAUNCH_START_FAILED) return DB_LAUNCH_UNKNOWN;
    switch (result.code) {
    case 577: return DB_LAUNCH_SIGNATURE; /* ERROR_INVALID_IMAGE_HASH */
    case 1260: return DB_LAUNCH_APP_POLICY; /* ERROR_ACCESS_DISABLED_BY_POLICY */
    case 225: case 226: return DB_LAUNCH_SECURITY_SOFTWARE;
    case 193: case 216: return DB_LAUNCH_IMAGE_FORMAT;
    default: return DB_LAUNCH_UNKNOWN;
    }
}
static int db_launch_exit_code(db_launch_result result) {
    if (result.stage!=DB_LAUNCH_CHILD_EXIT) return 1;
    /* Preserve the child's DWORD bit pattern without an out-of-range signed cast. */
    return result.code<=INT32_MAX?(int)result.code:-1-(int)(UINT32_MAX-result.code);
}
static const wchar_t *db_launch_guidance(db_launch_result result) {
    switch (db_launch_classify(result)) {
    case DB_LAUNCH_SIGNATURE:
        return L"Windows가 설정 도우미의 이미지 서명을 확인하지 못해 실행을 거부했습니다. 새 Knot 배포 파일을 사용하고 Windows 보안 및 조직의 앱 실행 정책을 관리자와 확인하세요.";
    case DB_LAUNCH_APP_POLICY:
        return L"Windows가 그룹 정책에 따라 설정 도우미의 실행을 차단했습니다. Windows 관리자에게 Knot 배포 파일의 실행 승인을 확인하세요.";
    case DB_LAUNCH_SECURITY_SOFTWARE:
        return L"Windows가 악성 소프트웨어 또는 원치 않는 소프트웨어 감지를 보고하며 설정 도우미를 실행하지 못했습니다. Windows 보안의 보호 기록과 배포 파일을 관리자와 확인하세요.";
    case DB_LAUNCH_IMAGE_FORMAT:
        return L"Windows가 설정 도우미의 실행 파일 형식 또는 시스템 종류 문제를 보고했습니다. Windows 11 x64용 Knot 배포 파일을 다시 받아 실행하세요.";
    default: break;
    }
    if (result.stage==DB_LAUNCH_START_FAILED)
        return L"설정 도우미를 시작하지 못했습니다. Knot 배포 파일을 다시 실행하고, 계속 실패하면 Windows 관리자에게 아래 진단을 전달하세요.";
    if (result.stage==DB_LAUNCH_CHILD_EXIT)
        return L"설정 도우미가 작업을 완료하지 못하고 종료했습니다. Knot을 다시 열고, 계속 실패하면 Windows 관리자에게 아래 진단을 전달하세요.";
    if (result.stage==DB_LAUNCH_WAIT_FAILED || result.stage==DB_LAUNCH_WAIT_UNEXPECTED || result.stage==DB_LAUNCH_EXIT_QUERY_FAILED)
        return L"설정 도우미의 종료 결과를 확인하지 못했습니다. 작업 완료 여부를 확인한 뒤 다시 시도하고, 계속 실패하면 Windows 관리자에게 아래 진단을 전달하세요.";
    return L"설정 도우미의 시작 준비를 완료하지 못했습니다. Knot 배포 파일과 실행 환경을 확인한 뒤 다시 실행하세요.";
}
static const wchar_t *db_launch_stage_name(db_launch_stage stage) {
    switch (stage) {
    case DB_LAUNCH_START_FAILED: return L"bootstrap.start / Win32 ";
    case DB_LAUNCH_WAIT_FAILED: return L"bootstrap.wait / Win32 ";
    case DB_LAUNCH_WAIT_UNEXPECTED: return L"bootstrap.wait-result / status ";
    case DB_LAUNCH_EXIT_QUERY_FAILED: return L"bootstrap.exit-query / Win32 ";
    case DB_LAUNCH_CHILD_EXIT: return L"bootstrap.child-exit / code ";
    default: return L"bootstrap.prepare / status ";
    }
}
static int db_launch_text(wchar_t *out,size_t capacity,size_t *used,const wchar_t *text) {
    while (*text) {
        if (*used+1>=capacity) return 0;
        out[(*used)++]=*text++; out[*used]=0;
    }
    return 1;
}
static int db_launch_message(wchar_t *out,size_t capacity,db_launch_result result) {
    wchar_t digits[11]; size_t used=0,count=0; uint32_t code=result.code;
    if (!out || !capacity) return 0;
    out[0]=0;
    if (!db_launch_text(out,capacity,&used,db_launch_guidance(result)) ||
        !db_launch_text(out,capacity,&used,L"\n\n진단: ") ||
        !db_launch_text(out,capacity,&used,db_launch_stage_name(result.stage))) return 0;
    do { digits[count++]=(wchar_t)(L'0'+code%10); code/=10; } while (code);
    while (count) {
        wchar_t digit[2]; digit[0]=digits[--count]; digit[1]=0;
        if (!db_launch_text(out,capacity,&used,digit)) return 0;
    }
    return 1;
}
#endif
