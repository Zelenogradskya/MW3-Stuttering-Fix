#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <intrin.h>
#include <stdlib.h>
#ifndef AUDIO_CACHE_TEST
#include "MinHook.h"
#endif
#define HANDLE_COUNT 64
#define RECORD_SIZE 0x138
#define SEEK_CALLER 0x30E444
#define READ_CALLER 0x30E455
typedef int (__fastcall *SeekFn)(uint64_t,int64_t,int);
typedef int64_t (__fastcall *ReadFn)(void*,int64_t,uint64_t);
typedef void (__fastcall *CloseFn)(uint64_t);
typedef int (__fastcall *TellFn)(void*);
typedef struct {const char *name;uint32_t name_hash;uint64_t offset;char sha[65];DWORD size;BYTE *data;} Asset;
typedef struct {void *identity;void *zip;int asset;uint64_t cursor;BOOL dirty;} Binding;
static Asset *assets;
static int asset_count;
#define ASSET_COUNT asset_count
#define MAX_ASSETS 20000
#define MAX_BLOB_BYTES (UINT64_C(32)*1024*1024*1024)
static BYTE *records;
static Binding bindings[HANDLE_COUNT];
static SRWLOCK lock=SRWLOCK_INIT;
static SeekFn real_seek;
static ReadFn real_read;
static CloseFn real_close;
static TellFn real_tell;
static volatile LONG64 seek_hits,read_hits,served_bytes,resyncs,misses;
#ifndef AUDIO_CACHE_TEST
static uintptr_t image_base;
#endif
#ifndef AUDIO_CACHE_TEST
static void LogUncached(uint64_t h);
#endif
static int NameEquals(const char *actual,const char *expected) {
 for(size_t i=0;i<260;i++){unsigned char a=(unsigned char)actual[i],b=(unsigned char)expected[i];
  if(a=='\\')a='/';if(b=='\\')b='/';if(a>='A'&&a<='Z')a+=32;if(b>='A'&&b<='Z')b+=32;
  if(a!=b)return 0;if(a==0)return 1;
 }return 0;
}
static uint32_t NameHash(const char *path) {
 uint32_t hash=2166136261u;
 for(size_t i=0;i<260;i++){unsigned char c=(unsigned char)path[i];if(!c)return hash;if(c=='\\')c='/';if(c>='A'&&c<='Z')c+=32;hash=(hash^c)*16777619u;}
 return 0;
}

static int Identify(uint64_t h,void **identity,void **zip) {
 if(!records||h==0||h>=HANDLE_COUNT)return -1;
 BYTE *r=records+h*RECORD_SIZE;
 *identity=*(void**)r;*zip=*(void**)(r+0x28);
 if(!*identity||!*zip)return -1;
 uint32_t hash=NameHash((char*)r+0x34);int lo=0,hi=ASSET_COUNT;
 while(lo<hi){int mid=lo+(hi-lo)/2;if(assets[mid].name_hash<hash)lo=mid+1;else hi=mid;}
 for(int i=lo;i<ASSET_COUNT&&assets[i].name_hash==hash;i++)if(assets[i].data&&NameEquals((char*)r+0x34,assets[i].name))return i;
 return -1;
}
static BOOL Matches(uint64_t h,Binding *b) {
 void *id=NULL,*zip=NULL;int a=Identify(h,&id,&zip);
 return a>=0&&b->dirty&&b->asset==a&&b->identity==id&&b->zip==zip;
}
/* A foreign caller gets the stock stream resynchronized before it resumes.
   These buffers serve only the verified sound seek/read pair. */
