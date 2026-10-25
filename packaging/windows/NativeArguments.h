/* SPDX-License-Identifier: GPL-3.0-only
 * Pure command/quoting boundary shared by the native bootstrap and host-side checks. */
#ifndef DESKBRIDGE_NATIVE_ARGUMENTS_H
#define DESKBRIDGE_NATIVE_ARGUMENTS_H
#include <stddef.h>
#include <stdint.h>
#include <wchar.h>

typedef enum { DB_INVALID = -1, DB_NORMAL = 0, DB_ENABLE, DB_EXPORT, DB_DISABLE, DB_INSTALL, DB_INSTALL_DISPLAY, DB_REMOVE_DISPLAY, DB_QUICK_SETUP, DB_CLOSE_UPDATE } db_operation;
static size_t db_length(const wchar_t *s) { size_t n=0; if (s) while (s[n]) ++n; return n; }
static int db_equal(const wchar_t *a,const wchar_t *b) { return a && b && wcscmp(a,b)==0; }
static int db_digit(wchar_t c) { return c>=L'0' && c<=L'9'; }
static int db_private_ip(const wchar_t *s) {
    unsigned int parts[4]; int i; const wchar_t *p=s;
    if (!p || db_length(p)>15) return 0;
    for (i=0;i<4;++i) {
        unsigned int value=0; int digits=0;
        if (!db_digit(*p) || (*p==L'0' && db_digit(p[1]))) return 0;
        while (db_digit(*p)) { value=value*10+(unsigned)(*p++-L'0'); if (++digits>3 || value>255) return 0; }
        parts[i]=value; if (i<3) { if (*p++!=L'.') return 0; } else if (*p) return 0;
    }
    return parts[0]==10 || (parts[0]==172 && parts[1]>=16 && parts[1]<=31) ||
        (parts[0]==192 && parts[1]==168) || (parts[0]==100 && parts[1]>=64 && parts[1]<=127) || (parts[0]==169 && parts[1]==254);
}
static int db_desktop_sid(const wchar_t *s) {
    const wchar_t *p; int i;
    if (!s || db_length(s)>80 || wcsncmp(s,L"S-1-5-21-",9)!=0) return 0;
    p=s+9;
    for (i=0;i<4;++i) {
        uint64_t value=0; int digits=0;
        if (!db_digit(*p) || (*p==L'0' && db_digit(p[1]))) return 0;
        while (db_digit(*p)) { value=value*10+(unsigned)(*p++-L'0'); if (++digits>10 || value>UINT32_MAX) return 0; }
        if (i<3) { if (*p++!=L'-') return 0; } else if (*p) return 0;
    }
    return 1;
}
static int db_base64_value(wchar_t c) {
    if (c>=L'A' && c<=L'Z') return (int)(c-L'A');
    if (c>=L'a' && c<=L'z') return (int)(c-L'a')+26;
    if (c>=L'0' && c<=L'9') return (int)(c-L'0')+52;
    return c==L'+'?62:(c==L'/'?63:-1);
}
typedef struct { unsigned left,low,high; } db_utf8_state;
static int db_utf8_byte(db_utf8_state *state,unsigned b) {
    if (state->left) {
        if (b<state->low || b>state->high) return 0;
        --state->left; state->low=0x80; state->high=0xbf; return 1;
    }
    if (b>0 && b<0x80) return 1;
    state->low=0x80; state->high=0xbf;
    if (b>=0xc2 && b<=0xdf) state->left=1;
    else if (b>=0xe0 && b<=0xef) { state->left=2; if (b==0xe0) state->low=0xa0; if (b==0xed) state->high=0x9f; }
    else if (b>=0xf0 && b<=0xf4) { state->left=3; if (b==0xf0) state->low=0x90; if (b==0xf4) state->high=0x8f; }
    else return 0;
    return 1;
}
static int db_request_base64(const wchar_t *s) {
    size_t n=db_length(s),i,bytes=0; db_utf8_state utf={0,0,0};
    if (!s || !n || n>21848 || n%4) return 0;
    for (i=0;i<n;i+=4) {
        int a=db_base64_value(s[i]),b=db_base64_value(s[i+1]),c=db_base64_value(s[i+2]),d=db_base64_value(s[i+3]);
        if (a<0 || b<0) return 0;
        if (++bytes>16384 || !db_utf8_byte(&utf,(unsigned)((a<<2)|(b>>4)))) return 0;
        if (s[i+2]==L'=') { if (i+4!=n || s[i+3]!=L'=' || (b&15)) return 0; }
        else {
            if (c<0 || ++bytes>16384 || !db_utf8_byte(&utf,(unsigned)(((b&15)<<4)|(c>>2)))) return 0;
            if (s[i+3]==L'=') { if (i+4!=n || (c&3)) return 0; }
            else if (d<0 || ++bytes>16384 || !db_utf8_byte(&utf,(unsigned)(((c&3)<<6)|d))) return 0;
        }
    }
    return utf.left==0;
}
static int db_local_file(const wchar_t *path,const wchar_t *extension) {
    size_t n=db_length(path),e=db_length(extension),start=3,i;
    if (!path || n<4 || n>1024 || !((path[0]>=L'A'&&path[0]<=L'Z')||(path[0]>=L'a'&&path[0]<=L'z')) || path[1]!=L':' || path[2]!=L'\\' || n<e) return 0;
    for (i=3;i<=n;++i) {
        wchar_t c=path[i];
        if (c && (c<32 || c==L'"' || c==L'/' || c==L':' || c==L'<' || c==L'>' || c==L'|' || c==L'?' || c==L'*')) return 0;
        if (c==L'\\' || !c) {
            size_t length=i-start;
            if (!length || (length==1 && path[start]==L'.') || (length==2 && path[start]==L'.' && path[start+1]==L'.') || path[i-1]==L'.' || path[i-1]==L' ') return 0;
            start=i+1;
        }
    }
    for (i=0;i<e;++i) {
        wchar_t c=path[n-e+i]; if (c>=L'A' && c<=L'Z') c+=L'a'-L'A';
        if (c!=extension[i]) return 0;
    }
    return 1;
}
static db_operation db_close_update_dispatch(int argc,const wchar_t *const *argv) {
    const wchar_t *name,*p;
    if (argc!=1 || !argv || !db_local_file(argv[0],L".exe")) return DB_INVALID;
    name=argv[0]; for (p=name;*p;++p) if (*p==L'\\') name=p+1;
    return db_equal(name,L"Knot.exe") || db_equal(name,L"DeskBridge-Windows.exe")?DB_CLOSE_UPDATE:DB_INVALID;
}
static int db_silent_disable(int argc,const wchar_t *const *argv) {
    return argc==3 && argv && db_equal(argv[0],L"--elevated-operation") && db_equal(argv[1],L"DisableFiles") && db_equal(argv[2],L"--silent");
}
/* argv excludes argv[0]. Only these fixed operation schemas cross UAC. */
static db_operation db_dispatch(int argc,const wchar_t *const *argv) {
    int enable;
    if (argc==0) return DB_NORMAL;
    if (!argv || argc<2 || !db_equal(argv[0],L"--elevated-operation")) return DB_INVALID;
    if (db_equal(argv[1],L"DisableFiles")) return argc==2 || db_silent_disable(argc,argv)?DB_DISABLE:DB_INVALID;
    if (db_equal(argv[1],L"QuickSetupSunshine")) return argc==2?DB_QUICK_SETUP:DB_INVALID;
    if (db_equal(argv[1],L"InstallSunshine") || db_equal(argv[1],L"InstallSunshineAndSetup")) return argc==4 && db_equal(argv[2],L"--msi-path") && db_local_file(argv[3],L".msi")?DB_INSTALL:DB_INVALID;
    if (db_equal(argv[1],L"InstallVirtualDisplay")) return argc==4 && db_equal(argv[2],L"--zip-path") && db_local_file(argv[3],L".zip")?DB_INSTALL_DISPLAY:DB_INVALID;
    if (db_equal(argv[1],L"RemoveVirtualDisplay")) return argc==2?DB_REMOVE_DISPLAY:DB_INVALID;
    enable=db_equal(argv[1],L"EnableFiles");
    if ((!enable && !db_equal(argv[1],L"Export")) || argc!=(enable?8:6) || !db_equal(argv[2],L"--request-base64") ||
        !db_request_base64(argv[3]) || !db_equal(argv[4],L"--windows-address") || !db_private_ip(argv[5]) ||
        (enable && (!db_equal(argv[6],L"--desktop-user-sid") || !db_desktop_sid(argv[7])))) return DB_INVALID;
    return enable?DB_ENABLE:DB_EXPORT;
}
/* Headless continuation/recovery statuses are meaningful only for these two
 * fixed operations; they already carry actionable managed guidance. */
