/* SPDX-License-Identifier: GPL-3.0-only
 * The distributed EXE is genuinely native: no CLR/config is activated before the
 * elevated managed helper is in a fresh, protected directory with a clean environment. */
#define UNICODE
#define _UNICODE
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <knownfolders.h>
#include <bcrypt.h>
#include <stdint.h>
#include <wchar.h>
#include "NativeArguments.h"
#include "NativePayload.h"

#define DB_PATH_CAP 32768
#define DB_COMMAND_CAP 32767
#define DB_MAX_LOCKS 128
#define DB_MAX_MANAGED (32UL*1024UL*1024UL)
#define DB_ENV_CAP 65536

/* bcrypt is loaded from an absolute system path, never searched beside the user EXE. */
typedef NTSTATUS (WINAPI *db_open_algorithm)(BCRYPT_ALG_HANDLE *,LPCWSTR,LPCWSTR,ULONG);
typedef NTSTATUS (WINAPI *db_get_property)(BCRYPT_HANDLE,LPCWSTR,PUCHAR,ULONG,ULONG *,ULONG);
typedef NTSTATUS (WINAPI *db_create_hash)(BCRYPT_ALG_HANDLE,BCRYPT_HASH_HANDLE *,PUCHAR,ULONG,PUCHAR,ULONG,ULONG);
typedef NTSTATUS (WINAPI *db_hash_data)(BCRYPT_HASH_HANDLE,PUCHAR,ULONG,ULONG);
typedef NTSTATUS (WINAPI *db_finish_hash)(BCRYPT_HASH_HANDLE,PUCHAR,ULONG,ULONG);
typedef NTSTATUS (WINAPI *db_destroy_hash)(BCRYPT_HASH_HANDLE);
typedef NTSTATUS (WINAPI *db_close_algorithm)(BCRYPT_ALG_HANDLE,ULONG);
typedef NTSTATUS (WINAPI *db_random)(BCRYPT_ALG_HANDLE,PUCHAR,ULONG,ULONG);
static struct { HMODULE module; db_open_algorithm open; db_get_property property; db_create_hash create;
    db_hash_data data; db_finish_hash finish; db_destroy_hash destroy; db_close_algorithm close; db_random random; } db_crypto;