static int Resync(uint64_t h) {
 if(h==0||h>=HANDLE_COUNT)return 0;
 AcquireSRWLockExclusive(&lock);
 Binding *b=&bindings[h];BOOL active=Matches(h,b);uint64_t pos=b->cursor;
 memset(b,0,sizeof(*b));
 ReleaseSRWLockExclusive(&lock);
 if(active){InterlockedIncrement64(&resyncs);return real_seek(h,(int64_t)pos,2);}
 return 0;
}
static int DispatchSeek(uint64_t h,int64_t off,int origin,uintptr_t caller) {
 if(caller==SEEK_CALLER&&origin==2&&off>=0) {
  AcquireSRWLockExclusive(&lock);
  void *id=NULL,*zip=NULL;int a=Identify(h,&id,&zip);
  if(a>=0&&(uint64_t)off<=assets[a].size) {
   bindings[h]=(Binding){id,zip,a,(uint64_t)off,TRUE};
   InterlockedIncrement64(&seek_hits);
   ReleaseSRWLockExclusive(&lock);return 0;
  }
  ReleaseSRWLockExclusive(&lock);
 }
 InterlockedIncrement64(&misses);
#ifndef AUDIO_CACHE_TEST
 if(caller==SEEK_CALLER)LogUncached(h);
#endif
 if(Resync(h)!=0)return -1;
 return real_seek(h,off,origin);
}
static int64_t DispatchRead(void *dst,int64_t count,uint64_t h,uintptr_t caller) {
 if(caller==READ_CALLER&&dst&&count==0x20000&&h>0&&h<HANDLE_COUNT) {
  AcquireSRWLockExclusive(&lock);
  Binding *b=&bindings[h];
  if(Matches(h,b)&&b->cursor<=assets[b->asset].size) {
   uint64_t n=assets[b->asset].size-b->cursor;if(n>(uint64_t)count)n=(uint64_t)count;
   if(n)memcpy(dst,assets[b->asset].data+b->cursor,(size_t)n);
   b->cursor+=n;
   InterlockedIncrement64(&read_hits);InterlockedAdd64(&served_bytes,(LONG64)n);
   ReleaseSRWLockExclusive(&lock);return (int64_t)n;
  }
  ReleaseSRWLockExclusive(&lock);
 }
 if(Resync(h)!=0)return -1;
 return real_read(dst,count,h);
}
static int DispatchTell(void *unz) {
 AcquireSRWLockShared(&lock);
 for(uint64_t h=1;h<HANDLE_COUNT;h++) {
  Binding *b=&bindings[h];
  if(b->identity==unz&&Matches(h,b)){int pos=(int)b->cursor;ReleaseSRWLockShared(&lock);return pos;}
 }
 ReleaseSRWLockShared(&lock);return real_tell(unz);
}
static void DispatchClose(uint64_t h) {
 if(h>0&&h<HANDLE_COUNT){AcquireSRWLockExclusive(&lock);memset(&bindings[h],0,sizeof(bindings[h]));ReleaseSRWLockExclusive(&lock);}
 real_close(h);
}
#ifndef AUDIO_CACHE_TEST
static HMODULE self_module,system_module;
static void * (WINAPI *real_create9)(UINT);
static INIT_ONCE once=INIT_ONCE_STATIC_INIT;
static wchar_t log_path[MAX_PATH];
static void Log(const char *message) {
 SYSTEMTIME t;GetSystemTime(&t);char line[800];
 int n=snprintf(line,sizeof(line),"%04u-%02u-%02uT%02u:%02u:%02uZ pid=%lu %s\r\n",t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond,(unsigned long)GetCurrentProcessId(),message);
 if(n<=0)return;if(n>=(int)sizeof(line))n=(int)sizeof(line)-1;
 HANDLE f=CreateFileW(log_path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
 if(f==INVALID_HANDLE_VALUE)return;DWORD written;WriteFile(f,line,(DWORD)n,&written,NULL);CloseHandle(f);
}
static void LogUncached(uint64_t h) {
 if(!records||h==0||h>=HANDLE_COUNT)return;
 BYTE *r=records+h*RECORD_SIZE;if(!*(void**)(r+0x28))return;
 char path[261];memcpy(path,r+0x34,260);path[260]=0;
 for(size_t i=0;path[i];i++)if(path[i]=='\\')path[i]='/';
 if(_strnicmp(path,"sound/",6))return;
 uint32_t hash=2166136261u;
 for(size_t i=0;path[i];i++){unsigned char ch=(unsigned char)path[i];if(ch>='A'&&ch<='Z')ch+=32;hash=(hash^ch)*16777619u;}
 static SRWLOCK missing_lock=SRWLOCK_INIT;
 static uint32_t seen[128];static unsigned int count;
 AcquireSRWLockExclusive(&missing_lock);
 for(unsigned int i=0;i<count;i++)if(seen[i]==hash){ReleaseSRWLockExclusive(&missing_lock);return;}
 if(count==128){ReleaseSRWLockExclusive(&missing_lock);return;}
 seen[count++]=hash;ReleaseSRWLockExclusive(&missing_lock);
 char line[400];snprintf(line,sizeof(line),"UNCACHED sound handle=%llu path=%s",(unsigned long long)h,path);Log(line);
}
static BOOL Digest(BYTE *data,DWORD size,char hex[65]) {
 HCRYPTPROV provider=0;HCRYPTHASH hash=0;BYTE digest[32];DWORD n=32;BOOL ok=FALSE;
 if(!CryptAcquireContextW(&provider,NULL,NULL,PROV_RSA_AES,CRYPT_VERIFYCONTEXT))return FALSE;
 if(CryptCreateHash(provider,CALG_SHA_256,0,0,&hash)&&CryptHashData(hash,data,size,0)&&CryptGetHashParam(hash,HP_HASHVAL,digest,&n,0)) {
  static const char digits[]="0123456789ABCDEF";for(int i=0;i<32;i++){hex[i*2]=digits[digest[i]>>4];hex[i*2+1]=digits[digest[i]&15];}hex[64]=0;ok=TRUE;
 }
 if(hash)CryptDestroyHash(hash);CryptReleaseContext(provider,0);return ok;
}
static BOOL ValidateExecutable(const wchar_t *path) {
 HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
 if(f==INVALID_HANDLE_VALUE)return FALSE;
 LARGE_INTEGER length;BYTE *file=NULL;DWORD got=0;BOOL ok=FALSE;
 if(!GetFileSizeEx(f,&length)||length.QuadPart<1024||length.QuadPart>128*1024*1024)goto done;
 file=HeapAlloc(GetProcessHeap(),0,(SIZE_T)length.QuadPart);if(!file)goto done;
 if(!ReadFile(f,file,(DWORD)length.QuadPart,&got,NULL)||got!=(DWORD)length.QuadPart)goto done;
 IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER*)file;
 if(dos->e_magic!=IMAGE_DOS_SIGNATURE||dos->e_lfanew<64||(uint64_t)dos->e_lfanew+sizeof(IMAGE_NT_HEADERS64)>(uint64_t)length.QuadPart)goto done;
 IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64*)(file+dos->e_lfanew);
 if(nt->Signature!=IMAGE_NT_SIGNATURE||nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||
    nt->FileHeader.TimeDateStamp!=1786002008u||nt->OptionalHeader.SizeOfImage!=0x044BE000||
    nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC||nt->FileHeader.NumberOfSections<1||nt->FileHeader.NumberOfSections>96)goto done;
 IMAGE_SECTION_HEADER *sections=IMAGE_FIRST_SECTION(nt);
 if((BYTE*)(sections+nt->FileHeader.NumberOfSections)>file+length.QuadPart)goto done;
 for(WORD i=0;i<nt->FileHeader.NumberOfSections;i++) {
  if(memcmp(sections[i].Name,".text\0\0\0",8))continue;
  uint64_t off=sections[i].PointerToRawData,size=sections[i].SizeOfRawData;
  if(sections[i].VirtualAddress!=0x1000||!size||off+size>(uint64_t)length.QuadPart||size>MAXDWORD)goto done;
  char hex[65];
  ok=Digest(file+off,(DWORD)size,hex)&&!strcmp(hex,"6568481ABC9F7B787ADDA5A61E53CEAB4D1923EFC0CB05501C4B5E1AE1F3210E");
  break;
 }
