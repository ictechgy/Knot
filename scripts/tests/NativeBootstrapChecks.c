/* SPDX-License-Identifier: GPL-3.0-only
 * Host-only pure checks. No Windows headers, process starts, ACLs or network. */
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <wchar.h>
#include "../../packaging/windows/NativeArguments.h"
static unsigned count;
static void expect(int value,const char *message) { if (!value) { fprintf(stderr,"%s\n",message); exit(1); } ++count; }
/* Test-only composition bridge: no bootstrap process, dialogs or Windows APIs. */
static int result_cli(int argc,char **argv) {
    db_operation operation; long code; char *end=NULL;
    if (argc!=4 || strcmp(argv[1],"--headless-result")!=0) return 2;
    if (strcmp(argv[2],"InstallVirtualDisplay")==0) operation=DB_INSTALL_DISPLAY;
    else if (strcmp(argv[2],"RemoveVirtualDisplay")==0) operation=DB_REMOVE_DISPLAY;
    else return 2;
    if (!argv[3][0] || !((argv[3][0]>='0' && argv[3][0]<='9') ||
        (argv[3][0]=='-' && argv[3][1]>='0' && argv[3][1]<='9'))) return 2;
    errno=0; code=strtol(argv[3],&end,10);
    if (errno==ERANGE || !end || *end || code<INT_MIN || code>INT_MAX) return 2;
    printf("{\"exitCode\":%d,\"showFailure\":%s}\n",db_complete_exit_code((int)code,0,operation,1),db_show_failure((int)code,0,operation)?"true":"false");
    return 0;
}
static void completion_matrix(void) {
    struct operation_case { db_operation operation; int headless; } operations[]={
        {DB_INVALID,0},{DB_NORMAL,0},{DB_ENABLE,0},{DB_EXPORT,0},{DB_DISABLE,0},{DB_INSTALL,0},
        {DB_INSTALL_DISPLAY,1},{DB_REMOVE_DISPLAY,1},{(db_operation)-2,0},{(db_operation)7,0}
    };
    /* Explicit expected outcomes for every result class and integer boundary.
     * Silent calls always use the unacknowledged result, even if a caller passes
     * acknowledged=1: no acknowledgement dialog was actually permitted. */
    struct status_case { int code,generic_dialog,headless_dialog,generic_unack,generic_ack,headless_unack,headless_ack; } statuses[]={
        {0,0,0,0,0,0,0}, {1,1,1,1,2,1,2}, {2,0,0,2,2,2,2}, {3,1,1,3,2,3,2}, {11,1,1,11,2,11,2},
        {12,1,0,1,2,12,12}, {13,1,0,1,2,13,13}, {14,1,1,14,2,14,2},
        {1602,0,0,1602,1602,1602,1602}, {3010,0,0,3010,3010,3010,3010}, {3011,1,1,3011,2,3011,2},
        {1618,1,1,1618,2,1618,2}, {1641,1,1,1641,2,1641,2},
        {-1,1,1,-1,2,-1,2}, {INT_MAX,1,1,INT_MAX,2,INT_MAX,2}, {INT_MIN,1,1,INT_MIN,2,INT_MIN,2}
    };
    size_t operation_index,status_index; int silent,acknowledged;
    for (operation_index=0;operation_index<sizeof(operations)/sizeof(*operations);++operation_index)
        for (status_index=0;status_index<sizeof(statuses)/sizeof(*statuses);++status_index)
            for (silent=0;silent<=1;++silent)
                for (acknowledged=0;acknowledged<=1;++acknowledged) {
                    struct operation_case operation=operations[operation_index];
                    struct status_case status=statuses[status_index];
                    int dialog=operation.headless?status.headless_dialog:status.generic_dialog;
                    int expected=operation.headless?status.headless_unack:status.generic_unack;
                    if (!silent && acknowledged) expected=operation.headless?status.headless_ack:status.generic_ack;
                    if (operation.operation==DB_INSTALL && (status.code==1618 || status.code==1641)) {
                        dialog=0; expected=status.code;
                    }
                    expect(db_show_failure(status.code,silent,operation.operation)==(!silent && dialog),"operation/result matrix displayed the wrong generic failure guidance");
                    expect(db_complete_exit_code(status.code,silent,operation.operation,acknowledged)==expected,"operation/result matrix changed or accepted an invalid final status");
                }
    expect(db_complete_exit_code(12,0,DB_INSTALL_DISPLAY,1)==12 && !db_show_failure(12,0,DB_INSTALL_DISPLAY),"install continuation status was replaced after generic acknowledgement");
    expect(db_complete_exit_code(13,0,DB_REMOVE_DISPLAY,1)==13 && !db_show_failure(13,0,DB_REMOVE_DISPLAY),"remove recovery status was replaced after generic acknowledgement");
    expect(db_complete_exit_code(12,0,DB_NORMAL,1)==2 && db_show_failure(12,0,DB_NORMAL),"normal entry accepted a headless continuation status");
    expect(db_complete_exit_code(13,1,DB_INVALID,1)==1 && !db_show_failure(13,1,DB_INVALID),"an invalid silent entry preserved a headless recovery status");
}
int main(int argc,char **argv) {
    if (argc!=1) return result_cli(argc,argv);
    const wchar_t *good_ip[]={L"10.0.0.1",L"172.16.0.1",L"192.168.1.20",L"100.64.0.1",L"169.254.1.2"};
    const wchar_t *bad_ip[]={L"8.8.8.8",L"127.0.0.1",L"localhost",L"::1",L"192.168.01.1",L"10.0.0.1/24",L"10.0.0.1 --arg",L"100.128.0.1",L"10.256.0.1",L"10.1.1"};
    const wchar_t *bad_paths[]={L"relative.msi",L"\\\\host\\share\\x.msi",L"C:\\x.msi:evil",L"C:\\..\\x.msi",L"C:\\a\\.\\x.msi",L"C:\\a\\\\x.msi",L"C:\\a.\\x.msi",L"C:/x.msi",L"C:\\x.msi\" --arg",L"C:\\x.exe"};
    const wchar_t *bad_b64[]={L"",L"YQ",L"YQ===",L" YQ==",L"YR==",L"YQ==YQ==",L"AA==",L"//8=",L"wIA=",L"7aCA",L"9JCAgA==",L"8J+A",L"Zg=\n"};
    size_t i; wchar_t quoted[1024]; size_t used;
    for (i=0;i<sizeof(good_ip)/sizeof(*good_ip);++i) expect(db_private_ip(good_ip[i]),"private IP rejected");
    for (i=0;i<sizeof(bad_ip)/sizeof(*bad_ip);++i) expect(!db_private_ip(bad_ip[i]),"unsafe IP accepted");
    for (i=0;i<sizeof(bad_paths)/sizeof(*bad_paths);++i) expect(!db_local_file(bad_paths[i],L".msi"),"unsafe MSI path accepted");
    expect(db_local_file(L"C:\\새 폴더\\Sunshine.MSI",L".msi"),"literal local MSI rejected");
    expect(db_desktop_sid(L"S-1-5-21-1-2-3-1001"),"desktop SID rejected");
    expect(!db_desktop_sid(L"S-1-5-32-544"),"admin group SID accepted");
    expect(!db_desktop_sid(L"S-1-5-21-01-2-3-1001"),"noncanonical SID accepted");
    expect(!db_desktop_sid(L"S-1-5-21-1-2-3-4294967296"),"overflow SID accepted");
    for (i=0;i<sizeof(bad_b64)/sizeof(*bad_b64);++i) expect(!db_request_base64(bad_b64[i]),"invalid/unsafe public request accepted");
    expect(db_request_base64(L"e30="),"public JSON snapshot rejected");
    expect(db_request_base64(L"7ZWc6riA"),"valid UTF8 snapshot rejected");
    expect(db_request_base64(L"8J+agA=="),"valid supplementary UTF8 snapshot rejected");
    {
        wchar_t *large=calloc(21849,sizeof(wchar_t)); size_t at=0;
        expect(large!=NULL,"request boundary allocation failed");
        for (i=0;i<5461;++i) { large[at++]=L'Y'; large[at++]=L'W'; large[at++]=L'F'; large[at++]=L'h'; }
        wcscpy(large+at,L"YQ=="); expect(db_request_base64(large),"16384-byte request rejected");
        wcscpy(large+at,L"YWE="); expect(!db_request_base64(large),"16385-byte request accepted"); free(large);
    }
    {
        const wchar_t *disable[]={L"--elevated-operation",L"DisableFiles"};
        const wchar_t *disable_silent[]={L"--elevated-operation",L"DisableFiles",L"--silent"};
        const wchar_t *disable_invalid[]={L"--elevated-operation",L"DisableFiles",L"--silent",L"extra"};
        const wchar_t *export_silent[]={L"--elevated-operation",L"Export",L"--request-base64",L"e30=",L"--windows-address",L"192.168.1.20",L"--silent"};
        const wchar_t *install[]={L"--elevated-operation",L"InstallSunshine",L"--msi-path",L"C:\\Sunshine.msi"};
        const wchar_t *export_args[]={L"--elevated-operation",L"Export",L"--request-base64",L"e30=",L"--windows-address",L"192.168.1.20"};
        const wchar_t *enable[]={L"--elevated-operation",L"EnableFiles",L"--request-base64",L"e30=",L"--windows-address",L"100.80.1.20",L"--desktop-user-sid",L"S-1-5-21-1-2-3-1001"};
        const wchar_t *unknown[]={L"--elevated-operation",L"RunScript"};
        const wchar_t *override[]={L"--elevated-operation",L"DisableFiles",L"--script-path",L"C:\\evil.ps1"};
        const wchar_t *bootstrap[]={L"--bootstrap-path",L"C:\\fake.exe"};
        expect(db_dispatch(0,NULL)==DB_NORMAL,"normal entry rejected");
        expect(db_dispatch(2,disable)==DB_DISABLE,"fixed disable rejected");
        expect(!db_silent_disable(2,disable),"ordinary disable must retain visible failure guidance");
        expect(db_dispatch(3,disable_silent)==DB_DISABLE && db_silent_disable(3,disable_silent),"strict silent uninstall revocation rejected");
        expect(db_dispatch(4,disable_invalid)==DB_INVALID && !db_silent_disable(4,disable_invalid),"extra silent revocation arguments accepted");
        expect(db_dispatch(7,export_silent)==DB_INVALID && !db_silent_disable(7,export_silent),"silent must be restricted to revocation");
        expect(db_dispatch(4,install)==DB_INSTALL,"fixed installation rejected");
        {
            const wchar_t *quick[]={L"--elevated-operation",L"QuickSetupSunshine",L"--url",L"https://example.invalid"};
            const wchar_t *combined[]={L"--elevated-operation",L"InstallSunshineAndSetup",L"--msi-path",L"C:\\fixture.msi",L"--silent"};
            expect(db_dispatch(2,quick)==DB_QUICK_SETUP,"fixed native setup rejected");
            expect(db_dispatch(3,quick)==DB_INVALID && db_dispatch(4,quick)==DB_INVALID,"native setup accepted caller URL or extra arguments");
            expect(db_dispatch(4,combined)==DB_INSTALL,"fixed combined installation rejected");
            expect(db_dispatch(3,combined)==DB_INVALID && db_dispatch(5,combined)==DB_INVALID,"combined install accepted missing/extra arguments");
            combined[3]=L"\\\\server\\fixture.msi";
            expect(db_dispatch(4,combined)==DB_INVALID,"combined install accepted network path");
        }
        expect(db_dispatch(6,export_args)==DB_EXPORT,"fixed export rejected");
        expect(db_dispatch(8,enable)==DB_ENABLE,"fixed enable rejected");
        expect(db_dispatch(2,unknown)==DB_INVALID,"unknown operation accepted");
        expect(db_dispatch(4,override)==DB_INVALID,"script override accepted");
        expect(db_dispatch(2,bootstrap)==DB_INVALID,"caller managed handoff accepted by outer");
        expect(db_dispatch(7,enable)==DB_INVALID,"missing SID accepted");
    }
    {
        const wchar_t *install[]={L"--elevated-operation",L"InstallVirtualDisplay",L"--zip-path",L"C:\\Knot\\VirtualDisplay.zip",L"--silent"};
        const wchar_t *remove[]={L"--elevated-operation",L"RemoveVirtualDisplay",L"--instance-id",L"ROOT\\FOREIGN\\0000"};
        const wchar_t *zip_paths[]={L"C:\\새 폴더\\VirtualDisplay.ZIP",L"D:\\one&two\\driver.zip",L"C:\\$fixture\\driver.zip"};
        const wchar_t *unsafe_zip[]={L"",L"relative.zip",L"C:relative.zip",L"\\\\host\\share\\driver.zip",L"\\\\?\\C:\\driver.zip",
            L"C:/driver.zip",L"C:\\a\\..\\driver.zip",L"C:\\a\\.\\driver.zip",L"C:\\a\\\\driver.zip",L"C:\\a.\\driver.zip",
            L"C:\\a \\driver.zip",L"C:\\driver.zip:stream",L"C:\\driver.zip.exe",L"C:\\driver.msi",L"C:\\*.zip",L"C:\\driver.zip\" --arg"};
        wchar_t control_path[]=L"C:\\fixture\\a.zip";
        wchar_t boundary[1026];
        expect(db_dispatch(4,install)==DB_INSTALL_DISPLAY,"fixed virtual display installation rejected");
        expect(db_dispatch(3,install)==DB_INVALID && db_dispatch(5,install)==DB_INVALID,"virtual display installation accepted missing or extra args");
        expect(db_dispatch(2,remove)==DB_REMOVE_DISPLAY,"fixed virtual display removal rejected");
        expect(db_dispatch(3,remove)==DB_INVALID && db_dispatch(4,remove)==DB_INVALID,"virtual display removal accepted caller-selected identity");
        remove[2]=L"--silent";
        expect(db_dispatch(3,remove)==DB_INVALID,"virtual display removal accepted silent bypass");
        install[2]=L"--msi-path";
        expect(db_dispatch(4,install)==DB_INVALID,"virtual display installation accepted wrong package argument");
        install[2]=L"--zip-path";
        for (i=0;i<sizeof(zip_paths)/sizeof(*zip_paths);++i) { install[3]=zip_paths[i]; expect(db_dispatch(4,install)==DB_INSTALL_DISPLAY,"literal local ZIP rejected"); }
        for (i=0;i<sizeof(unsafe_zip)/sizeof(*unsafe_zip);++i) { install[3]=unsafe_zip[i]; expect(db_dispatch(4,install)==DB_INVALID,"unsafe ZIP boundary accepted"); }
        for (i=1;i<32;++i) { control_path[10]=(wchar_t)i; install[3]=control_path; expect(db_dispatch(4,install)==DB_INVALID,"C0 control in ZIP path accepted"); }
        wcscpy(boundary,L"C:\\"); for (i=3;i<1020;++i) boundary[i]=L'a'; wcscpy(boundary+1020,L".zip"); install[3]=boundary;
        expect(db_dispatch(4,install)==DB_INSTALL_DISPLAY,"bounded 1024-character ZIP path rejected");
        boundary[1020]=L'a'; wcscpy(boundary+1021,L".zip");
        expect(db_dispatch(4,install)==DB_INVALID,"oversized ZIP path accepted");
        install[3]=NULL; expect(db_dispatch(4,install)==DB_INVALID,"null ZIP path accepted");
    }
    {
        const wchar_t *inputs[]={L"",L"plain",L"two words",L"C:\\tail\\",L"a\\\"b",L"a\"b",L"한국어"};
        const wchar_t *outputs[]={L"\"\"",L"\"plain\"",L"\"two words\"",L"\"C:\\tail\\\\\"",L"\"a\\\\\\\"b\"",L"\"a\\\"b\"",L"\"한국어\""};
        for (i=0;i<sizeof(inputs)/sizeof(*inputs);++i) { used=0; quoted[0]=0; expect(db_quote(quoted,1024,&used,inputs[i]) && wcscmp(quoted,outputs[i])==0,"CRT quote mismatch"); }
        used=0; expect(!db_quote(quoted,3,&used,L"long"),"quote overflow accepted");
    }
    expect(!db_show_failure(0,0,DB_NORMAL),"successful child must not show error");
    expect(db_show_failure(1,0,DB_NORMAL),"unhandled bootstrap failure must show guidance");
    expect(!db_show_failure(2,0,DB_NORMAL),"managed handled error must not be shown twice");
    expect(!db_show_failure(3010,0,DB_INSTALL),"MSI reboot-required is a status, not a bootstrap failure");
    expect(!db_show_failure(1602,0,DB_INSTALL),"MSI cancellation is a status, not a bootstrap error dialog");
    {
        const wchar_t *keep[]={L"USERPROFILE=C:\\Users\\Synthetic",L"APPDATA=C:\\Users\\Synthetic\\AppData\\Roaming",L"LOCALAPPDATA=C:\\Users\\Synthetic\\AppData\\Local",L"PATH=C:\\Tools",L"DEVPATH_EXTRA=ordinary"};
        const wchar_t *drop[]={L"COR_ENABLE_PROFILING=1",L"coreclr_profiler_path=C:\\bad.dll",L"complus_Version=bad",L"DOTNET_STARTUP_HOOKS=bad",L"APPDOMAIN_MANAGER_ASM=bad",L"DevPath=C:\\bad",L"psmodulepath=C:\\bad",L"PSExecutionPolicyPreference=Bypass",L"TEMP=C:\\ambient",L"TMP=C:\\ambient",L"SystemRoot=C:\\bad",L"__COMPAT_LAYER=RunAsInvoker",L"=C:=C:\\ambient"};
        for (i=0;i<sizeof(keep)/sizeof(*keep);++i) expect(db_keep_normal_env(keep[i]),"normal user environment unexpectedly discarded");
        for (i=0;i<sizeof(drop)/sizeof(*drop);++i) expect(!db_keep_normal_env(drop[i]),"ambient loader/temp/system override retained");
        expect(db_env_name(L"PaTh=C:\\Tools",L"PATH",0),"normal PATH detection must be case insensitive");
    }
    expect(!db_show_failure(1,1,DB_DISABLE) && !db_show_failure(2,1,DB_DISABLE),"silent uninstall must not show either failure path");
    completion_matrix();
    printf("{\"status\":\"passed\",\"checks\":%u,\"scope\":\"pure native bootstrap dispatch, result completion matrix, UTF8 public request bounds and Windows CRT quoting; no Windows operations\"}\n",count);
    return 0;
}