typedef struct { BCRYPT_ALG_HANDLE algorithm; BCRYPT_HASH_HANDLE hash; PUCHAR object; } db_hash;
typedef struct { HANDLE values[DB_MAX_LOCKS]; unsigned count; } db_locks;
static HANDLE db_heap;
static void *db_alloc(SIZE_T bytes) { return HeapAlloc(db_heap,HEAP_ZERO_MEMORY,bytes); }
static void db_free(void *p) { if (p) HeapFree(db_heap,0,p); }
static int db_copy(wchar_t *out,size_t cap,const wchar_t *text) {
    size_t i,n=db_length(text); if (!text || n>=cap) return 0;
    for (i=0;i<=n;++i) out[i]=text[i]; return 1;
}
static int db_join(wchar_t *out,size_t cap,const wchar_t *parent,const wchar_t *name) {
    size_t p=db_length(parent),n=db_length(name),i;
    while (p>3 && parent[p-1]==L'\\') --p;
    if (!parent || !name || !p || p+n+2>cap) return 0;
    for (i=0;i<p;++i) out[i]=parent[i];
    if (out[p-1]!=L'\\') out[p++]=L'\\';
    for (i=0;i<=n;++i) out[p+i]=name[i]; return 1;
}
static int db_parent(wchar_t *path) {
    size_t n=db_length(path); if (n<=3) return 0;
    while (n>3 && path[n-1]!=L'\\') --n;
    if (n>3) --n; path[n]=0; return 1;
}
static int db_local_path(const wchar_t *path) {
    return path && db_length(path)>=3 && path[1]==L':' && path[2]==L'\\' &&
        ((path[0]>=L'A' && path[0]<=L'Z') || (path[0]>=L'a' && path[0]<=L'z'));
}
static void db_unlock(db_locks *locks) { while (locks->count) CloseHandle(locks->values[--locks->count]); }
static int db_lock_image_path(const wchar_t *image,db_locks *locks) {
    wchar_t *path=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t));
    wchar_t *normalized=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)),*expected=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t));
    int first=1,ok=0; wchar_t root[4];
    BY_HANDLE_FILE_INFORMATION original;
    ZeroMemory(&original,sizeof(original));
    if (!path || !normalized || !expected || !db_local_file(image,L".exe") || !db_copy(path,DB_PATH_CAP,image)) goto done;
    root[0]=image[0]; root[1]=L':'; root[2]=L'\\'; root[3]=0;
    if (GetDriveTypeW(root)==DRIVE_REMOTE) goto done;
    for (;;) {
        HANDLE handle; BY_HANDLE_FILE_INFORMATION info;
        // A drive root has no renameable parent; avoid requesting list rights there.
        if (!first && db_length(path)==3) break;
        if (locks->count==DB_MAX_LOCKS) goto done;
        handle=CreateFileW(path,first?GENERIC_READ:(FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES|SYNCHRONIZE),first?FILE_SHARE_READ:(FILE_SHARE_READ|FILE_SHARE_WRITE),NULL,OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT|(first?0:FILE_FLAG_BACKUP_SEMANTICS),NULL);
        if (handle==INVALID_HANDLE_VALUE) goto done;
        locks->values[locks->count++]=handle;
        if (!GetFileInformationByHandle(handle,&info) || (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT) ||
            (first && (info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) || (!first && !(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY))) goto done;
        if (first) original=info;
        first=0; if (!db_parent(path)) break;
    }
    {
        HANDLE rebound; BY_HANDLE_FILE_INFORMATION actual; DWORD length; size_t at=0,i;
        if (locks->count==DB_MAX_LOCKS) goto done;
        // Bind the original open image to its pathname AFTER every ancestor is locked.
        rebound=CreateFileW(image,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,NULL);
        if (rebound==INVALID_HANDLE_VALUE) goto done;
        locks->values[locks->count++]=rebound;
        if (!GetFileInformationByHandle(rebound,&actual) || (actual.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY)) ||
            (original.nFileIndexHigh==0 && original.nFileIndexLow==0) || actual.dwVolumeSerialNumber!=original.dwVolumeSerialNumber ||
            actual.nFileIndexHigh!=original.nFileIndexHigh || actual.nFileIndexLow!=original.nFileIndexLow) goto done;
        if (!db_copy(expected,DB_PATH_CAP,L"\\\\?\\")) goto done;
        at=db_length(expected);
        for (i=0;image[i];++i) if (!db_append(expected,DB_PATH_CAP,&at,image[i])) goto done;
        length=GetFinalPathNameByHandleW(rebound,normalized,DB_PATH_CAP,FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
        if (!length || length>=DB_PATH_CAP || CompareStringOrdinal(normalized,-1,expected,-1,TRUE)!=CSTR_EQUAL) goto done;
    }
    ok=1;
done: db_free(path); db_free(normalized); db_free(expected); if (!ok) db_unlock(locks); return ok;
}
static int db_lock_directory_chain(const wchar_t *directory,db_locks *locks) {
    wchar_t *path=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); int ok=0;
    if (!path || !db_local_path(directory) || !db_copy(path,DB_PATH_CAP,directory)) goto done;
    for (;;) {
        HANDLE handle; BY_HANDLE_FILE_INFORMATION info;
        if (db_length(path)==3) break;
        if (locks->count==DB_MAX_LOCKS) goto done;
        handle=CreateFileW(path,FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES|SYNCHRONIZE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,NULL);
        if (handle==INVALID_HANDLE_VALUE) goto done;
        locks->values[locks->count++]=handle;
        if (!GetFileInformationByHandle(handle,&info) || (info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT) || !(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)) goto done;
        if (!db_parent(path)) break;
    }
    ok=1;