done:
 if(file)HeapFree(GetProcessHeap(),0,file);CloseHandle(f);return ok;
}
static wchar_t cache_root[MAX_PATH];
static char expected_index_sha[65];
static BOOL PathJoin(wchar_t *dst,const wchar_t *base,const wchar_t *name) {
 if(wcslen(base)+wcslen(name)+2>=MAX_PATH)return FALSE;
 wcscpy(dst,base);wcscat(dst,L"\\");wcscat(dst,name);return TRUE;
}
static BOOL ReadConfiguration(const wchar_t *ini) {
 wchar_t sha[80],logs[MAX_PATH];
 DWORD n=GetPrivateProfileStringW(L"Cache",L"Root",L"",cache_root,MAX_PATH,ini);
 if(n<4||n>180||cache_root[1]!=L':'||cache_root[2]!=L'\\')return FALSE;
 while(n>3&&cache_root[n-1]==L'\\')cache_root[--n]=0;
 if(GetPrivateProfileStringW(L"Cache",L"IndexSHA256",L"",sha,80,ini)!=64)return FALSE;
 for(int i=0;i<64;i++){wchar_t ch=sha[i];if(!((ch>=L'0'&&ch<=L'9')||(ch>=L'A'&&ch<=L'F')||(ch>=L'a'&&ch<=L'f')))return FALSE;expected_index_sha[i]=(char)ch;}expected_index_sha[64]=0;
 if(!PathJoin(logs,cache_root,L"logs"))return FALSE;CreateDirectoryW(logs,NULL);
 wchar_t filename[64];swprintf(filename,64,L"runtime-%lu.log",(unsigned long)GetCurrentProcessId());
 return PathJoin(log_path,logs,filename);
}
static BOOL InitializePaths(void) {
 wchar_t module[MAX_PATH],ini[MAX_PATH];DWORD n=GetModuleFileNameW(self_module,module,MAX_PATH);
 if(!n||n>=MAX_PATH)return FALSE;
 wchar_t *slash=wcsrchr(module,L'\\');if(!slash)return FALSE;*slash=0;
 return PathJoin(ini,module,L"mw3sf.ini")&&ReadConfiguration(ini);
}
static HANDLE cache_file=INVALID_HANDLE_VALUE,cache_mapping,index_file=INVALID_HANDLE_VALUE,index_mapping;
static BYTE *cache_view,*index_view;
static void CloseCache(void) {
 if(assets){HeapFree(GetProcessHeap(),0,assets);assets=NULL;}asset_count=0;
 if(cache_view){UnmapViewOfFile(cache_view);cache_view=NULL;}
 if(index_view){UnmapViewOfFile(index_view);index_view=NULL;}
 if(cache_mapping){CloseHandle(cache_mapping);cache_mapping=NULL;}
 if(index_mapping){CloseHandle(index_mapping);index_mapping=NULL;}
 if(cache_file!=INVALID_HANDLE_VALUE){CloseHandle(cache_file);cache_file=INVALID_HANDLE_VALUE;}
 if(index_file!=INVALID_HANDLE_VALUE){CloseHandle(index_file);index_file=INVALID_HANDLE_VALUE;}
}
static void Hex(const BYTE *bytes,char out[65]) {
 static const char d[]="0123456789ABCDEF";for(int i=0;i<32;i++){out[i*2]=d[bytes[i]>>4];out[i*2+1]=d[bytes[i]&15];}out[64]=0;
}
static BOOL MapCache(void) {
 wchar_t path[MAX_PATH];LARGE_INTEGER length;char sha[65];
 uint64_t blob_bytes;uint32_t count;
 if(!PathJoin(path,cache_root,L"index.bin"))goto failed;
 index_file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
 if(index_file==INVALID_HANDLE_VALUE||!GetFileSizeEx(index_file,&length)||length.QuadPart<96||length.QuadPart>96+312*MAX_ASSETS)goto failed;
 index_mapping=CreateFileMappingW(index_file,NULL,PAGE_READONLY,0,0,NULL);if(!index_mapping)goto failed;
 index_view=MapViewOfFile(index_mapping,FILE_MAP_READ,0,0,0);if(!index_view)goto failed;
 if(!Digest(index_view,(DWORD)length.QuadPart,sha)||_stricmp(sha,expected_index_sha)||memcmp(index_view,"MW3IDX01",8)||*(uint32_t*)(index_view+8)!=1)goto failed;
 count=*(uint32_t*)(index_view+12);blob_bytes=*(uint64_t*)(index_view+16);
 if(!count||count>MAX_ASSETS||length.QuadPart!=(LONGLONG)(96+(uint64_t)count*312)||blob_bytes<65536||blob_bytes>MAX_BLOB_BYTES)goto failed;
 if(!PathJoin(path,cache_root,L"audio.bin"))goto failed;
 cache_file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
 if(cache_file==INVALID_HANDLE_VALUE||!GetFileSizeEx(cache_file,&length)||(uint64_t)length.QuadPart!=blob_bytes)goto failed;
 cache_mapping=CreateFileMappingW(cache_file,NULL,PAGE_READONLY,0,0,NULL);if(!cache_mapping)goto failed;
 cache_view=MapViewOfFile(cache_mapping,FILE_MAP_READ,0,0,0);if(!cache_view)goto failed;
 Hex(index_view+56,sha);char actual[65];
 if(memcmp(cache_view,"MW3SND01",8)||*(uint32_t*)(cache_view+8)!=count||*(uint64_t*)(cache_view+16)!=blob_bytes||
    !Digest(cache_view,65536,actual)||strcmp(sha,actual))goto failed;
 assets=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,(SIZE_T)count*sizeof(Asset));if(!assets)goto failed;
 asset_count=(int)count;
 for(uint32_t i=0;i<count;i++) {
  BYTE *r=index_view+96+(SIZE_T)i*312;const char *name=(const char*)r;
  size_t len=strnlen(name,260);
  if(len<7||len>=260||_strnicmp(name,"sound/",6)||strstr(name,"../")||strstr(name,"/./")||*(uint32_t*)(r+308)!=0)goto failed;
  for(size_t j=0;j<len;j++){unsigned char ch=(unsigned char)name[j];if(!((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='_'||ch=='/'||ch==' '||ch=='.'||ch=='-'))goto failed;}
  assets[i].name=name;assets[i].name_hash=*(uint32_t*)(r+260);assets[i].offset=*(uint64_t*)(r+264);assets[i].size=*(uint32_t*)(r+272);Hex(r+276,assets[i].sha);
  if(assets[i].name_hash!=NameHash(name)||!assets[i].size||assets[i].size>64*1024*1024||
     assets[i].offset<65536||assets[i].offset>blob_bytes||(uint64_t)assets[i].size>blob_bytes-assets[i].offset)goto failed;
  if(i&&assets[i].name_hash<assets[i-1].name_hash)goto failed;
  for(uint32_t j=i;j>0&&assets[j-1].name_hash==assets[i].name_hash;j--)if(NameEquals(assets[i].name,assets[j-1].name))goto failed;
  assets[i].data=cache_view+(SIZE_T)assets[i].offset;
 }
 char line[180];snprintf(line,sizeof(line),"mapped cache: %u resources, %llu file bytes; file-backed pages",(unsigned int)count,(unsigned long long)blob_bytes);Log(line);return TRUE;
failed:
 CloseCache();return FALSE;
}