static int db_headless_status(int exit_code,db_operation operation) {
    return (operation==DB_INSTALL_DISPLAY || operation==DB_REMOVE_DISPLAY) && (exit_code==12 || exit_code==13);
}
/* Exit 2 means the managed helper already displayed its failure; it is still failure. */
static int db_show_failure(int exit_code,int silent,db_operation operation) {
    int installer_status=operation==DB_INSTALL && (exit_code==1641 || exit_code==1618);
    return !installer_status && !db_headless_status(exit_code,operation) && exit_code!=0 && exit_code!=2 && exit_code!=1602 && exit_code!=3010 && !silent;
}
static int db_complete_exit_code(int exit_code,int silent,db_operation operation,int acknowledged) {
    if (db_headless_status(exit_code,operation)) return exit_code;
    /* A non-headless child cannot introduce a valid headless status. */
    if (exit_code==12 || exit_code==13) exit_code=1;
    return db_show_failure(exit_code,silent,operation) && acknowledged?2:exit_code;
}
static int db_env_name(const wchar_t *entry,const wchar_t *name,int prefix) {
    size_t i;
    if (!entry || !name) return 0;
    for (i=0;name[i];++i) {
        wchar_t a=entry[i],b=name[i];
        if (a>=L'a' && a<=L'z') a-=L'a'-L'A';
        if (b>=L'a' && b<=L'z') b-=L'a'-L'A';
        if (a!=b) return 0;
    }
    return prefix || entry[i]==L'=';
}
/* Normal user environment is retained only after loader hooks and fixed overrides are removed. */
static int db_keep_normal_env(const wchar_t *entry) {
    static const wchar_t *prefixes[]={L"COR_",L"CORECLR_",L"COMPLUS_",L"DOTNET_",L"APPDOMAIN_",L"CLR_"};
    static const wchar_t *exact[]={L"DEVPATH",L"PSMODULEPATH",L"PSEXECUTIONPOLICYPREFERENCE",L"TEMP",L"TMP",L"WINDIR",L"SYSTEMROOT",L"SYSTEMDRIVE",L"PROGRAMDATA",L"PROCESSOR_ARCHITECTURE",L"OS",L"COMPUTERNAME",L"__COMPAT_LAYER"};
    size_t i;
    if (!entry || !*entry || *entry==L'=') return 0;
    for (i=0;i<sizeof(prefixes)/sizeof(*prefixes);++i) if (db_env_name(entry,prefixes[i],1)) return 0;
    for (i=0;i<sizeof(exact)/sizeof(*exact);++i) if (db_env_name(entry,exact[i],0)) return 0;
    return 1;
}
static int db_append(wchar_t *out,size_t capacity,size_t *used,wchar_t c) {
    if (*used+1>=capacity) return 0;
    out[(*used)++]=c; out[*used]=0; return 1;
}
/* Windows CRT quoting, including trailing backslashes and embedded quotes. */
static int db_quote(wchar_t *out,size_t capacity,size_t *used,const wchar_t *argument) {
    const wchar_t *p=argument; size_t slashes;
    if (!p || !db_append(out,capacity,used,L'"')) return 0;
    for (;;) {
        slashes=0; while (*p==L'\\') { ++slashes; ++p; }
        if (*p==L'"' || !*p) slashes*=2;
        while (slashes--) if (!db_append(out,capacity,used,L'\\')) return 0;
        if (!*p) break;
        if (*p==L'"' && !db_append(out,capacity,used,L'\\')) return 0;
        if (!db_append(out,capacity,used,*p++)) return 0;
    }
    return db_append(out,capacity,used,L'"');
}
#endif