done: db_free(path); return ok;
}
static int db_trusted_sid(PSID sid,PSID installer) {
    return sid && (IsWellKnownSid(sid,WinLocalSystemSid) || IsWellKnownSid(sid,WinBuiltinAdministratorsSid) || EqualSid(sid,installer));
}
static int db_protected_chain(const wchar_t *start) {
    wchar_t *path=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); PSID installer=NULL; int ok=0;
    if (!path || !db_local_path(start) || !db_copy(path,DB_PATH_CAP,start) ||
        !ConvertStringSidToSidW(L"S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464",&installer)) goto done;
    for (;;) {
        DWORD attr=GetFileAttributesW(path),status; PSID owner=NULL; PACL acl=NULL; PSECURITY_DESCRIPTOR descriptor=NULL; DWORD i; int safe=1;
        if (attr==INVALID_FILE_ATTRIBUTES || !(attr&FILE_ATTRIBUTE_DIRECTORY) || (attr&FILE_ATTRIBUTE_REPARSE_POINT)) goto done;
        status=GetNamedSecurityInfoW(path,SE_FILE_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,NULL,&acl,NULL,&descriptor);
        if (status!=ERROR_SUCCESS || !descriptor || !acl || !db_trusted_sid(owner,installer)) { if (descriptor) LocalFree(descriptor); goto done; }
        for (i=0;i<acl->AceCount;++i) {
            ACE_HEADER *header=NULL;
            if (!GetAce(acl,i,(LPVOID *)&header)) { safe=0; break; }
            if (header->AceFlags&INHERIT_ONLY_ACE) continue;
            if (header->AceType==ACCESS_ALLOWED_ACE_TYPE) {
                ACCESS_ALLOWED_ACE *ace=(ACCESS_ALLOWED_ACE *)header;
                if ((ace->Mask&(DELETE|FILE_DELETE_CHILD|WRITE_DAC|WRITE_OWNER|GENERIC_WRITE|GENERIC_ALL)) && !db_trusted_sid((PSID)&ace->SidStart,installer)) { safe=0; break; }
            } else if (header->AceType!=ACCESS_DENIED_ACE_TYPE) { safe=0; break; }
        }
        LocalFree(descriptor); if (!safe) goto done;
        if (!db_parent(path)) break;
    }
    ok=1;
done: if (installer) LocalFree(installer); db_free(path); return ok;
}
static int db_ordinary_directory(const wchar_t *directory) {
    wchar_t *path=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); int ok=0;
    if (!path || !db_local_path(directory) || !db_copy(path,DB_PATH_CAP,directory)) goto done;
    for (;;) {
        DWORD attributes=GetFileAttributesW(path);
        if (attributes==INVALID_FILE_ATTRIBUTES || !(attributes&FILE_ATTRIBUTE_DIRECTORY) || (attributes&FILE_ATTRIBUTE_REPARSE_POINT)) goto done;
        if (!db_parent(path)) break;
    }
    ok=1;
done: db_free(path); return ok;
}
static wchar_t *db_stable_temp(int elevated) {
    wchar_t *temporary=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)),*windows=NULL; PWSTR local_data=NULL; int ok=0;
    if (!temporary) goto done;
    if (elevated) {
        DWORD length;
        windows=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); if (!windows) goto done;
        length=GetWindowsDirectoryW(windows,DB_PATH_CAP);
        if (!length || length>=DB_PATH_CAP || !db_protected_chain(windows) || !db_join(temporary,DB_PATH_CAP,windows,L"Temp")) goto done;
    } else {
        if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData,KF_FLAG_DEFAULT,NULL,&local_data)) || !db_join(temporary,DB_PATH_CAP,local_data,L"Temp")) goto done;
    }
    // Ordinary existing OS-derived locations survive helper cleanup and browser/MSI lifetimes.
    if (!db_ordinary_directory(temporary)) goto done;
    ok=1;