static int __fastcall HookSeek(uint64_t h,int64_t off,int origin) {
 return DispatchSeek(h,off,origin,(uintptr_t)__builtin_return_address(0)-image_base);
}
static int64_t __fastcall HookRead(void *dst,int64_t count,uint64_t h) {
 return DispatchRead(dst,count,h,(uintptr_t)__builtin_return_address(0)-image_base);
}
static int __fastcall HookTell(void *unz) {return DispatchTell(unz);}
static void __fastcall HookClose(uint64_t h) {DispatchClose(h);}
static DWORD WINAPI StatsThread(void *unused) {
 (void)unused;
 for(;;){Sleep(2000);char line[300];snprintf(line,sizeof(line),"stats seeks=%lld reads=%lld bytes=%lld resyncs=%lld misses=%lld",
  (long long)InterlockedCompareExchange64(&seek_hits,0,0),(long long)InterlockedCompareExchange64(&read_hits,0,0),
  (long long)InterlockedCompareExchange64(&served_bytes,0,0),(long long)InterlockedCompareExchange64(&resyncs,0,0),
  (long long)InterlockedCompareExchange64(&misses,0,0));Log(line);}
 return 0;
}
static void Install(void) {
 wchar_t exe[MAX_PATH];if(!GetModuleFileNameW(NULL,exe,MAX_PATH))return;
 const wchar_t *name=wcsrchr(exe,L'\\');name=name?name+1:exe;
 if(_wcsicmp(name,L"iw5sp.exe"))return;
 if(!InitializePaths()){OutputDebugStringA("MW3 Stuttering Fix: configuration missing or invalid; native path retained.");return;}
 Log("initializing mapped common-audio seek cache");
 if(!ValidateExecutable(exe)){Log("REFUSED: unsupported executable code build");return;}
 image_base=(uintptr_t)GetModuleHandleW(NULL);BYTE *base=(BYTE*)image_base;
 IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER*)base;IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64*)(base+dos->e_lfanew);
 if(nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||nt->OptionalHeader.SizeOfImage!=0x044BE000){Log("REFUSED: PE architecture or size mismatch");return;}
 static const BYTE seek_sig[]={0x48,0x89,0x5c,0x24,0x10,0x48,0x89,0x6c,0x24,0x18,0x48,0x89,0x7c,0x24,0x20,0x41,0x56,0x48,0x83,0xec,0x20};
 static const BYTE read_sig[]={0x40,0x55,0x56,0x41,0x57,0x48,0x83,0xec,0x20,0x4d,0x8b,0xf8,0x48,0x8b,0xea,0x48,0x8b,0xf1};
 static const BYTE close_sig[]={0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x48,0x69,0xd9,0x38,0x01,0x00,0x00};
 static const BYTE tell_sig[]={0x48,0x85,0xc9,0x74,0x10,0x48,0x8b,0x81,0x80,0x00,0x00,0x00,0x48,0x85,0xc0,0x74,0x04};
 static const BYTE seek_call[]={0xe8,0x1c,0x80,0xfa,0xff};
 static const BYTE read_call[]={0xe8,0x6b,0x7a,0xfa,0xff};
 if(memcmp(base+0x2B6460,seek_sig,sizeof(seek_sig))||memcmp(base+0x2B5EC0,read_sig,sizeof(read_sig))||
    memcmp(base+0x2B3E90,close_sig,sizeof(close_sig))||memcmp(base+0x30E43F,seek_call,sizeof(seek_call))||
    memcmp(base+0x30E450,read_call,sizeof(read_call))||memcmp(base+0x315FE0,tell_sig,sizeof(tell_sig))){Log("REFUSED: engine byte signatures changed");return;}
 if(!MapCache()){Log("REFUSED: mapped cache header, size or offsets failed validation");return;}
 records=base+0x026563F0;
 MH_STATUS status=MH_Initialize();if(status!=MH_OK&&status!=MH_ERROR_ALREADY_INITIALIZED){Log("REFUSED: hook initialization failed");return;}
 void *targets[4]={base+0x2B6460,base+0x2B5EC0,base+0x2B3E90,base+0x315FE0};
 void *hooks[4]={(void*)HookSeek,(void*)HookRead,(void*)HookClose,(void*)HookTell};
 void **trampolines[4]={(void**)&real_seek,(void**)&real_read,(void**)&real_close,(void**)&real_tell};
 int made=0;
 for(int i=0;i<4;i++){status=MH_CreateHook(targets[i],hooks[i],trampolines[i]);if(status!=MH_OK)break;made++;}
 if(made==4){for(int i=0;i<4;i++)MH_QueueEnableHook(targets[i]);status=MH_ApplyQueued();}
 if(made!=4||status!=MH_OK){for(int i=0;i<made;i++){MH_DisableHook(targets[i]);MH_RemoveHook(targets[i]);}Log("REFUSED: hook installation failed");return;}
 HMODULE pinned=NULL;GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,(LPCWSTR)(uintptr_t)self_module,&pinned);
 Log("ACTIVE: verified FS_Seek/FS_Read/close/tell hooks; mapped common-audio buffers; original game archives unchanged");
 HANDLE worker=CreateThread(NULL,0,StatsThread,NULL,0,NULL);if(worker)CloseHandle(worker);
}
static BOOL CALLBACK Initialize(PINIT_ONCE init,void *parameter,void **context) {
 (void)init;(void)parameter;(void)context;wchar_t path[MAX_PATH];UINT n=GetSystemDirectoryW(path,MAX_PATH);
 if(!n||n+11>=MAX_PATH)return FALSE;wcscat(path,L"\\d3d9.dll");
 system_module=LoadLibraryW(path);if(!system_module)return FALSE;
 real_create9=(void*(WINAPI*)(UINT))GetProcAddress(system_module,"Direct3DCreate9");
 if(!real_create9)return FALSE;Install();return TRUE;
}
void *WINAPI Direct3DCreate9(UINT version) {
 if(!InitOnceExecuteOnce(&once,Initialize,NULL,NULL))return NULL;return real_create9(version);
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
 (void)reserved;if(reason==DLL_PROCESS_ATTACH){self_module=module;DisableThreadLibraryCalls(module);}return TRUE;
}
#ifdef AUDIO_MAP_TEST
int wmain(int argc,wchar_t **argv) {
 if(argc==3&&!wcscmp(argv[1],L"--validate-exe")) {
  BOOL ok=ValidateExecutable(argv[2]);puts(ok?"PASS: supported executable code identity":"REFUSED: unsupported executable code identity");return ok?0:2;
 }
 if(argc!=3){puts("Usage: cache-map-test.exe <cache-dir> <index-sha256>");return 2;}
 if(!wcscmp(argv[1],L"--ini")) {
  if(!ReadConfiguration(argv[2])){puts("REFUSED: invalid Unicode configuration");return 1;}
 } else {
  if(wcslen(argv[1])>180||wcslen(argv[2])!=64)return 2;
  wcscpy(cache_root,argv[1]);for(int i=0;i<64;i++)expected_index_sha[i]=(char)argv[2][i];expected_index_sha[64]=0;
 }
 wchar_t logs[MAX_PATH];if(!PathJoin(logs,cache_root,L"logs"))return 2;CreateDirectoryW(logs,NULL);PathJoin(log_path,logs,L"loader-test.log");
 if(!MapCache()){puts("REFUSED: invalid cache header, index, size or resource range");return 1;}
 for(int i=0;i<ASSET_COUNT;i++){char sha[65];if(!Digest(assets[i].data,assets[i].size,sha)||strcmp(sha,assets[i].sha)){printf("REFUSED: mapped resource %d differs\n",i);CloseCache();return 1;}}
 printf("PASS: %u resources mapped and SHA256-verified.\n",(unsigned int)ASSET_COUNT);CloseCache();return 0;
}
#endif