done:
    if (local_data) CoTaskMemFree(local_data); db_free(windows);
    if (!ok) { db_free(temporary); temporary=NULL; } return temporary;
}
static int db_load_crypto(void) {
    wchar_t path[MAX_PATH+16]; UINT length=GetSystemDirectoryW(path,MAX_PATH);
    if (!length || length>=MAX_PATH || !db_join(path,MAX_PATH+16,path,L"bcrypt.dll")) return 0;
    db_crypto.module=LoadLibraryExW(path,NULL,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!db_crypto.module) return 0;
#define DB_CRYPTO(name,type,export_name) db_crypto.name=(type)GetProcAddress(db_crypto.module,export_name); if (!db_crypto.name) return 0
    DB_CRYPTO(open,db_open_algorithm,"BCryptOpenAlgorithmProvider");
    DB_CRYPTO(property,db_get_property,"BCryptGetProperty");
    DB_CRYPTO(create,db_create_hash,"BCryptCreateHash");
    DB_CRYPTO(data,db_hash_data,"BCryptHashData");
    DB_CRYPTO(finish,db_finish_hash,"BCryptFinishHash");
    DB_CRYPTO(destroy,db_destroy_hash,"BCryptDestroyHash");
    DB_CRYPTO(close,db_close_algorithm,"BCryptCloseAlgorithmProvider");
    DB_CRYPTO(random,db_random,"BCryptGenRandom");
#undef DB_CRYPTO
    return 1;
}
static int db_hash_begin(db_hash *state) {
    DWORD length=0,used=0;
    if (db_crypto.open(&state->algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 ||
        db_crypto.property(state->algorithm,BCRYPT_OBJECT_LENGTH,(PUCHAR)&length,sizeof(length),&used,0)<0 || length>65536 ||
        !(state->object=(PUCHAR)db_alloc(length)) || db_crypto.create(state->algorithm,&state->hash,state->object,length,NULL,0,0)<0) return 0;
    return 1;
}
static void db_hash_close(db_hash *state) {
    if (state->hash) db_crypto.destroy(state->hash);
    if (state->algorithm) db_crypto.close(state->algorithm,0);
    db_free(state->object);
}
static int db_hash_expected(db_hash *state) {
    UCHAR digest[32]; const char *expected=DB_MANAGED_SHA256; size_t i;
    if (sizeof(DB_MANAGED_SHA256)!=65 || db_crypto.finish(state->hash,digest,sizeof(digest),0)<0) return 0;
    for (i=0;i<32;++i) {
        const char *hex="0123456789abcdef";
        if (expected[2*i]!=hex[digest[i]>>4] || expected[2*i+1]!=hex[digest[i]&15]) return 0;
    }
    return 1;
}
static int db_resource(const BYTE **bytes,DWORD *size) {
    HRSRC resource=FindResourceW(NULL,MAKEINTRESOURCEW(DB_MANAGED_RESOURCE_ID),RT_RCDATA); HGLOBAL loaded; db_hash hash={0}; int ok=0;
    if (!resource || !(*size=SizeofResource(NULL,resource)) || *size>DB_MAX_MANAGED || !(loaded=LoadResource(NULL,resource)) || !(*bytes=(const BYTE *)LockResource(loaded))) return 0;
    if (!db_hash_begin(&hash) || db_crypto.data(hash.hash,(PUCHAR)*bytes,*size,0)<0 || !db_hash_expected(&hash)) goto done;
    ok=1;
done: db_hash_close(&hash); return ok;
}
static int db_make_stage(int elevated,HANDLE token,wchar_t *stage) {
    PWSTR parent=NULL; wchar_t *temporary=NULL,*sddl=NULL; LPWSTR user_sid=NULL; PSECURITY_DESCRIPTOR descriptor=NULL;
    PTOKEN_USER user=NULL; DWORD bytes=0; BYTE random[16]; wchar_t suffix[80]; SECURITY_ATTRIBUTES attributes; int i,ok=0;
    if (elevated) {
        if (FAILED(SHGetKnownFolderPath(&FOLDERID_ProgramFilesX64,KF_FLAG_DEFAULT,NULL,&parent)) || !db_protected_chain(parent)) goto done;
    } else {
        temporary=db_stable_temp(0); if (!temporary) goto done;
        parent=temporary;
        GetTokenInformation(token,TokenUser,NULL,0,&bytes);
        if (!bytes || bytes>65536 || !(user=(PTOKEN_USER)db_alloc(bytes)) || !GetTokenInformation(token,TokenUser,user,bytes,&bytes) || !ConvertSidToStringSidW(user->User.Sid,&user_sid)) goto done;
    }
    if (db_crypto.random(NULL,random,sizeof(random),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0 ||
        !db_copy(suffix,80,elevated?L"DeskBridgeBootstrapAdmin-":L"DeskBridgeBootstrap-")) goto done;
    {
        size_t at=db_length(suffix); const wchar_t *hex=L"0123456789abcdef";
        for (i=0;i<16;++i) { suffix[at++]=hex[random[i]>>4]; suffix[at++]=hex[random[i]&15]; } suffix[at]=0;
    }
    if (!db_join(stage,DB_PATH_CAP,parent,suffix)) goto done;
    sddl=(wchar_t *)db_alloc(1024*sizeof(wchar_t)); if (!sddl) goto done;
    if (elevated) { if (!db_copy(sddl,1024,L"O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")) goto done; }
    else {
        size_t at=0; const wchar_t *parts[]={L"O:",user_sid,L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;",user_sid,L")"};
        for (i=0;i<5;++i) { size_t j; for (j=0;parts[i][j];++j) if (!db_append(sddl,1024,&at,parts[i][j])) goto done; }
    }
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,SDDL_REVISION_1,&descriptor,NULL)) goto done;
    attributes.nLength=sizeof(attributes); attributes.lpSecurityDescriptor=descriptor; attributes.bInheritHandle=FALSE;
    // This native create-new fails if any existing path wins the race; no inherited writable interval.
    if (!CreateDirectoryW(stage,&attributes)) goto done;
    ok=1;
done:
    if (descriptor) LocalFree(descriptor); if (user_sid) LocalFree(user_sid); db_free(user); db_free(sddl);
    if (parent && parent!=temporary) CoTaskMemFree(parent); db_free(temporary); return ok;
}
static HANDLE db_extract(const wchar_t *stage,const BYTE *bytes,DWORD size,wchar_t *helper) {
    HANDLE file=INVALID_HANDLE_VALUE; DWORD wrote=0,read=0; db_hash hash={0}; BYTE buffer[65536]; int ok=0; LARGE_INTEGER zero;
    if (!db_join(helper,DB_PATH_CAP,stage,L"DeskBridge-Managed.exe")) return INVALID_HANDLE_VALUE;
    file=CreateFileW(helper,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if (file==INVALID_HANDLE_VALUE) return file;
    if (!WriteFile(file,bytes,size,&wrote,NULL) || wrote!=size || !FlushFileBuffers(file)) goto done;
    CloseHandle(file);
    file=CreateFileW(helper,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    if (file==INVALID_HANDLE_VALUE) goto done;
    {
        BY_HANDLE_FILE_INFORMATION info;
        if (!GetFileInformationByHandle(file,&info) || (info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)) || info.nFileSizeHigh || info.nFileSizeLow!=size) goto done;
    }
    zero.QuadPart=0;
    if (!SetFilePointerEx(file,zero,NULL,FILE_BEGIN) || !db_hash_begin(&hash)) goto done;
    do { if (!ReadFile(file,buffer,sizeof(buffer),&read,NULL) || (read && db_crypto.data(hash.hash,buffer,read,0)<0)) goto done; } while (read);
    if (!db_hash_expected(&hash)) goto done;
    ok=1;
done:
    db_hash_close(&hash);
    if (!ok) { if (file!=INVALID_HANDLE_VALUE) CloseHandle(file); DeleteFileW(helper); return INVALID_HANDLE_VALUE; }
    return file;
}
static int db_environment_entry(wchar_t *env,size_t capacity,size_t *used,const wchar_t *key,const wchar_t *value) {
    size_t i;
    for (i=0;key[i];++i) if (!db_append(env,capacity,used,key[i])) return 0;
    if (!db_append(env,capacity,used,L'=')) return 0;
    for (i=0;value[i];++i) if (!db_append(env,capacity,used,value[i])) return 0;
    if (*used+1>=capacity) return 0;
    env[(*used)++]=0; env[*used]=0; return 1;
}
typedef BOOL (WINAPI *db_create_environment)(LPVOID *,HANDLE,BOOL);
typedef BOOL (WINAPI *db_destroy_environment)(LPVOID);
static int db_append_normal_environment(wchar_t *env,size_t *used,HANDLE token,int *has_path) {
    wchar_t library[MAX_PATH+16]; HMODULE module=NULL; LPVOID block=NULL;
    db_create_environment create=NULL; db_destroy_environment destroy=NULL; UINT length; size_t consumed=0; int ok=0;
    length=GetSystemDirectoryW(library,MAX_PATH);
    if (!length || length>=MAX_PATH || !db_join(library,MAX_PATH+16,library,L"userenv.dll")) goto done;
    module=LoadLibraryExW(library,NULL,LOAD_LIBRARY_SEARCH_SYSTEM32); if (!module) goto done;
    create=(db_create_environment)GetProcAddress(module,"CreateEnvironmentBlock");
    destroy=(db_destroy_environment)GetProcAddress(module,"DestroyEnvironmentBlock");
    if (!create || !destroy || !create(&block,token,FALSE) || !block) goto done;
    while (consumed<DB_ENV_CAP) {
        const wchar_t *entry=(const wchar_t *)block+consumed; size_t i=0;
        if (!*entry) { ok=1; break; }
        while (consumed+i<DB_ENV_CAP && entry[i]) ++i;
        if (consumed+i>=DB_ENV_CAP) goto done;
        if (db_keep_normal_env(entry)) {
            size_t j;
            for (j=0;j<i;++j) if (!db_append(env,DB_ENV_CAP,used,entry[j])) goto done;
            if (*used+1>=DB_ENV_CAP) goto done;
            env[(*used)++]=0; env[*used]=0;
            if (db_env_name(entry,L"PATH",0)) *has_path=1;
        }
        consumed+=i+1;
    }
done:
    if (block && destroy) destroy(block); if (module) FreeLibrary(module); return ok;
}
static int db_compare_environment_names(const wchar_t *a,const wchar_t *b) {
    int a_length=0,b_length=0;
    while (a[a_length] && a[a_length]!=L'=') ++a_length;
    while (b[b_length] && b[b_length]!=L'=') ++b_length;
    return CompareStringOrdinal(a,a_length,b,b_length,TRUE);
}
static wchar_t *db_sort_environment(wchar_t *env,size_t used) {
    wchar_t **entries=(wchar_t **)db_alloc(4096*sizeof(wchar_t *)); wchar_t *sorted=(wchar_t *)db_alloc(DB_ENV_CAP*sizeof(wchar_t));
    size_t count=0,i,j,at=0,offset=0; int ok=0;
    if (!entries || !sorted) goto done;
    while (offset<used) {
        if (count==4096) goto done;
        entries[count++]=env+offset;
        offset+=db_length(env+offset)+1;
    }
    for (i=1;i<count;++i) {
        wchar_t *entry=entries[i]; j=i;
        while (j && db_compare_environment_names(entries[j-1],entry)==CSTR_GREATER_THAN) { entries[j]=entries[j-1]; --j; }
        entries[j]=entry;
    }
    for (i=1;i<count;++i) if (db_compare_environment_names(entries[i-1],entries[i])==CSTR_EQUAL) goto done;
    for (i=0;i<count;++i) {
        for (j=0;entries[i][j];++j) if (!db_append(sorted,DB_ENV_CAP,&at,entries[i][j])) goto done;
        if (at+1>=DB_ENV_CAP) goto done;
        sorted[at++]=0; sorted[at]=0;
    }
    ok=1;
done: db_free(entries); if (!ok) { db_free(sorted); sorted=NULL; } return sorted;
}
static wchar_t *db_clean_environment(int elevated,HANDLE token) {
    wchar_t *env=NULL,*windows=NULL,*system=NULL,*modules=NULL,*path=NULL,*temporary=NULL; PWSTR program_data=NULL;
    wchar_t computer[MAX_COMPUTERNAME_LENGTH+1],drive[3]; DWORD computer_length=MAX_COMPUTERNAME_LENGTH+1,length; size_t used=0; int ok=0,has_path=0;
    windows=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); system=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t));
    modules=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); path=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t));
    env=(wchar_t *)db_alloc(DB_ENV_CAP*sizeof(wchar_t));
    temporary=db_stable_temp(elevated);
    if (!windows || !system || !modules || !path || !env || !temporary) goto done;
    length=GetWindowsDirectoryW(windows,DB_PATH_CAP);
    if (!length || length>=DB_PATH_CAP || !db_protected_chain(windows) ||
        FAILED(SHGetKnownFolderPath(&FOLDERID_ProgramData,KF_FLAG_DEFAULT,NULL,&program_data)) || !db_protected_chain(program_data) ||
        !db_join(system,DB_PATH_CAP,windows,L"System32") || !db_join(modules,DB_PATH_CAP,system,L"WindowsPowerShell\\v1.0\\Modules") ||
        !db_copy(path,DB_PATH_CAP,system) || !GetComputerNameW(computer,&computer_length)) goto done;
    {
        size_t at=db_length(path),i; if (!db_append(path,DB_PATH_CAP,&at,L';')) goto done;
        for (i=0;windows[i];++i) if (!db_append(path,DB_PATH_CAP,&at,windows[i])) goto done;
    }
    drive[0]=windows[0]; drive[1]=L':'; drive[2]=0;
    if (!elevated && !db_append_normal_environment(env,&used,token,&has_path)) goto done;
    // Elevated children use an allowlist; normal UI retains the sanitized token-derived user environment.
    // Loader/profiling/startup hooks and ambient module/temp/system overrides are removed
    // before CLR activation; elevated PATH is fixed to OS directories.
    if (!db_environment_entry(env,DB_ENV_CAP,&used,L"COMPUTERNAME",computer) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"OS",L"Windows_NT") ||
        ((elevated || !has_path) && !db_environment_entry(env,DB_ENV_CAP,&used,L"PATH",path)) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"PROCESSOR_ARCHITECTURE",L"AMD64") ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"ProgramData",program_data) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"PSModulePath",modules) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"SystemDrive",drive) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"SystemRoot",windows) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"TEMP",temporary) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"TMP",temporary) ||
        !db_environment_entry(env,DB_ENV_CAP,&used,L"WINDIR",windows)) goto done;
    ok=1;