#else
static uint64_t mock_pos;static int mock_fail,mock_seek_calls,mock_read_calls;
static int __fastcall MockSeek(uint64_t h,int64_t off,int origin){(void)h;mock_seek_calls++;if(mock_fail)return -1;
 int64_t p=origin==2?off:origin==1?(int64_t)mock_pos+off:(int64_t)assets[0].size+off;if(p<0||(uint64_t)p>assets[0].size)return -1;mock_pos=(uint64_t)p;return 0;}
static int64_t __fastcall MockRead(void *dst,int64_t n,uint64_t h){(void)h;mock_read_calls++;if(n<0)return -1;uint64_t got=assets[0].size-mock_pos;if(got>(uint64_t)n)got=(uint64_t)n;memcpy(dst,assets[0].data+mock_pos,(size_t)got);mock_pos+=got;return (int64_t)got;}
static int __fastcall MockTell(void *unz){(void)unz;return (int)mock_pos;}
static void __fastcall MockClose(uint64_t h){memset(records+h*RECORD_SIZE,0,RECORD_SIZE);mock_pos=0;}
static void OpenMock(void){BYTE *r=records+RECORD_SIZE;*(void**)r=(void*)0x123400;*(void**)(r+0x28)=(void*)0x567800;strcpy((char*)r+0x34,assets[0].name);}
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAILED line %d: %s\n",__LINE__,#x);return 1;}}while(0)
static int CompareAsset(const void *a,const void *b) {
 const Asset *x=a,*y=b;return x->name_hash<y->name_hash?-1:x->name_hash>y->name_hash?1:strcmp(x->name,y->name);
}
int main(void) {
 static const char *fixture_names[]={"sound/test/first.wav","sound/test/mixed.mp3","sound/test/third.wav"};
 asset_count=3;assets=calloc(ASSET_COUNT,sizeof(Asset));CHECK(assets);
 for(int i=0;i<ASSET_COUNT;i++){assets[i].name=fixture_names[i];assets[i].name_hash=NameHash(fixture_names[i]);}
 qsort(assets,ASSET_COUNT,sizeof(Asset),CompareAsset);
 records=calloc(HANDLE_COUNT,RECORD_SIZE);assets[0].size=400000;assets[0].data=malloc(assets[0].size);
 BYTE *buf=malloc(0x20000);CHECK(records&&assets[0].data&&buf);
 for(DWORD i=0;i<assets[0].size;i++)assets[0].data[i]=(BYTE)(i^(i>>8));
 real_seek=MockSeek;real_read=MockRead;real_close=MockClose;real_tell=MockTell;OpenMock();
 for(int i=0;i<1000;i++){uint64_t pos=((uint64_t)i*15485863)%assets[0].size;CHECK(DispatchSeek(1,(int64_t)pos,2,SEEK_CALLER)==0);int64_t n=DispatchRead(buf,0x20000,1,READ_CALLER);uint64_t expected=assets[0].size-pos;if(expected>0x20000)expected=0x20000;CHECK(n==(int64_t)expected);CHECK(memcmp(buf,assets[0].data+pos,(size_t)n)==0);}
 CHECK(mock_seek_calls==0&&mock_read_calls==0);
 CHECK(DispatchTell((void*)0x123400)==(int)bindings[1].cursor);
 CHECK(DispatchTell((void*)0x999900)==(int)mock_pos);
 CHECK(DispatchSeek(1,assets[0].size,2,SEEK_CALLER)==0);CHECK(DispatchRead(buf,0x20000,1,READ_CALLER)==0);
 CHECK(DispatchSeek(1,100,2,SEEK_CALLER)==0);CHECK(DispatchRead(buf,0x20000,1,READ_CALLER)==0x20000);
 CHECK(DispatchRead(buf,32,1,0)==32);CHECK(mock_pos==100+0x20000+32);CHECK(memcmp(buf,assets[0].data+100+0x20000,32)==0);
 CHECK(DispatchSeek(1,50,2,SEEK_CALLER)==0);mock_fail=1;int reads_before=mock_read_calls;CHECK(DispatchRead(buf,32,1,0)==-1);CHECK(mock_read_calls==reads_before);mock_fail=0;
 CHECK(DispatchSeek(1,200,2,SEEK_CALLER)==0);DispatchClose(1);OpenMock();CHECK(DispatchRead(buf,32,1,0)==32);CHECK(mock_pos==32);CHECK(memcmp(buf,assets[0].data,32)==0);
 CHECK(DispatchSeek(1,-1,2,SEEK_CALLER)==-1);
 for(int a=1;a<ASSET_COUNT;a++){
  assets[a].size=(DWORD)(512+a*37);assets[a].data=malloc(assets[a].size);CHECK(assets[a].data);
  for(DWORD i=0;i<assets[a].size;i++)assets[a].data[i]=(BYTE)(i+a);
  BYTE *r=records+2*RECORD_SIZE;*(void**)r=(void*)(uintptr_t)(0x888000+a);*(void**)(r+0x28)=(void*)0x567800;strcpy((char*)r+0x34,assets[a].name);
  CHECK(DispatchSeek(2,3,2,SEEK_CALLER)==0);
  CHECK(DispatchRead(buf,0x20000,2,READ_CALLER)==(int64_t)assets[a].size-3);
  CHECK(memcmp(buf,assets[a].data+3,assets[a].size-3)==0);
  CHECK(DispatchTell((void*)(uintptr_t)(0x888000+a))==(int)assets[a].size);
  DispatchClose(2);free(assets[a].data);assets[a].data=NULL;
 }
 puts("PASS: 1000 random cached seek/read pairs, byte equality, EOF, native fallback position, failed resync, close/reuse, virtual position queries, invalid offset, all configured resource paths.");
 free(buf);free(assets[0].data);free(records);free(assets);return 0;
}
#endif