done:
    if (program_data) CoTaskMemFree(program_data); db_free(windows); db_free(system); db_free(modules); db_free(path); db_free(temporary);
    if (!ok) { db_free(env); env=NULL; }
    else { wchar_t *sorted=db_sort_environment(env,used); db_free(env); env=sorted; }
    return env;
}
static int db_append_number(wchar_t *out,size_t cap,size_t *used,uint64_t number) {
    wchar_t digits[24]; unsigned count=0;
    do { digits[count++]=(wchar_t)(L'0'+number%10); number/=10; } while (number && count<24);
    while (count) if (!db_append(out,cap,used,digits[--count])) return 0;
    return 1;
}
static int db_run(const wchar_t *helper,const wchar_t *stage,const wchar_t *original,int argc,wchar_t **argv,int silent,int elevated,HANDLE token) {
    wchar_t *command=(wchar_t *)db_alloc(DB_COMMAND_CAP*sizeof(wchar_t)),*env=NULL;
    size_t used=0; int i,exit_code=1; STARTUPINFOW startup; PROCESS_INFORMATION process; DWORD code=1;
    ZeroMemory(&startup,sizeof(startup)); ZeroMemory(&process,sizeof(process)); startup.cb=sizeof(startup);
    if (!command || !db_quote(command,DB_COMMAND_CAP,&used,helper)) goto done;
    if (!argc) {
        FILETIME created,exited,kernel,user; uint64_t creation;
        if (!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user)) goto done;
        creation=((uint64_t)created.dwHighDateTime<<32)|created.dwLowDateTime;
        if (!db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_quote(command,DB_COMMAND_CAP,&used,L"--bootstrap-path") ||
            !db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_quote(command,DB_COMMAND_CAP,&used,original) ||
            !db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_quote(command,DB_COMMAND_CAP,&used,L"--bootstrap-pid") ||
            !db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_append_number(command,DB_COMMAND_CAP,&used,GetCurrentProcessId()) ||
            !db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_quote(command,DB_COMMAND_CAP,&used,L"--bootstrap-created") ||
            !db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_append_number(command,DB_COMMAND_CAP,&used,creation)) goto done;
    } else for (i=0;i<argc;++i) if (!db_append(command,DB_COMMAND_CAP,&used,L' ') || !db_quote(command,DB_COMMAND_CAP,&used,argv[i])) goto done;
    env=db_clean_environment(elevated,token); if (!env) goto done;
    // Fixed protected/owned application and cwd; no inherited handles or ambient loader environment.
    if (!CreateProcessW(helper,command,NULL,NULL,FALSE,CREATE_UNICODE_ENVIRONMENT|(silent?CREATE_NO_WINDOW:0),env,stage,&startup,&process)) goto done;
    if (WaitForSingleObject(process.hProcess,INFINITE)==WAIT_OBJECT_0 && GetExitCodeProcess(process.hProcess,&code)) exit_code=(int)code;
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
done: db_free(command); db_free(env); return exit_code;
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,PWSTR command_line,int show) {
    wchar_t *image=NULL,*stage=NULL,*helper=NULL; wchar_t **argv=NULL; HANDLE token=NULL,extracted=INVALID_HANDLE_VALUE;
    int argc=0,exit_code=1,elevated=0,created_stage=0,locked_stage=0,silent=0,hardened=0,acknowledged=0; db_operation operation=DB_INVALID;
    const wchar_t *failure=L"설정 도우미의 실행 환경을 확인하지 못했습니다. Windows 11 x64용 Knot 배포 파일인지, 실행 파일과 사용자 임시 폴더의 접근 권한이 올바른지 확인하세요. 실행 파일은 OneDrive·동기화·링크 폴더 밖의 로컬 폴더에 저장하세요. 임시 폴더 문제는 파일을 옮기는 것만으로 해결되지 않을 수 있습니다."; const BYTE *bytes=NULL; DWORD size=0,used=0;
    TOKEN_ELEVATION elevation; USHORT process_machine=0,native_machine=0; OSVERSIONINFOW version; db_locks locks={{0},0};
    (void)instance; (void)previous; (void)command_line; (void)show; db_heap=GetProcessHeap();
    // Static dependencies are system KnownDLLs/UCRT API sets; later loads search only System32.
    hardened=SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32) && SetDllDirectoryW(L"");
    argv=CommandLineToArgvW(GetCommandLineW(),&argc); if (!argv || argc<1) goto done;
    operation=db_dispatch(argc-1,(const wchar_t *const *)(argv+1)); if (operation==DB_INVALID) goto done;
    silent=db_silent_disable(argc-1,(const wchar_t *const *)(argv+1));
    if (silent) SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
    if (!hardened || !db_load_crypto()) goto done;
    ZeroMemory(&version,sizeof(version)); version.dwOSVersionInfoSize=sizeof(version);
    if (!IsWow64Process2(GetCurrentProcess(),&process_machine,&native_machine) || process_machine!=IMAGE_FILE_MACHINE_UNKNOWN || native_machine!=IMAGE_FILE_MACHINE_AMD64 ||
        !GetVersionExW(&version) || version.dwBuildNumber<22000 || !OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY|TOKEN_DUPLICATE,&token) ||
        !GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&used)) goto done;
    elevated=elevation.TokenIsElevated!=0;
    if ((operation==DB_NORMAL && elevated) || (operation!=DB_NORMAL && !elevated)) {
        failure=L"일반 설정 창은 관리자 권한 없이 여세요. 관리자 작업은 Knot 설정 창의 버튼에서 시작하세요.";
        goto done;
    }
    image=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); stage=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t)); helper=(wchar_t *)db_alloc(DB_PATH_CAP*sizeof(wchar_t));
    if (!image || !stage || !helper) goto done;
    used=GetModuleFileNameW(NULL,image,DB_PATH_CAP); if (!used || used>=DB_PATH_CAP || !db_lock_image_path(image,&locks) || !db_resource(&bytes,&size) || !db_make_stage(elevated,token,stage)) goto done;
    created_stage=1; if (!db_lock_directory_chain(stage,&locks)) goto done; locked_stage=1;
    extracted=db_extract(stage,bytes,size,helper); if (extracted==INVALID_HANDLE_VALUE) goto done;
    failure=L"설정 작업을 완료하지 못했습니다. 표시된 오류를 확인하세요. 조직에서 AllSigned를 강제하면 별도로 서명한 스크립트나 조직이 승인한 수동 배포가 필요합니다.";
    exit_code=db_run(helper,stage,image,argc-1,argv+1,silent,elevated,token);
done:
    if (extracted!=INVALID_HANDLE_VALUE) CloseHandle(extracted);
    // Never recursively remove unknown files, links, sidecars or user content.
    if (created_stage && locked_stage) { if (helper && *helper) DeleteFileW(helper); }
    // The stage's own no-delete handle is released only after deleting our exact helper.
    db_unlock(&locks);
    if (created_stage && locked_stage) RemoveDirectoryW(stage);
    if (db_crypto.module) FreeLibrary(db_crypto.module);
    if (token) CloseHandle(token);
    if (argv) LocalFree(argv);
    db_free(image); db_free(stage); db_free(helper);
    if (db_show_failure(exit_code,silent,operation)) acknowledged=MessageBoxW(NULL,failure,L"Knot",MB_OK|MB_ICONERROR)!=0;
    return db_complete_exit_code(exit_code,silent,operation,acknowledged);
}
